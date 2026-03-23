// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Non-DTW distance functions: cross-correlation, SBD, LCSS, EDR, ERP, TWED.
//!
//! All public functions use idiomatic Zig signatures:
//! - Bounded slices (`[]const f64`) instead of raw pointers + length pairs
//! - Error unions (`!`) instead of integer return codes
//! - Result structs instead of output pointer parameters
//!
//! References:
//! - Vlachos et al., "Discovering similar multidimensional trajectories", ICDE, 2002 (LCSS).
//! - Chen & Ng, "On the marriage of Lp-norms and edit distance", VLDB, 2004 (EDR).
//! - Chen et al., "Robust and fast similarity search for moving object trajectories", SIGMOD, 2005 (ERP).
//! - Marteau, "Time Warp Edit Distance with Stiffness Adjustment", IEEE TPAMI, 2009 (TWED).
//! - Paparrizos & Gravano, "k-Shape: Efficient and Accurate Clustering of Time Series", SIGMOD, 2015 (SBD).

const std = @import("std");
const math = std.math;
const types = @import("types.zig");
const CorrelationResult = types.CorrelationResult;
const TsError = types.TsError;

/// Maximum number of f64 elements allowed in a single allocation (256 MB cap).
const MAX_ALLOC_F64: usize = 256 * 1024 * 1024 / @sizeOf(f64);

/// Maximum number of i32 elements allowed in a single allocation (256 MB cap).
const MAX_ALLOC_I32: usize = 256 * 1024 * 1024 / @sizeOf(i32);

/// Threshold below which brute-force cross-correlation is faster than FFT.
const FFT_THRESHOLD: usize = 64;

/// Radix-2 Cooley-Tukey in-place FFT (or inverse FFT).
/// `real` and `imag` are modified in-place. `n` must be a power of 2.
fn fft(real: []f64, imag: []f64, n: usize, inverse: bool) void {
    // Bit-reversal permutation.
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            std.mem.swap(f64, &real[i], &real[j]);
            std.mem.swap(f64, &imag[i], &imag[j]);
        }
    }

    // Butterfly stages.
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const angle = 2.0 * math.pi / @as(f64, @floatFromInt(len)) *
            if (inverse) @as(f64, -1.0) else @as(f64, 1.0);
        const wlen_r = @cos(angle);
        const wlen_i = @sin(angle);
        var i: usize = 0;
        while (i < n) : (i += len) {
            var w_r: f64 = 1.0;
            var w_i: f64 = 0.0;
            for (0..len / 2) |k| {
                const u_r = real[i + k];
                const u_i = imag[i + k];
                const v_r = real[i + k + len / 2] * w_r - imag[i + k + len / 2] * w_i;
                const v_i = real[i + k + len / 2] * w_i + imag[i + k + len / 2] * w_r;
                real[i + k] = u_r + v_r;
                imag[i + k] = u_i + v_i;
                real[i + k + len / 2] = u_r - v_r;
                imag[i + k + len / 2] = u_i - v_i;
                const new_w_r = w_r * wlen_r - w_i * wlen_i;
                const new_w_i = w_r * wlen_i + w_i * wlen_r;
                w_r = new_w_r;
                w_i = new_w_i;
            }
        }
    }

    if (inverse) {
        const inv_n = 1.0 / @as(f64, @floatFromInt(n));
        for (0..n) |i| {
            real[i] *= inv_n;
            imag[i] *= inv_n;
        }
    }
}

/// Return the smallest power of 2 >= v.
fn nextPowerOf2(v: usize) usize {
    if (v == 0) return 1;
    var p: usize = 1;
    while (p < v) p <<= 1;
    return p;
}

/// Brute-force cross-correlation for small inputs.
fn crossCorrelateBruteForce(
    a: []const f64,
    mean_a: f64,
    norm_a: f64,
    b: []const f64,
    mean_b: f64,
    norm_b: f64,
) CorrelationResult {
    const n = a.len;
    const m = b.len;
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

    return .{ .lag = best_lag, .correlation = best_corr };
}

