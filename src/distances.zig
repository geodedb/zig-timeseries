// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Non-DTW distance functions: cross-correlation, SBD, LCSS, EDR, ERP, TWED.
//!
//! References:
//! - Vlachos et al., "Discovering similar multidimensional trajectories", ICDE, 2002 (LCSS).
//! - Chen & Ng, "On the marriage of Lp-norms and edit distance", VLDB, 2004 (EDR).
//! - Chen et al., "Robust and fast similarity search for moving object trajectories", SIGMOD, 2005 (ERP).
//! - Marteau, "Time Warp Edit Distance with Stiffness Adjustment", IEEE TPAMI, 2009 (TWED).
//! - Paparrizos & Gravano, "k-Shape: Efficient and Accurate Clustering of Time Series", SIGMOD, 2015 (SBD).

const std = @import("std");
const math = std.math;

/// Maximum number of f64 elements allowed in a single allocation (256 MB cap).
const MAX_ALLOC_F64: usize = 256 * 1024 * 1024 / @sizeOf(f64);

/// Maximum number of i32 elements allowed in a single allocation (256 MB cap).
const MAX_ALLOC_I32: usize = 256 * 1024 * 1024 / @sizeOf(i32);

/// Normalized cross-correlation returning optimal lag and correlation.
pub fn crossCorrelate(
    a: [*]const f64,
    a_len: i32,
    b: [*]const f64,
    b_len: i32,
    lag_out: *i32,
    corr_out: *f64,
) i32 {
    if (a_len <= 0 or b_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);

    // Compute means and norms.
    var mean_a: f64 = 0;
    for (0..n) |i| mean_a += a[i];
    mean_a /= @as(f64, @floatFromInt(n));

    var mean_b: f64 = 0;
    for (0..m) |i| mean_b += b[i];
    mean_b /= @as(f64, @floatFromInt(m));

    var norm_a: f64 = 0;
    for (0..n) |i| {
        const d = a[i] - mean_a;
        norm_a += d * d;
    }
    norm_a = @sqrt(norm_a);

    var norm_b: f64 = 0;
    for (0..m) |i| {
        const d = b[i] - mean_b;
        norm_b += d * d;
    }
    norm_b = @sqrt(norm_b);

    if (norm_a == 0 or norm_b == 0) {
        lag_out.* = 0;
        corr_out.* = if (norm_a == 0 and norm_b == 0) 1.0 else 0.0;
        return 0;
    }

    const max_lag: i32 = @intCast(@max(n, m) - 1);
    var best_corr: f64 = -math.inf(f64);
    var best_lag: i32 = 0;

    var lag: i32 = -max_lag;
    while (lag <= max_lag) : (lag += 1) {
        var cc: f64 = 0;
        const start_a: usize = if (lag >= 0) @intCast(lag) else 0;
        const start_b: usize = if (lag < 0) @intCast(-lag) else 0;

        var ia = start_a;
        var ib = start_b;
        while (ia < n and ib < m) {
            cc += (a[ia] - mean_a) * (b[ib] - mean_b);
            ia += 1;
            ib += 1;
        }

        const ncc = cc / (norm_a * norm_b);
        if (ncc > best_corr) {
            best_corr = ncc;
            best_lag = lag;
        }
    }

    lag_out.* = best_lag;
    corr_out.* = best_corr;
    return 0;
}

/// Shape-based distance (1 - max NCC), range [0, 2].
pub fn sbd(
    a: [*]const f64,
    a_len: i32,
    b: [*]const f64,
    b_len: i32,
    dist_out: *f64,
) i32 {
    var lag: i32 = undefined;
    var corr: f64 = undefined;
    const rc = crossCorrelate(a, a_len, b, b_len, &lag, &corr);
    if (rc != 0) return rc;
    dist_out.* = 1.0 - corr;
    return 0;
}

/// LCSS: Longest Common Subsequence distance.
/// Returns 1 - (LCSS_count / min(n, m)).
/// Uses a 2-row rolling buffer instead of a full (n+1)*(m+1) matrix.
pub fn lcss(
    allocator: std.mem.Allocator,
    a: [*]const f64,
    a_len: i32,
    b: [*]const f64,
    b_len: i32,
    epsilon: f64,
    delta: i32,
    dist_out: *f64,
) i32 {
    if (a_len <= 0 or b_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);

    const d: usize = if (delta <= 0) @max(n, m) else @intCast(delta);
    const cols = m + 1;

    if (cols > MAX_ALLOC_I32) return -1;
    const prev = allocator.alloc(i32, cols) catch return -1;
    defer allocator.free(prev);
    const curr = allocator.alloc(i32, cols) catch return -1;
    defer allocator.free(curr);

    // Initialize row 0: all zeros.
    for (0..cols) |j| prev[j] = 0;

    for (1..n + 1) |i| {
        curr[0] = 0; // Column 0 is always 0.
        for (1..m + 1) |j| {
            const idx_diff = if (i - 1 >= j - 1) i - 1 - (j - 1) else j - 1 - (i - 1);
            if (idx_diff <= d and @abs(a[i - 1] - b[j - 1]) <= epsilon) {
                curr[j] = prev[j - 1] + 1;
            } else {
                curr[j] = @max(prev[j], curr[j - 1]);
            }
        }
        @memcpy(prev, curr);
    }

    const lcss_count: f64 = @floatFromInt(curr[m]);
    const min_len: f64 = @floatFromInt(@min(n, m));
    dist_out.* = 1.0 - lcss_count / min_len;
    return 0;
}

