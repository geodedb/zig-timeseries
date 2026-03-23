// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Dynamic Time Warping variants: constrained, derivative, open-end, shape, and soft.
//!
//! All public functions use idiomatic Zig signatures:
//! - Bounded slices (`[]const f64`) instead of raw pointers + length pairs
//! - Error unions (`!`) instead of integer return codes
//! - Result structs instead of output pointer parameters
//!
//! References:
//! - Sakoe & Chiba, "Dynamic Programming Algorithm Optimization for Spoken Word Recognition", IEEE Trans. ASSP, 1978.
//! - Keogh & Ratanamahatana, "Exact indexing of dynamic time warping", KAIS, 2005 (LB_Keogh).
//! - Cuturi & Blondel, "Soft-DTW: A Differentiable Loss Function for Time-Series", ICML, 2017.

const std = @import("std");
const math = std.math;
const types = @import("types.zig");
const PathPoint = types.PathPoint;
const DtwResult = types.DtwResult;
const TsError = types.TsError;

/// Maximum number of f64 elements allowed in a single allocation (256 MB cap).
const MAX_ALLOC_ELEMENTS: usize = 256 * 1024 * 1024 / @sizeOf(f64);

/// Walk backward through a DTW cost matrix from (start_i, start_j) choosing the
/// minimum-cost neighbor at each step. Returns the warp path in forward order.
fn backtrackPath(
    allocator: std.mem.Allocator,
    cost_flat: []const f64,
    m: usize,
    start_i: usize,
    start_j: usize,
) (TsError || error{OutOfMemory})![]PathPoint {
    const max_path = start_i + start_j + 2;
    const rev = try allocator.alloc(PathPoint, max_path);
    defer allocator.free(rev);

    var pi: usize = start_i;
    var pj: usize = start_j;
    var plen: usize = 0;

    while (true) {
        rev[plen] = .{ .i = @intCast(pi), .j = @intCast(pj) };
        plen += 1;
        if (pi == 0 and pj == 0) break;

        var best: f64 = math.inf(f64);
        var ni: usize = pi;
        var nj: usize = pj;

        if (pi > 0 and pj > 0 and cost_flat[(pi - 1) * m + (pj - 1)] < best) {
            best = cost_flat[(pi - 1) * m + (pj - 1)];
            ni = pi - 1;
            nj = pj - 1;
        }
        if (pi > 0 and cost_flat[(pi - 1) * m + pj] < best) {
            best = cost_flat[(pi - 1) * m + pj];
            ni = pi - 1;
            nj = pj;
        }
        if (pj > 0 and cost_flat[pi * m + (pj - 1)] < best) {
            ni = pi;
            nj = pj - 1;
        }

        pi = ni;
        pj = nj;
    }

    // Allocate the result path and reverse into it.
    const path = try allocator.alloc(PathPoint, plen);
    for (0..plen) |k| {
        path[k] = rev[plen - 1 - k];
    }

    return path;
}

/// Constrained DTW with Sakoe-Chiba band.
///
/// Returns the DTW distance and the warp path. The caller owns the path
/// allocation and must free it via `result.deinit(allocator)`.
///
/// `band` of 0 means no constraint (full DTW).
pub fn constrainedDTW(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    band: usize,
) (TsError || error{OutOfMemory})!DtwResult {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0) return TsError.InvalidInput;

    const w: usize = if (band == 0) @max(n, m) else band;

    const size = std.math.mul(usize, n, m) catch return TsError.AllocationTooLarge;
    if (size > MAX_ALLOC_ELEMENTS) return TsError.AllocationTooLarge;
    const cost_flat = try allocator.alloc(f64, size);
    defer allocator.free(cost_flat);

    for (0..n) |i| {
        for (0..m) |j| {
            const diff = if (i >= j) i - j else j - i;
            if (diff > w) {
                cost_flat[i * m + j] = math.inf(f64);
                continue;
            }

            const d = a[i] - b[j];
            const local_cost = d * d;

            var min_prev: f64 = math.inf(f64);
            if (i > 0 and j > 0) min_prev = cost_flat[(i - 1) * m + (j - 1)];
            if (i > 0) min_prev = @min(min_prev, cost_flat[(i - 1) * m + j]);
            if (j > 0) min_prev = @min(min_prev, cost_flat[i * m + (j - 1)]);
            if (i == 0 and j == 0) min_prev = 0;

            cost_flat[i * m + j] = local_cost + min_prev;
        }
    }

    const distance = @sqrt(cost_flat[(n - 1) * m + (m - 1)]);
    const path = try backtrackPath(allocator, cost_flat, m, n - 1, m - 1);

    return DtwResult{
        .distance = distance,
        .path = path,
    };
}

/// Derivative DTW: computes DTW on first-difference representation.
///
/// Requires both input slices to have length >= 2.
pub fn derivativeDTW(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    band: usize,
) (TsError || error{OutOfMemory})!DtwResult {
    if (a.len < 2 or b.len < 2) return TsError.InvalidInput;

    const da = try allocator.alloc(f64, a.len - 1);
    defer allocator.free(da);
    const db = try allocator.alloc(f64, b.len - 1);
    defer allocator.free(db);

    for (0..a.len - 1) |i| da[i] = a[i + 1] - a[i];
    for (0..b.len - 1) |i| db[i] = b[i + 1] - b[i];

    return constrainedDTW(allocator, da, db, band);
}

