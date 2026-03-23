// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Matrix profile computation and MP-based distance.
//!
//! Uses the STOMP algorithm (Scalable Time-series Ordered-search Matrix Profile)
//! for O(n^2) self-join computation with incremental dot-product updates.
//!
//! References:
//! - Yeh et al., "Matrix Profile I: All Pairs Similarity Joins for Time Series", ICDM, 2016.
//! - Zhu et al., "Matrix Profile II: Exploiting a Novel Algorithm and GPUs", ICDM, 2016.
//! - Gharghabi et al., "Matrix Profile XII: MPdist", ICDM, 2018.

const std = @import("std");
const math = std.math;

/// Maximum series length for matrix profile operations to prevent CPU DoS.
const MAX_SERIES_LEN: usize = 100_000;

/// Threshold below which a standard deviation is treated as zero (constant subsequence).
const STD_EPS: f64 = 1e-10;

/// Compute z-normalized Euclidean distance between two subsequences.
/// Each subsequence is defined by a data pointer, a start offset, and a window length.
/// Handles edge cases: both-constant (distance 0) and one-constant (max distance).
fn zNormDist(
    values_a: [*]const f64,
    start_a: usize,
    values_b: [*]const f64,
    start_b: usize,
    w: usize,
) f64 {
    const wf: f64 = @floatFromInt(w);

    // Compute mean and std for subsequence a.
    var mean_a: f64 = 0;
    for (0..w) |k| mean_a += values_a[start_a + k];
    mean_a /= wf;

    var var_a: f64 = 0;
    for (0..w) |k| {
        const d = values_a[start_a + k] - mean_a;
        var_a += d * d;
    }
    const std_a: f64 = @sqrt(var_a / wf);

    // Compute mean and std for subsequence b.
    var mean_b: f64 = 0;
    for (0..w) |k| mean_b += values_b[start_b + k];
    mean_b /= wf;

    var var_b: f64 = 0;
    for (0..w) |k| {
        const d = values_b[start_b + k] - mean_b;
        var_b += d * d;
    }
    const std_b: f64 = @sqrt(var_b / wf);

    // Z-normalized Euclidean distance.
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
        return 0; // Both constant.
    } else {
        return @sqrt(wf); // Max distance for constant vs non-constant.
    }
}

/// Convert a dot product QT(i,j) to z-normalized Euclidean distance using
/// precomputed means and standard deviations.
///
/// Returns sqrt(2*w*(1 - (QT - w*mu_i*mu_j) / (w*std_i*std_j))) clamped to [0, inf).
/// Handles constant subsequences (std near zero) as special cases.
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
        // Pearson correlation from dot product:
        //   corr = (QT - w*mu_i*mu_j) / (w*std_i*std_j)
        const corr = (qt - wf * mu_i * mu_j) / (wf * std_i * std_j);
        // Clamp to [-1, 1] for numerical safety, then convert to distance.
        const clamped = @min(@as(f64, 1.0), @max(@as(f64, -1.0), corr));
        const dist_sq = 2.0 * wf * (1.0 - clamped);
        // Clamp to non-negative for numerical safety before sqrt.
        return @sqrt(@max(@as(f64, 0.0), dist_sq));
    } else if (std_i <= STD_EPS and std_j <= STD_EPS) {
        return 0; // Both constant.
    } else {
        return @sqrt(wf); // Max distance for constant vs non-constant.
    }
}