/// FFT-based cross-correlation for large inputs. O(n log n) instead of O(n^2).
/// Returns null on allocation failure.
fn crossCorrelateFFT(
    a: []const f64,
    mean_a: f64,
    norm_a: f64,
    b: []const f64,
    mean_b: f64,
    norm_b: f64,
) ?CorrelationResult {
    const page_allocator = std.heap.page_allocator;
    const n = a.len;
    const m = b.len;
    const conv_len = n + m - 1;
    const fft_size = nextPowerOf2(conv_len);

    if (fft_size > MAX_ALLOC_F64) return null;

    const ar = page_allocator.alloc(f64, fft_size) catch return null;
    defer page_allocator.free(ar);
    const ai = page_allocator.alloc(f64, fft_size) catch return null;
    defer page_allocator.free(ai);
    const br = page_allocator.alloc(f64, fft_size) catch return null;
    defer page_allocator.free(br);
    const bi = page_allocator.alloc(f64, fft_size) catch return null;
    defer page_allocator.free(bi);

    for (0..fft_size) |i| {
        ar[i] = if (i < n) a[i] - mean_a else 0;
        ai[i] = 0;
        br[i] = if (i < m) b[i] - mean_b else 0;
        bi[i] = 0;
    }

    fft(ar, ai, fft_size, false);
    fft(br, bi, fft_size, false);

    for (0..fft_size) |i| {
        const r = ar[i] * br[i] + ai[i] * bi[i];
        const im = ai[i] * br[i] - ar[i] * bi[i];
        ar[i] = r;
        ai[i] = im;
    }

    fft(ar, ai, fft_size, true);

    const norm_product = norm_a * norm_b;
    var best_corr: f64 = -math.inf(f64);
    var best_lag: i32 = 0;
    const max_lag_pos: usize = n - 1;
    const max_lag_neg: usize = m - 1;

    for (0..max_lag_pos + 1) |k| {
        const ncc = ar[k] / norm_product;
        if (ncc > best_corr) {
            best_corr = ncc;
            best_lag = @intCast(k);
        }
    }

    for (1..max_lag_neg + 1) |k| {
        const ncc = ar[fft_size - k] / norm_product;
        const lag_val: i32 = -@as(i32, @intCast(k));
        if (ncc > best_corr) {
            best_corr = ncc;
            best_lag = lag_val;
        }
    }

    return .{ .lag = best_lag, .correlation = best_corr };
}

/// Normalized cross-correlation returning optimal lag and correlation.
/// Uses FFT-based O(n log n) algorithm for large inputs and brute-force
/// O(n^2) for small inputs (n,m < 64) where FFT overhead is not worthwhile.
pub fn crossCorrelate(
    a: []const f64,
    b: []const f64,
) TsError!CorrelationResult {
    if (a.len == 0 or b.len == 0) return TsError.InvalidInput;
    const n = a.len;
    const m = b.len;

    // Compute means and norms.
    var mean_a: f64 = 0;
    for (a) |v| mean_a += v;
    mean_a /= @as(f64, @floatFromInt(n));

    var mean_b: f64 = 0;
    for (b) |v| mean_b += v;
    mean_b /= @as(f64, @floatFromInt(m));

    var norm_a: f64 = 0;
    for (a) |v| {
        const d = v - mean_a;
        norm_a += d * d;
    }
    norm_a = @sqrt(norm_a);

    var norm_b: f64 = 0;
    for (b) |v| {
        const d = v - mean_b;
        norm_b += d * d;
    }
    norm_b = @sqrt(norm_b);

    if (norm_a == 0 or norm_b == 0) {
        return CorrelationResult{
            .lag = 0,
            .correlation = if (norm_a == 0 and norm_b == 0) 1.0 else 0.0,
        };
    }

    // Use brute-force for small inputs where FFT overhead is not worthwhile.
    if (n < FFT_THRESHOLD and m < FFT_THRESHOLD) {
        return crossCorrelateBruteForce(a, mean_a, norm_a, b, mean_b, norm_b);
    }

    // Use FFT-based O(n log n) cross-correlation for larger inputs.
    // Falls back to brute-force if allocation fails.
    if (crossCorrelateFFT(a, mean_a, norm_a, b, mean_b, norm_b)) |result| {
        return result;
    }

    return crossCorrelateBruteForce(a, mean_a, norm_a, b, mean_b, norm_b);
}

/// Shape-based distance (1 - max NCC), range [0, 2].
pub fn sbd(
    a: []const f64,
    b: []const f64,
) TsError!f64 {
    const result = try crossCorrelate(a, b);
    return 1.0 - result.correlation;
}