/// Open-end DTW: alignment need not reach end of second series.
pub fn openEndDTW(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    band: usize,
) (TsError || error{OutOfMemory})!DtwResult {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0) return TsError.InvalidInput;

    const w: usize = if (band == 0) @max(n, m) else band;

    const size = std.math.mul(usize, n, m) catch return TsError.AllocationTooLarge;
    if (size > MAX_ALLOC_ELEMENTS) return TsError.AllocationTooLarge;
    const cost_flat = try allocator.alloc(f64, size);
    defer allocator.free(cost_flat);

    for (0..n) |i| {
        for (0..m) |j| {
            const diff = if (i >= j) i - j else j - i;
            if (diff > w) {
                cost_flat[i * m + j] = math.inf(f64);
                continue;
            }

            const d = a[i] - b[j];
            const local_cost = d * d;

            var min_prev: f64 = math.inf(f64);
            if (i > 0 and j > 0) min_prev = cost_flat[(i - 1) * m + (j - 1)];
            if (i > 0) min_prev = @min(min_prev, cost_flat[(i - 1) * m + j]);
            if (j > 0) min_prev = @min(min_prev, cost_flat[i * m + (j - 1)]);
            if (i == 0 and j == 0) min_prev = 0;

            cost_flat[i * m + j] = local_cost + min_prev;
        }
    }

    // Find the minimum cost in the last row (open-end on series b).
    var best_j: usize = 0;
    var best_cost: f64 = cost_flat[(n - 1) * m];
    for (1..m) |j| {
        if (cost_flat[(n - 1) * m + j] < best_cost) {
            best_cost = cost_flat[(n - 1) * m + j];
            best_j = j;
        }
    }

    const distance = @sqrt(best_cost);
    const path = try backtrackPath(allocator, cost_flat, m, n - 1, best_j);

    return DtwResult{
        .distance = distance,
        .path = path,
    };
}

/// Shape DTW: DTW using local shape descriptors of specified length.
pub fn shapeDTW(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    band: usize,
    descriptor_len: usize,
) (TsError || error{OutOfMemory})!DtwResult {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0 or descriptor_len == 0) return TsError.InvalidInput;

    const w: usize = if (band == 0) @max(n, m) else band;

    const size = std.math.mul(usize, n, m) catch return TsError.AllocationTooLarge;
    if (size > MAX_ALLOC_ELEMENTS) return TsError.AllocationTooLarge;
    const cost_flat = try allocator.alloc(f64, size);
    defer allocator.free(cost_flat);

    for (0..n) |i| {
        for (0..m) |j| {
            const diff_idx = if (i >= j) i - j else j - i;
            if (diff_idx > w) {
                cost_flat[i * m + j] = math.inf(f64);
                continue;
            }

            // Shape descriptor distance: sum of squared diffs in local windows.
            var local_cost: f64 = 0;
            const half = descriptor_len / 2;
            for (0..descriptor_len) |k| {
                const ai_idx = if (i + k >= half) i + k - half else 0;
                const bj_idx = if (j + k >= half) j + k - half else 0;
                const ai_val = if (ai_idx < n) a[ai_idx] else a[n - 1];
                const bj_val = if (bj_idx < m) b[bj_idx] else b[m - 1];
                const dd = ai_val - bj_val;
                local_cost += dd * dd;
            }

            var min_prev: f64 = math.inf(f64);
            if (i > 0 and j > 0) min_prev = cost_flat[(i - 1) * m + (j - 1)];
            if (i > 0) min_prev = @min(min_prev, cost_flat[(i - 1) * m + j]);
            if (j > 0) min_prev = @min(min_prev, cost_flat[i * m + (j - 1)]);
            if (i == 0 and j == 0) min_prev = 0;

            cost_flat[i * m + j] = local_cost + min_prev;
        }
    }

    const distance = @sqrt(cost_flat[(n - 1) * m + (m - 1)]);
    const path = try backtrackPath(allocator, cost_flat, m, n - 1, m - 1);

    return DtwResult{
        .distance = distance,
        .path = path,
    };
}

