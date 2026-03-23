// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! PELT (Pruned Exact Linear Time) change-point detection.
//!
//! Reference: Killick et al., "Optimal Detection of Changepoints with a Linear Computational Cost", JASA, 2012.

const std = @import("std");
const math = std.math;

/// PELT change-point detection.
///
/// Detects change points in `values` using a Gaussian cost model
/// with the given `penalty` and `min_size` constraint.
/// Writes change-point indices into `cps_out` and sets `cps_len_out`.
/// Returns 0 on success, -1 on error.
pub fn pelt(
    allocator: std.mem.Allocator,
    values: [*]const f64,
    values_len: i32,
    penalty: f64,
    min_size: i32,
    cps_out: [*]i32,
    cps_len_out: *i32,
) i32 {
    if (values_len < 0) return -1;
    const n: usize = @intCast(values_len);
    const ms: usize = @intCast(@max(1, min_size));
    if (n == 0) {
        cps_len_out.* = 0;
        return 0;
    }

    if (n < ms * 2) {
        cps_len_out.* = 0;
        return 0;
    }

    // Cumulative sum and sum-of-squares for O(1) segment cost.
    const cum_sum = allocator.alloc(f64, n + 1) catch return -1;
    defer allocator.free(cum_sum);
    const cum_sq = allocator.alloc(f64, n + 1) catch return -1;
    defer allocator.free(cum_sq);

    cum_sum[0] = 0;
    cum_sq[0] = 0;
    for (0..n) |i| {
        cum_sum[i + 1] = cum_sum[i] + values[i];
        cum_sq[i + 1] = cum_sq[i] + values[i] * values[i];
    }

    // Segment cost: variance * count (Gaussian negative log-likelihood, up to constant).
    const segmentCost = struct {
        fn cost(cs: []f64, csq: []f64, start: usize, end: usize) f64 {
            const count: f64 = @floatFromInt(end - start);
            if (count <= 0) return 0;
            const s = cs[end] - cs[start];
            const sq = csq[end] - csq[start];
            return sq - (s * s) / count;
        }
    }.cost;

    // Optimal cost F[t] and last change point before t.
    const f_buf = allocator.alloc(f64, n + 1) catch return -1;
    defer allocator.free(f_buf);
    const cp_buf = allocator.alloc(usize, n + 1) catch return -1;
    defer allocator.free(cp_buf);

    f_buf[0] = -penalty;
    for (1..n + 1) |t| {
        f_buf[t] = math.inf(f64);
        cp_buf[t] = 0;
    }

    // Candidate set for pruning.
    const candidates = allocator.alloc(usize, n + 1) catch return -1;
    defer allocator.free(candidates);
    var num_candidates: usize = 1;
    candidates[0] = 0;

    // Cache for segmentCost values per candidate, reused in pruning.
    const cost_cache = allocator.alloc(f64, n + 1) catch return -1;
    defer allocator.free(cost_cache);

    for (ms..n + 1) |t| {
        var best_cost: f64 = math.inf(f64);
        var best_cp: usize = 0;

        for (0..num_candidates) |ci| {
            const s = candidates[ci];
            if (t < s + ms) {
                cost_cache[ci] = math.inf(f64);
                continue;
            }

            const seg_cost = segmentCost(cum_sum, cum_sq, s, t);
            cost_cache[ci] = seg_cost;
            const c = f_buf[s] + seg_cost + penalty;
            if (c < best_cost) {
                best_cost = c;
                best_cp = s;
            }
        }

        f_buf[t] = best_cost;
        cp_buf[t] = best_cp;

        // Pruning: remove candidates that can never be optimal.
        // Reuse cached segmentCost values from the optimization loop when available.
        var new_count: usize = 0;
        for (0..num_candidates) |ci| {
            const s = candidates[ci];
            // Use cached cost if it was computed; otherwise compute it now.
            // Candidates with t < s + ms were skipped in optimization but still
            // need segmentCost for the pruning check.
            const seg_cost = if (cost_cache[ci] < math.inf(f64))
                cost_cache[ci]
            else
                segmentCost(cum_sum, cum_sq, s, t);
            if (f_buf[s] + seg_cost <= f_buf[t]) {
                candidates[new_count] = s;
                new_count += 1;
            }
        }
        candidates[new_count] = t;
        num_candidates = new_count + 1;
    }

    // Backtrace change points.
    const result = allocator.alloc(i32, n) catch return -1;
    defer allocator.free(result);
    var result_len: usize = 0;
    var pos: usize = n;
    while (pos > 0 and cp_buf[pos] > 0) {
        result[result_len] = @intCast(cp_buf[pos]);
        result_len += 1;
        pos = cp_buf[pos];
    }

    // Reverse into output.
    for (0..result_len) |i| {
        cps_out[i] = result[result_len - 1 - i];
    }
    cps_len_out.* = @intCast(result_len);
    return 0;
}