/// Precompute subsequence means and standard deviations using cumulative sums.
/// means and stds must be pre-allocated slices of length plen = n - w + 1.
fn precomputeStats(
    values: [*]const f64,
    n: usize,
    w: usize,
    means: []f64,
    stds: []f64,
) void {
    const plen = n - w + 1;
    const wf: f64 = @floatFromInt(w);

    // Compute cumulative sums for mean calculation: cum_sum[i] = sum(values[0..i]).
    // We use an incremental approach to avoid allocating an extra array.

    // First subsequence: compute mean and variance directly.
    var sum_val: f64 = 0;
    var sum_sq: f64 = 0;
    for (0..w) |k| {
        sum_val += values[k];
    }
    means[0] = sum_val / wf;

    // Compute variance for first window using the mean.
    for (0..w) |k| {
        const d = values[k] - means[0];
        sum_sq += d * d;
    }
    stds[0] = @sqrt(sum_sq / wf);

    // Sliding window: update mean incrementally, recompute variance from mean.
    // For numerical stability with the variance, we use the two-pass approach
    // within the incremental framework: update the mean first, then compute
    // variance from scratch using the new mean. This matches the brute-force
    // computation exactly.
    //
    // However, recomputing variance from scratch for each window is O(n*w).
    // Instead, we use the incremental formula for both mean and variance sum:
    //   new_sum = old_sum - values[i-1] + values[i+w-1]
    //   new_mean = new_sum / w
    //   new_var_sum = old_var_sum + (values[i+w-1] - new_mean + old_mean - values[i-1])
    //                              * (values[i+w-1] - old_mean + new_mean - values[i-1])
    //                 ... this is complex and error-prone.
    //
    // For correctness, use the simple O(w) per-window computation since w is
    // typically small relative to n and the overall STOMP complexity is O(n^2).
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
fn dotProduct(values: [*]const f64, start_a: usize, start_b: usize, w: usize) f64 {
    var dp: f64 = 0;
    for (0..w) |k| {
        dp += values[start_a + k] * values[start_b + k];
    }
    return dp;
}

/// Compute the matrix profile and profile index for a series using the STOMP algorithm.
///
/// STOMP (Scalable Time-series Ordered-search Matrix Profile) computes the
/// self-join matrix profile in O(n^2) time by exploiting incremental dot-product
/// updates across successive query subsequences.
///
/// Algorithm:
/// 1. Precompute means and standard deviations for all subsequences in O(n*w).
/// 2. Compute initial distance profile for i=0 using direct dot products.
/// 3. For each subsequent row i>0, update dot products incrementally:
///    QT[j] = QT_prev[j-1] - values[i-1]*values[j-1] + values[i+w-1]*values[j+w-1]
/// 4. Convert dot products to z-normalized distances and track minima.
///
/// The exclusion zone skips indices j where |i-j| < w/4 + 1 to avoid trivial matches.
pub fn matrixProfile(
    allocator: std.mem.Allocator,
    values: [*]const f64,
    values_len: i32,
    window_len: i32,
    profile_out: [*]f64,
    indices_out: [*]i32,
    profile_len_out: *i32,
) i32 {
    if (values_len <= 0 or window_len <= 0) return -1;
    const n: usize = @intCast(values_len);
    const w: usize = @intCast(window_len);
    if (w > n) return -1;
    if (n > MAX_SERIES_LEN) return -1;

    const plen = n - w + 1;
    const exclusion_zone = w / 4 + 1;

    // For very small profiles where no comparisons are possible outside the
    // exclusion zone, fall back to setting infinity/0 for all entries.
    // This matches the brute-force behavior where every j is skipped.
    if (plen <= 1) {
        profile_out[0] = math.inf(f64);
        indices_out[0] = 0;
        profile_len_out.* = @intCast(plen);
        return 0;
    }

    // Allocate working arrays.
    const means = allocator.alloc(f64, plen) catch return -1;
    defer allocator.free(means);
    const stds = allocator.alloc(f64, plen) catch return -1;
    defer allocator.free(stds);
    const qt = allocator.alloc(f64, plen) catch return -1;
    defer allocator.free(qt);
    const qt_prev = allocator.alloc(f64, plen) catch return -1;
    defer allocator.free(qt_prev);

    // Precompute subsequence statistics.
    precomputeStats(values, n, w, means, stds);

    // Initialize profile to infinity.
    for (0..plen) |i| {
        profile_out[i] = math.inf(f64);
        indices_out[i] = 0;
    }

    // --- Row i=0: compute initial dot products and distance profile ---
    for (0..plen) |j| {
        qt[j] = dotProduct(values, 0, j, w);
    }

    // Update profile from row 0.
    for (0..plen) |j| {
        if (j < exclusion_zone) continue; // |0 - j| < exclusion_zone means j < exclusion_zone
        const dist = qtToZnormDist(qt[j], means[0], stds[0], means[j], stds[j], w);

        // Update profile[0] (row minimum).
        if (dist < profile_out[0]) {
            profile_out[0] = dist;
            indices_out[0] = @intCast(j);
        }
        // Update profile[j] (column minimum -- symmetric self-join).
        if (dist < profile_out[j]) {
            profile_out[j] = dist;
            indices_out[j] = 0;
        }
    }

    // --- Rows i=1..plen-1: incremental STOMP updates ---
    for (1..plen) |i| {
        // Swap qt and qt_prev.
        @memcpy(qt_prev, qt);

        // QT[j] for j=0 must be computed directly (no qt_prev[-1] exists).
        qt[0] = dotProduct(values, i, 0, w);

        // Incremental update for j=1..plen-1:
        //   QT_new[j] = QT_prev[j-1] - values[i-1]*values[j-1] + values[i+w-1]*values[j+w-1]
        for (1..plen) |j| {
            qt[j] = qt_prev[j - 1] - values[i - 1] * values[j - 1] + values[i + w - 1] * values[j + w - 1];
        }

        // Compute distances and update profile.
        for (0..plen) |j| {
            // Exclusion zone: skip if |i - j| < exclusion_zone.
            const diff = if (i >= j) i - j else j - i;
            if (diff < exclusion_zone) continue;

            const dist = qtToZnormDist(qt[j], means[i], stds[i], means[j], stds[j], w);

            // Update profile[i] (row minimum).
            if (dist < profile_out[i]) {
                profile_out[i] = dist;
                indices_out[i] = @intCast(j);
            }
            // Update profile[j] (column minimum -- symmetric self-join).
            if (dist < profile_out[j]) {
                profile_out[j] = dist;
                indices_out[j] = @intCast(i);
            }
        }
    }

    profile_len_out.* = @intCast(plen);
    return 0;
}

/// MP-based distance between two series using the AB-join matrix profile.
/// Returns the k-th smallest value in the AB-join profile where k = floor(plen * 0.05).
///
/// Optimized with precomputed means/stds and dot-product based distance computation
/// for the AB-join (cross-series comparison, no exclusion zone needed).
pub fn mpDist(
    allocator: std.mem.Allocator,
    a: [*]const f64,
    a_len: i32,
    b: [*]const f64,
    b_len: i32,
    window_len: i32,
    dist_out: *f64,
) i32 {
    if (a_len <= 0 or b_len <= 0 or window_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const w: usize = @intCast(window_len);
    if (w > n or w > m) return -1;
    if (n > MAX_SERIES_LEN or m > MAX_SERIES_LEN) return -1;

    const plen_a = n - w + 1;
    const plen_b = m - w + 1;

    // Compute AB-join: for each subsequence in A, find nearest neighbor in B.
    const ab_buf = allocator.alloc(f64, plen_a) catch return -1;
    defer allocator.free(ab_buf);

    // Precompute stats for series A and B.
    const means_a = allocator.alloc(f64, plen_a) catch return -1;
    defer allocator.free(means_a);
    const stds_a = allocator.alloc(f64, plen_a) catch return -1;
    defer allocator.free(stds_a);
    const means_b = allocator.alloc(f64, plen_b) catch return -1;
    defer allocator.free(means_b);
    const stds_b = allocator.alloc(f64, plen_b) catch return -1;
    defer allocator.free(stds_b);

    precomputeStats(a, n, w, means_a, stds_a);
    precomputeStats(b, m, w, means_b, stds_b);

    // AB-join: for each subsequence in A, find nearest neighbor in B.
    // Use precomputed stats with direct dot-product computation.
    for (0..plen_a) |i| {
        var best: f64 = math.inf(f64);
        for (0..plen_b) |j| {
            // Compute dot product between a[i..i+w] and b[j..j+w].
            var dp: f64 = 0;
            for (0..w) |k| {
                dp += a[i + k] * b[j + k];
            }
            const dist = qtToZnormDist(dp, means_a[i], stds_a[i], means_b[j], stds_b[j], w);
            if (dist < best) best = dist;
        }
        ab_buf[i] = best;
    }

    // Sort and pick the 5th percentile value.
    std.mem.sort(f64, ab_buf, {}, std.sort.asc(f64));
    const k = @max(1, plen_a * 5 / 100);
    dist_out.* = ab_buf[k - 1];
    return 0;
}
