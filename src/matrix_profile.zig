// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Matrix profile computation and MP-based distance.
//!
//! References:
//! - Yeh et al., "Matrix Profile I: All Pairs Similarity Joins for Time Series", ICDM, 2016.
//! - Gharghabi et al., "Matrix Profile XII: MPdist", ICDM, 2018.

const std = @import("std");
const math = std.math;

/// Maximum series length for matrix profile operations to prevent CPU DoS.
const MAX_SERIES_LEN: usize = 100_000;

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
    if (std_a > 1e-10 and std_b > 1e-10) {
        var dist: f64 = 0;
        for (0..w) |k| {
            const za = (values_a[start_a + k] - mean_a) / std_a;
            const zb = (values_b[start_b + k] - mean_b) / std_b;
            const dd = za - zb;
            dist += dd * dd;
        }
        return @sqrt(dist);
    } else if (std_a <= 1e-10 and std_b <= 1e-10) {
        return 0; // Both constant.
    } else {
        return @sqrt(wf); // Max distance for constant vs non-constant.
    }
}

/// Compute the matrix profile and profile index for a series.
/// Uses brute-force z-normalized Euclidean distance (STAMP-like).
pub fn matrixProfile(
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

    // Compute profile for each subsequence.
    for (0..plen) |i| {
        var best_dist: f64 = math.inf(f64);
        var best_idx: usize = 0;

        for (0..plen) |j| {
            // Skip trivial matches (within exclusion zone).
            const diff = if (i >= j) i - j else j - i;
            if (diff < w / 4 + 1) continue;

            const dist = zNormDist(values, i, values, j, w);

            if (dist < best_dist) {
                best_dist = dist;
                best_idx = j;
            }
        }

        profile_out[i] = best_dist;
        indices_out[i] = @intCast(best_idx);
    }

    profile_len_out.* = @intCast(plen);
    return 0;
}

/// MP-based distance between two series using the AB-join matrix profile.
/// Returns the k-th smallest value in the AB-join profile where k = floor(plen * 0.05).
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

    for (0..plen_a) |i| {
        var best: f64 = math.inf(f64);
        for (0..plen_b) |j| {
            const dist = zNormDist(a, i, b, j, w);
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
