// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Feature extraction and similarity functions.

const std = @import("std");
const math = std.math;

/// Named indices into the 22-element feature vector produced by extractFeatures.
pub const FeatureIndex = struct {
    pub const length: usize = 0;
    pub const mean: usize = 1;
    pub const std_dev: usize = 2;
    pub const min: usize = 3;
    pub const max: usize = 4;
    pub const range: usize = 5;
    pub const median: usize = 6;
    pub const skewness: usize = 7;
    pub const kurtosis: usize = 8;
    pub const first: usize = 9;
    pub const last: usize = 10;
    pub const slope: usize = 11;
    pub const hist_start: usize = 12;
    pub const hist_end: usize = 22;
    pub const feature_count: usize = 22;
};

/// Extract a 22-element feature vector from a series.
///
/// Features: [0] length, [1] mean, [2] std, [3] min, [4] max, [5] range,
/// [6] median, [7] skewness, [8] kurtosis, [9] first, [10] last,
/// [11] slope (linear trend), [12-21] 10-bin histogram of z-normalized values.
///
/// Performance: Uses fused loops to minimize cache misses.
///   Pass 1: sum + min + max (single traversal).
///   Pass 2: variance + skewness + kurtosis + slope (single traversal, needs mean).
///   Sort:   median computation (unavoidable O(n log n)).
///   Pass 3: histogram (needs std_dev from pass 2).
pub fn extractFeatures(
    allocator: std.mem.Allocator,
    values: [*]const f64,
    values_len: i32,
    features_out: [*]f64,
) i32 {
    if (values_len <= 0) return -1;
    const n: usize = @intCast(values_len);

    const nf: f64 = @floatFromInt(n);

    // --- Pass 1: sum, min, max in a single traversal ---
    var sum: f64 = values[0];
    var min_val: f64 = values[0];
    var max_val: f64 = values[0];
    for (1..n) |i| {
        const v = values[i];
        sum += v;
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }
    const mean = sum / nf;

    // --- Pass 2: variance, skewness, kurtosis, slope in a single traversal ---
    // All of these need the mean computed in pass 1.
    const i_mean = (nf - 1.0) / 2.0;
    var var_sum: f64 = 0;
    var m3: f64 = 0;
    var m4: f64 = 0;
    var slope_num: f64 = 0;
    var slope_den: f64 = 0;
    for (0..n) |i| {
        const v = values[i];
        const d = v - mean;
        const d2 = d * d;
        var_sum += d2;
        m3 += d * d2;
        m4 += d2 * d2;
        const fi: f64 = @floatFromInt(i);
        const di = fi - i_mean;
        slope_num += di * d;
        slope_den += di * di;
    }
    const variance = var_sum / nf;
    const std_dev = @sqrt(variance);
    m3 /= nf;
    m4 /= nf;
    const skewness = if (std_dev > 1e-10) m3 / (std_dev * std_dev * std_dev) else 0;
    const kurtosis = if (std_dev > 1e-10) m4 / (variance * variance) - 3.0 else 0;
    const slope = if (slope_den > 1e-10) slope_num / slope_den else 0;

    // --- Sort for median (unavoidable separate pass) ---
    const sort_buf = allocator.alloc(f64, n) catch return -1;
    defer allocator.free(sort_buf);
    for (0..n) |i| sort_buf[i] = values[i];
    std.mem.sort(f64, sort_buf, {}, std.sort.asc(f64));
    const median = if (n % 2 == 1)
        sort_buf[n / 2]
    else
        (sort_buf[n / 2 - 1] + sort_buf[n / 2]) / 2.0;

    // --- Pass 3: 10-bin histogram of z-normalized values (range [-3, 3]) ---
    var hist: [10]f64 = .{0} ** 10;
    for (0..n) |i| {
        const z = if (std_dev > 1e-10) (values[i] - mean) / std_dev else 0;
        const clamped = @max(-3.0, @min(3.0, z));
        const bin_f = (clamped + 3.0) / 6.0 * 10.0;
        const bin: usize = @min(9, @as(usize, @intFromFloat(bin_f)));
        hist[bin] += 1.0;
    }
    // Normalize histogram.
    for (0..10) |i| hist[i] /= nf;

    // Pack features using named indices.
    features_out[FeatureIndex.length] = nf;
    features_out[FeatureIndex.mean] = mean;
    features_out[FeatureIndex.std_dev] = std_dev;
    features_out[FeatureIndex.min] = min_val;
    features_out[FeatureIndex.max] = max_val;
    features_out[FeatureIndex.range] = max_val - min_val;
    features_out[FeatureIndex.median] = median;
    features_out[FeatureIndex.skewness] = skewness;
    features_out[FeatureIndex.kurtosis] = kurtosis;
    features_out[FeatureIndex.first] = values[0];
    features_out[FeatureIndex.last] = values[n - 1];
    features_out[FeatureIndex.slope] = slope;
    for (0..10) |i| features_out[FeatureIndex.hist_start + i] = hist[i];

    return 0;
}

/// Cosine similarity between two vectors.
/// Uses @Vector(4, f64) SIMD for the inner accumulation loop.
pub fn cosineSimilarity(
    a: [*]const f64,
    b: [*]const f64,
    len: i32,
) f64 {
    if (len < 0) return 0;
    const n: usize = @intCast(len);
    if (n == 0) return 0;

    const Vec4 = @Vector(4, f64);
    const zero: Vec4 = @splat(0.0);
    var dot_v: Vec4 = zero;
    var norm_a_v: Vec4 = zero;
    var norm_b_v: Vec4 = zero;

    const a_slice = a[0..n];
    const b_slice = b[0..n];

    const chunks = n / 4;
    for (0..chunks) |c| {
        const base = c * 4;
        const ai: Vec4 = a_slice[base..][0..4].*;
        const bi: Vec4 = b_slice[base..][0..4].*;
        dot_v += ai * bi;
        norm_a_v += ai * ai;
        norm_b_v += bi * bi;
    }

    // Reduce vectors to scalars.
    var dot = @reduce(.Add, dot_v);
    var norm_a_acc = @reduce(.Add, norm_a_v);
    var norm_b_acc = @reduce(.Add, norm_b_v);

    // Handle remaining elements (n mod 4).
    const remainder_start = chunks * 4;
    for (remainder_start..n) |i| {
        dot += a_slice[i] * b_slice[i];
        norm_a_acc += a_slice[i] * a_slice[i];
        norm_b_acc += b_slice[i] * b_slice[i];
    }

    const denom = @sqrt(norm_a_acc) * @sqrt(norm_b_acc);
    if (denom < 1e-15) return 0;
    return dot / denom;
}
