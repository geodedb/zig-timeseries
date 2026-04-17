// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Matrix profile computation and MP-based distance.
//!
//! Uses the STOMP algorithm (Scalable Time-series Ordered-search Matrix Profile)
//! for O(n^2) self-join computation with incremental dot-product updates.
//!
//! All public functions use idiomatic Zig signatures:
//! - Bounded slices (`[]const f64`) instead of raw pointers + length pairs
//! - Error unions (`!`) instead of integer return codes
//! - Result structs instead of output pointer parameters
//!
//! References:
//! - Yeh et al., "Matrix Profile I: All Pairs Similarity Joins for Time Series", ICDM, 2016.
//! - Zhu et al., "Matrix Profile II: Exploiting a Novel Algorithm and GPUs", ICDM, 2016.
//! - Gharghabi et al., "Matrix Profile XII: MPdist", ICDM, 2018.

const std = @import("std");
const math = std.math;
const types = @import("types.zig");
const MatrixProfileResult = types.MatrixProfileResult;
const TsError = types.TsError;

/// Maximum series length for matrix profile operations to prevent CPU DoS.
const MAX_SERIES_LEN: usize = 100_000;

/// Threshold below which a standard deviation is treated as zero (constant subsequence).
const STD_EPS: f64 = 1e-10;

/// Compute z-normalized Euclidean distance between two subsequences.
fn zNormDist(
    values_a: []const f64,
    start_a: usize,
    values_b: []const f64,
    start_b: usize,
    w: usize,
) f64 {
    const wf: f64 = @floatFromInt(w);

    var mean_a: f64 = 0;
    for (0..w) |k| mean_a += values_a[start_a + k];
    mean_a /= wf;

    var var_a: f64 = 0;
    for (0..w) |k| {
        const d = values_a[start_a + k] - mean_a;
        var_a += d * d;
    }
    const std_a: f64 = @sqrt(var_a / wf);

    var mean_b: f64 = 0;
    for (0..w) |k| mean_b += values_b[start_b + k];
    mean_b /= wf;

    var var_b: f64 = 0;
    for (0..w) |k| {
        const d = values_b[start_b + k] - mean_b;
        var_b += d * d;
    }
    const std_b: f64 = @sqrt(var_b / wf);

    if (std_a > STD_EPS and std_b > STD_EPS) {
        var dist: f64 = 0;
        for (0..w) |k| {
            const za = (values_a[start_a + k] - mean_a) / std_a;
            const zb = (values_b[start_b + k] - mean_b) / std_b;
            const dd = za - zb;
            dist += dd * dd;
        }
        return @sqrt(dist);
    } else if (std_a <= STD_EPS and std_b <= STD_EPS) {
        return 0;
    } else {
        return @sqrt(wf);
    }
}

/// Convert a dot product QT(i,j) to z-normalized Euclidean distance.
inline fn qtToZnormDist(
    qt: f64,
    mu_i: f64,
    std_i: f64,
    mu_j: f64,
    std_j: f64,
    w: usize,
) f64 {
    const wf: f64 = @floatFromInt(w);

    if (std_i > STD_EPS and std_j > STD_EPS) {
        const corr = (qt - wf * mu_i * mu_j) / (wf * std_i * std_j);
        const clamped = @min(@as(f64, 1.0), @max(@as(f64, -1.0), corr));
        const dist_sq = 2.0 * wf * (1.0 - clamped);
        return @sqrt(@max(@as(f64, 0.0), dist_sq));
    } else if (std_i <= STD_EPS and std_j <= STD_EPS) {
        return 0;
    } else {
        return @sqrt(wf);
    }
}

/// Precompute subsequence means and standard deviations using cumulative sums.
pub fn precomputeStats(
    values: []const f64,
    w: usize,
    means: []f64,
    stds: []f64,
) void {
    const n = values.len;
    const plen = n - w + 1;
    const wf: f64 = @floatFromInt(w);

    var sum_val: f64 = 0;
    var sum_sq: f64 = 0;
    for (0..w) |k| {
        sum_val += values[k];
    }
    means[0] = sum_val / wf;

    for (0..w) |k| {
        const d = values[k] - means[0];
        sum_sq += d * d;
    }
    stds[0] = @sqrt(sum_sq / wf);

    for (1..plen) |i| {
        sum_val = sum_val - values[i - 1] + values[i + w - 1];
        means[i] = sum_val / wf;

        var var_sum: f64 = 0;
        for (0..w) |k| {
            const d = values[i + k] - means[i];
            var_sum += d * d;
        }
        stds[i] = @sqrt(var_sum / wf);
    }
}

/// Compute the dot product between subsequences values[start_a..+w] and values[start_b..+w].
fn dotProduct(values: []const f64, start_a: usize, start_b: usize, w: usize) f64 {
    var dp: f64 = 0;
    for (0..w) |k| {
        dp += values[start_a + k] * values[start_b + k];
    }
    return dp;
}