/// LCSS: Longest Common Subsequence distance.
/// Returns 1 - (LCSS_count / min(n, m)).
/// Uses a 2-row rolling buffer instead of a full (n+1)*(m+1) matrix.
pub fn lcss(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    epsilon: f64,
    delta: usize,
) (TsError || error{OutOfMemory})!f64 {
    if (a.len == 0 or b.len == 0) return TsError.InvalidInput;
    const n = a.len;
    const m = b.len;

    const d: usize = if (delta == 0) @max(n, m) else delta;
    const cols = m + 1;

    if (cols > MAX_ALLOC_I32) return TsError.AllocationTooLarge;
    const prev = try allocator.alloc(i32, cols);
    defer allocator.free(prev);
    const curr = try allocator.alloc(i32, cols);
    defer allocator.free(curr);

    for (0..cols) |j| prev[j] = 0;

    for (1..n + 1) |i| {
        curr[0] = 0;
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
    return 1.0 - lcss_count / min_len;
}

/// EDR: Edit Distance on Real Sequences.
/// Returns normalized edit distance.
pub fn edr(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    epsilon: f64,
) (TsError || error{OutOfMemory})!f64 {
    if (a.len == 0 or b.len == 0) return TsError.InvalidInput;
    const n = a.len;
    const m = b.len;

    const cols = m + 1;
    if (cols > MAX_ALLOC_I32) return TsError.AllocationTooLarge;
    const prev = try allocator.alloc(i32, cols);
    defer allocator.free(prev);
    const curr = try allocator.alloc(i32, cols);
    defer allocator.free(curr);

    for (0..cols) |j| prev[j] = @intCast(j);

    for (1..n + 1) |i| {
        curr[0] = @intCast(i);
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
    return edit / max_len;
}

/// ERP: Edit distance with Real Penalty.
pub fn erp(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    gap_value: f64,
) (TsError || error{OutOfMemory})!f64 {
    if (a.len == 0 or b.len == 0) return TsError.InvalidInput;
    const n = a.len;
    const m = b.len;

    const cols = m + 1;
    if (cols > MAX_ALLOC_F64) return TsError.AllocationTooLarge;
    const prev = try allocator.alloc(f64, cols);
    defer allocator.free(prev);
    const curr = try allocator.alloc(f64, cols);
    defer allocator.free(curr);

    prev[0] = 0;
    for (1..m + 1) |j| {
        prev[j] = prev[j - 1] + @abs(b[j - 1] - gap_value);
    }

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

    return curr[m];
}

/// TWED: Time Warp Edit Distance.
pub fn twed(
    allocator: std.mem.Allocator,
    a: []const f64,
    a_times: []const f64,
    b: []const f64,
    b_times: []const f64,
    lambda: f64,
    nu: f64,
) (TsError || error{OutOfMemory})!f64 {
    if (a.len == 0 or b.len == 0) return TsError.InvalidInput;
    if (a.len != a_times.len or b.len != b_times.len) return TsError.InvalidInput;
    const n = a.len;
    const m = b.len;

    const cols = m + 1;
    if (cols > MAX_ALLOC_F64) return TsError.AllocationTooLarge;
    const prev = try allocator.alloc(f64, cols);
    defer allocator.free(prev);
    const curr = try allocator.alloc(f64, cols);
    defer allocator.free(curr);

    prev[0] = 0;
    for (1..m + 1) |j| prev[j] = math.inf(f64);

    for (1..n + 1) |i| {
        curr[0] = math.inf(f64);
        for (1..m + 1) |j| {
            const d_match = @abs(a[i - 1] - b[j - 1]);
            var cost_match = prev[j - 1] + d_match;
            if (i > 1 and j > 1) {
                cost_match += nu * @abs(a_times[i - 1] - a_times[i - 2] - (b_times[j - 1] - b_times[j - 2]));
            }

            var cost_del_a = prev[j] + @abs(a[i - 1] - a[if (i > 1) i - 2 else 0]) + lambda;
            if (i > 1) {
                cost_del_a += nu * @abs(a_times[i - 1] - a_times[i - 2]);
            }

            var cost_del_b = curr[j - 1] + @abs(b[j - 1] - b[if (j > 1) j - 2 else 0]) + lambda;
            if (j > 1) {
                cost_del_b += nu * @abs(b_times[j - 1] - b_times[j - 2]);
            }

            curr[j] = @min(cost_match, @min(cost_del_a, cost_del_b));
        }
        @memcpy(prev, curr);
    }

    return curr[m];
}
