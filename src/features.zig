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
pub fn extractFeatures(
    allocator: std.mem.Allocator,
    values: [*]const f64,
    values_len: i32,
    features_out: [*]f64,
) i32 {
    if (values_len <= 0) return -1;
    const n: usize = @intCast(values_len);

    const nf: f64 = @floatFromInt(n);

    // Mean.
    var sum: f64 = 0;
    for (0..n) |i| sum += values[i];
    const mean = sum / nf;

    // Variance / StdDev.
    var var_sum: f64 = 0;
    for (0..n) |i| {
        const d = values[i] - mean;
        var_sum += d * d;
    }
    const variance = var_sum / nf;
    const std_dev = @sqrt(variance);

    // Min / Max.
    var min_val: f64 = values[0];
    var max_val: f64 = values[0];
    for (1..n) |i| {
        if (values[i] < min_val) min_val = values[i];
        if (values[i] > max_val) max_val = values[i];
    }

    // Median (via sorted copy -- dynamically allocated).
    const sort_buf = allocator.alloc(f64, n) catch return -1;
    defer allocator.free(sort_buf);
    for (0..n) |i| sort_buf[i] = values[i];
    std.mem.sort(f64, sort_buf, {}, std.sort.asc(f64));
    const median = if (n % 2 == 1)
        sort_buf[n / 2]
    else
        (sort_buf[n / 2 - 1] + sort_buf[n / 2]) / 2.0;

    // Skewness and kurtosis.
    var m3: f64 = 0;
    var m4: f64 = 0;
    for (0..n) |i| {
        const d = values[i] - mean;
        const d2 = d * d;
        m3 += d * d2;
        m4 += d2 * d2;
    }
    m3 /= nf;
    m4 /= nf;
    const skewness = if (std_dev > 1e-10) m3 / (std_dev * std_dev * std_dev) else 0;
    const kurtosis = if (std_dev > 1e-10) m4 / (variance * variance) - 3.0 else 0;

    // Linear trend slope: sum((i - i_mean) * (v - v_mean)) / sum((i - i_mean)^2).
    const i_mean = (nf - 1.0) / 2.0;
    var num: f64 = 0;
    var den: f64 = 0;
    for (0..n) |i| {
        const fi: f64 = @floatFromInt(i);
        const di = fi - i_mean;
        num += di * (values[i] - mean);
        den += di * di;
    }
    const slope = if (den > 1e-10) num / den else 0;

    // 10-bin histogram of z-normalized values (range [-3, 3]).
    var hist: [10]f64 = .{0} ** 10;
    for (0..n) |i| {
        const z = if (std_dev > 1e-10) (values[i] - mean) / std_dev else 0;
        // Map z in [-3, 3] to bins [0, 9].
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