/// Soft DTW: differentiable distance using log-sum-exp smoothing.
/// Uses a 2-row rolling buffer instead of a full n*m matrix since only
/// the previous row is needed and no backtracking is performed.
pub fn softDTW(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    gamma: f64,
) (TsError || error{OutOfMemory})!f64 {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0) return TsError.InvalidInput;

    const g = if (gamma > 0) gamma else 1.0;

    // 2-row rolling buffer: prev_row holds row i-1, curr_row holds row i.
    if (m > MAX_ALLOC_ELEMENTS) return TsError.AllocationTooLarge;
    const prev_row = try allocator.alloc(f64, m);
    defer allocator.free(prev_row);
    const curr_row = try allocator.alloc(f64, m);
    defer allocator.free(curr_row);

    for (0..n) |i| {
        for (0..m) |j| {
            const d = a[i] - b[j];
            const local_cost = d * d;

            if (i == 0 and j == 0) {
                curr_row[0] = local_cost;
                continue;
            }

            // Soft minimum using -gamma * log(sum of exp(-x/gamma)).
            var candidates: [3]f64 = undefined;
            var count: usize = 0;

            if (i > 0 and j > 0) {
                candidates[count] = prev_row[j - 1];
                count += 1;
            }
            if (i > 0) {
                candidates[count] = prev_row[j];
                count += 1;
            }
            if (j > 0) {
                candidates[count] = curr_row[j - 1];
                count += 1;
            }

            if (count == 0) {
                curr_row[j] = local_cost;
                continue;
            }

            // Find min for numerical stability.
            var cmin = candidates[0];
            for (1..count) |k| {
                if (candidates[k] < cmin) cmin = candidates[k];
            }

            var sum_exp: f64 = 0;
            for (0..count) |k| {
                sum_exp += @exp(-(candidates[k] - cmin) / g);
            }

            const soft_min = cmin - g * @log(sum_exp);
            curr_row[j] = local_cost + soft_min;
        }

        // Swap: copy curr_row into prev_row for the next iteration.
        @memcpy(prev_row, curr_row);
    }

    // After the last row iteration, curr_row still holds the final row.
    return curr_row[m - 1];
}

/// LB_Keogh lower bound on DTW distance.
/// Uses precomputed upper/lower envelopes via monotonic deques for O(n) time.
///
/// This function takes bounded slices and a band width. Returns 0 for empty input.
pub fn lbKeogh(
    a: []const f64,
    b: []const f64,
    band: usize,
) f64 {
    if (a.len == 0 or b.len == 0) return 0;

    const n = a.len;
    const m = b.len;
    const len = @min(n, m);
    const w: usize = if (band == 0) len else band;

    // Precompute upper and lower envelopes for series b using monotonic deques.
    var upper_deque_buf: [8192]usize = undefined;
    var lower_deque_buf: [8192]usize = undefined;
    const use_stack = (m <= 8192);

    var upper_env_buf: [8192]f64 = undefined;
    var lower_env_buf: [8192]f64 = undefined;

    if (!use_stack) {
        // Fall back to O(n*w) inline computation for very large series.
        var lb: f64 = 0;
        for (0..len) |i| {
            const lo = if (i >= w) i - w else 0;
            const hi = @min(i + w + 1, m);

            var upper: f64 = -math.inf(f64);
            var lower: f64 = math.inf(f64);
            for (lo..hi) |j| {
                if (b[j] > upper) upper = b[j];
                if (b[j] < lower) lower = b[j];
            }

            if (a[i] > upper) {
                const d = a[i] - upper;
                lb += d * d;
            } else if (a[i] < lower) {
                const d = a[i] - lower;
                lb += d * d;
            }
        }
        return @sqrt(lb);
    }

    const upper_env = upper_env_buf[0..len];
    const lower_env = lower_env_buf[0..len];

    // Monotonic deque for max (upper envelope).
    {
        const dq = upper_deque_buf[0..m];
        var dq_front: usize = 0;
        var dq_back: usize = 0;
        var next_add: usize = 0;

        for (0..len) |i| {
            const lo = if (i >= w) i - w else 0;
            const hi = @min(i + w + 1, m);

            while (next_add < hi) {
                while (dq_back > dq_front and b[dq[dq_back - 1]] <= b[next_add]) {
                    dq_back -= 1;
                }
                dq[dq_back] = next_add;
                dq_back += 1;
                next_add += 1;
            }

            while (dq_front < dq_back and dq[dq_front] < lo) {
                dq_front += 1;
            }

            upper_env[i] = b[dq[dq_front]];
        }
    }

    // Monotonic deque for min (lower envelope).
    {
        var dq = lower_deque_buf[0..m];
        var dq_front: usize = 0;
        var dq_back: usize = 0;
        var next_add: usize = 0;

        for (0..len) |i| {
            const lo = if (i >= w) i - w else 0;
            const hi = @min(i + w + 1, m);

            while (next_add < hi) {
                while (dq_back > dq_front and b[dq[dq_back - 1]] >= b[next_add]) {
                    dq_back -= 1;
                }
                dq[dq_back] = next_add;
                dq_back += 1;
                next_add += 1;
            }

            while (dq_front < dq_back and dq[dq_front] < lo) {
                dq_front += 1;
            }

            lower_env[i] = b[dq[dq_front]];
        }
    }

    // Compute LB_Keogh using precomputed envelopes.
    var lb: f64 = 0;
    for (0..len) |i| {
        if (a[i] > upper_env[i]) {
            const d = a[i] - upper_env[i];
            lb += d * d;
        } else if (a[i] < lower_env[i]) {
            const d = a[i] - lower_env[i];
            lb += d * d;
        }
    }

    return @sqrt(lb);
}