/// EDR: Edit Distance on Real Sequences.
/// Returns normalized edit distance.
/// Uses a 2-row rolling buffer instead of a full (n+1)*(m+1) matrix.
pub fn edr(
    allocator: std.mem.Allocator,
    a: [*]const f64,
    a_len: i32,
    b: [*]const f64,
    b_len: i32,
    epsilon: f64,
    dist_out: *f64,
) i32 {
    if (a_len <= 0 or b_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);

    const cols = m + 1;
    if (cols > MAX_ALLOC_I32) return -1;
    const prev = allocator.alloc(i32, cols) catch return -1;
    defer allocator.free(prev);
    const curr = allocator.alloc(i32, cols) catch return -1;
    defer allocator.free(curr);

    // Initialize row 0: dp[0][j] = j.
    for (0..cols) |j| prev[j] = @intCast(j);

    for (1..n + 1) |i| {
        curr[0] = @intCast(i); // dp[i][0] = i.
        for (1..m + 1) |j| {
            const subcost: i32 = if (@abs(a[i - 1] - b[j - 1]) <= epsilon) 0 else 1;
            const diag = prev[j - 1] + subcost;
            const up = prev[j] + 1;
            const left = curr[j - 1] + 1;
            curr[j] = @min(diag, @min(up, left));
        }
        @memcpy(prev, curr);
    }

    const edit: f64 = @floatFromInt(curr[m]);
    const max_len: f64 = @floatFromInt(@max(n, m));
    dist_out.* = edit / max_len;
    return 0;
}

/// ERP: Edit distance with Real Penalty.
/// Uses a 2-row rolling buffer instead of a full (n+1)*(m+1) matrix.
pub fn erp(
    allocator: std.mem.Allocator,
    a: [*]const f64,
    a_len: i32,
    b: [*]const f64,
    b_len: i32,
    gap_value: f64,
    dist_out: *f64,
) i32 {
    if (a_len <= 0 or b_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);

    const cols = m + 1;
    if (cols > MAX_ALLOC_F64) return -1;
    const prev = allocator.alloc(f64, cols) catch return -1;
    defer allocator.free(prev);
    const curr = allocator.alloc(f64, cols) catch return -1;
    defer allocator.free(curr);

    // Initialize row 0: dp[0][0] = 0, dp[0][j] = dp[0][j-1] + |b[j-1] - gap|.
    prev[0] = 0;
    for (1..m + 1) |j| {
        prev[j] = prev[j - 1] + @abs(b[j - 1] - gap_value);
    }

    // Track cumulative column-0 value (dp[i][0]).
    var col0: f64 = 0;

    for (1..n + 1) |i| {
        col0 += @abs(a[i - 1] - gap_value);
        curr[0] = col0;
        for (1..m + 1) |j| {
            const diag = prev[j - 1] + @abs(a[i - 1] - b[j - 1]);
            const up = prev[j] + @abs(a[i - 1] - gap_value);
            const left = curr[j - 1] + @abs(b[j - 1] - gap_value);
            curr[j] = @min(diag, @min(up, left));
        }
        @memcpy(prev, curr);
    }

    dist_out.* = curr[m];
    return 0;
}

/// TWED: Time Warp Edit Distance.
/// Uses a 2-row rolling buffer instead of a full (n+1)*(m+1) matrix.
pub fn twed(
    allocator: std.mem.Allocator,
    a: [*]const f64,
    a_len: i32,
    a_times: [*]const f64,
    b: [*]const f64,
    b_len: i32,
    b_times: [*]const f64,
    lambda: f64,
    nu: f64,
    dist_out: *f64,
) i32 {
    if (a_len <= 0 or b_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);

    const cols = m + 1;
    if (cols > MAX_ALLOC_F64) return -1;
    const prev = allocator.alloc(f64, cols) catch return -1;
    defer allocator.free(prev);
    const curr = allocator.alloc(f64, cols) catch return -1;
    defer allocator.free(curr);

    // Initialize row 0: dp[0][0] = 0, dp[0][j] = inf.
    prev[0] = 0;
    for (1..m + 1) |j| prev[j] = math.inf(f64);

    for (1..n + 1) |i| {
        curr[0] = math.inf(f64); // dp[i][0] = inf.
        for (1..m + 1) |j| {
            // Match: a[i-1] with b[j-1].
            const d_match = @abs(a[i - 1] - b[j - 1]);
            var cost_match = prev[j - 1] + d_match;
            if (i > 1 and j > 1) {
                cost_match += nu * @abs(a_times[i - 1] - a_times[i - 2] - (b_times[j - 1] - b_times[j - 2]));
            }

            // Delete from a.
            var cost_del_a = prev[j] + @abs(a[i - 1] - a[if (i > 1) i - 2 else 0]) + lambda;
            if (i > 1) {
                cost_del_a += nu * @abs(a_times[i - 1] - a_times[i - 2]);
            }

            // Delete from b.
            var cost_del_b = curr[j - 1] + @abs(b[j - 1] - b[if (j > 1) j - 2 else 0]) + lambda;
            if (j > 1) {
                cost_del_b += nu * @abs(b_times[j - 1] - b_times[j - 2]);
            }

            curr[j] = @min(cost_match, @min(cost_del_a, cost_del_b));
        }
        @memcpy(prev, curr);
    }

    dist_out.* = curr[m];
    return 0;
}