/// Compute the matrix profile and profile index for a series using the STOMP algorithm.
///
/// Returns a MatrixProfileResult with owned `profile` and `indices` slices.
/// The caller must free them via `result.deinit(allocator)`.
pub fn matrixProfile(
    allocator: std.mem.Allocator,
    values: []const f64,
    window_len: usize,
) (TsError || error{OutOfMemory})!MatrixProfileResult {
    const n = values.len;
    if (n == 0 or window_len == 0) return TsError.InvalidInput;
    if (window_len > n) return TsError.InvalidInput;
    if (n > MAX_SERIES_LEN) return TsError.SeriesTooLong;

    const w = window_len;
    const plen = n - w + 1;
    const exclusion_zone = w / 4 + 1;

    // Allocate result arrays.
    const profile = try allocator.alloc(f64, plen);
    errdefer allocator.free(profile);
    const indices = try allocator.alloc(usize, plen);
    errdefer allocator.free(indices);

    // For very small profiles where no comparisons are possible outside the
    // exclusion zone, return infinity for all entries.
    if (plen <= 1) {
        profile[0] = math.inf(f64);
        indices[0] = 0;
        return MatrixProfileResult{ .profile = profile, .indices = indices };
    }

    // Allocate working arrays.
    const means = try allocator.alloc(f64, plen);
    defer allocator.free(means);
    const stds = try allocator.alloc(f64, plen);
    defer allocator.free(stds);
    const qt = try allocator.alloc(f64, plen);
    defer allocator.free(qt);
    const qt_prev = try allocator.alloc(f64, plen);
    defer allocator.free(qt_prev);

    // Precompute subsequence statistics.
    precomputeStats(values, w, means, stds);

    // Initialize profile to infinity.
    for (0..plen) |i| {
        profile[i] = math.inf(f64);
        indices[i] = 0;
    }

    // --- Row i=0: compute initial dot products and distance profile ---
    for (0..plen) |j| {
        qt[j] = dotProduct(values, 0, j, w);
    }

    for (0..plen) |j| {
        if (j < exclusion_zone) continue;
        const dist = qtToZnormDist(qt[j], means[0], stds[0], means[j], stds[j], w);

        if (dist < profile[0]) {
            profile[0] = dist;
            indices[0] = j;
        }
        if (dist < profile[j]) {
            profile[j] = dist;
            indices[j] = 0;
        }
    }

    // --- Rows i=1..plen-1: incremental STOMP updates ---
    for (1..plen) |i| {
        @memcpy(qt_prev, qt);

        qt[0] = dotProduct(values, i, 0, w);

        for (1..plen) |j| {
            qt[j] = qt_prev[j - 1] - values[i - 1] * values[j - 1] + values[i + w - 1] * values[j + w - 1];
        }

        for (0..plen) |j| {
            const diff = if (i >= j) i - j else j - i;
            if (diff < exclusion_zone) continue;

            const dist = qtToZnormDist(qt[j], means[i], stds[i], means[j], stds[j], w);

            if (dist < profile[i]) {
                profile[i] = dist;
                indices[i] = j;
            }
            if (dist < profile[j]) {
                profile[j] = dist;
                indices[j] = i;
            }
        }
    }

    return MatrixProfileResult{ .profile = profile, .indices = indices };
}

/// Compute the best distance for a single `i` row of the AB-join matrix
/// profile between series `a` (with precomputed stats) and `b` (with
/// precomputed stats). Pure function — reads only the provided slices.
/// Exposed so `parallel.parallelMpDistAbJoin` can compute rows
/// independently across workers without duplicating the logic.
pub fn mpDistAbJoinRow(
    a: []const f64,
    b: []const f64,
    means_a: []const f64,
    stds_a: []const f64,
    means_b: []const f64,
    stds_b: []const f64,
    i: usize,
    window_len: usize,
) f64 {
    const w = window_len;
    const plen_b = means_b.len;
    var best: f64 = math.inf(f64);
    for (0..plen_b) |j| {
        var dp: f64 = 0;
        for (0..w) |k| {
            dp += a[i + k] * b[j + k];
        }
        const dist = qtToZnormDist(dp, means_a[i], stds_a[i], means_b[j], stds_b[j], w);
        if (dist < best) best = dist;
    }
    return best;
}

/// MP-based distance between two series using the AB-join matrix profile.
/// Returns the k-th smallest value in the AB-join profile where k = floor(plen * 0.05).
pub fn mpDist(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    window_len: usize,
) (TsError || error{OutOfMemory})!f64 {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0 or window_len == 0) return TsError.InvalidInput;
    if (window_len > n or window_len > m) return TsError.InvalidInput;
    if (n > MAX_SERIES_LEN or m > MAX_SERIES_LEN) return TsError.SeriesTooLong;

    const w = window_len;
    const plen_a = n - w + 1;
    const plen_b = m - w + 1;

    const ab_buf = try allocator.alloc(f64, plen_a);
    defer allocator.free(ab_buf);

    const means_a = try allocator.alloc(f64, plen_a);
    defer allocator.free(means_a);
    const stds_a = try allocator.alloc(f64, plen_a);
    defer allocator.free(stds_a);
    const means_b = try allocator.alloc(f64, plen_b);
    defer allocator.free(means_b);
    const stds_b = try allocator.alloc(f64, plen_b);
    defer allocator.free(stds_b);

    precomputeStats(a, w, means_a, stds_a);
    precomputeStats(b, w, means_b, stds_b);

    for (0..plen_a) |i| {
        ab_buf[i] = mpDistAbJoinRow(a, b, means_a, stds_a, means_b, stds_b, i, w);
    }

    std.mem.sort(f64, ab_buf, {}, std.sort.asc(f64));
    const k = @max(1, plen_a * 5 / 100);
    return ab_buf[k - 1];
}
