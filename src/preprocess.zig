// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Preprocessing functions for time-series data.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Resample a series to a regular grid with the given interval (in seconds).
/// Uses linear interpolation between existing points.
/// Caller owns returned slices.
pub fn resample(
    allocator: Allocator,
    times: []const f64,
    values: []const f64,
    interval: f64,
) !struct { times: []f64, values: []f64 } {
    if (times.len == 0 or values.len == 0 or interval <= 0) {
        return .{ .times = &.{}, .values = &.{} };
    }

    const start = times[0];
    const end = times[times.len - 1];
    const span = end - start;
    if (span <= 0) {
        var out_t = try allocator.alloc(f64, 1);
        var out_v = try allocator.alloc(f64, 1);
        out_t[0] = start;
        out_v[0] = values[0];
        return .{ .times = out_t, .values = out_v };
    }

    const count: usize = @as(usize, @intFromFloat(@floor(span / interval))) + 1;
    var out_t = try allocator.alloc(f64, count);
    var out_v = try allocator.alloc(f64, count);

    var src_idx: usize = 0;
    for (0..count) |i| {
        const t = start + @as(f64, @floatFromInt(i)) * interval;
        out_t[i] = t;

        // Advance source index.
        while (src_idx + 1 < times.len and times[src_idx + 1] <= t) {
            src_idx += 1;
        }

        if (src_idx + 1 >= times.len) {
            out_v[i] = values[values.len - 1];
        } else {
            const t0 = times[src_idx];
            const t1 = times[src_idx + 1];
            const frac = (t - t0) / (t1 - t0);
            out_v[i] = values[src_idx] + frac * (values[src_idx + 1] - values[src_idx]);
        }
    }

    return .{ .times = out_t, .values = out_v };
}

/// Z-normalize a series in-place: subtract mean, divide by std dev.
/// NOTE: Modifies `values` in-place; the original data is overwritten.
/// Constant series (std_dev == 0) is set to all zeros.
/// NOTE: This function modifies `values` in-place. The caller's original data is overwritten.
pub fn zNormalize(values: []f64) void {
    if (values.len == 0) return;

    const n: f64 = @floatFromInt(values.len);
    var sum: f64 = 0;
    for (values) |v| sum += v;
    const mean = sum / n;

    var var_sum: f64 = 0;
    for (values) |v| {
        const d = v - mean;
        var_sum += d * d;
    }
    const std_dev = @sqrt(var_sum / n);

    if (std_dev < 1e-10) {
        for (values) |*v| v.* = 0;
        return;
    }

    for (values) |*v| v.* = (v.* - mean) / std_dev;
}

/// Subtract a moving-average baseline from the series in-place.
/// NOTE: Modifies `values` in-place; the original data is overwritten.
/// `window_pct` is the fraction of the series length used as window size.
/// Uses a prefix sum for O(n) computation instead of O(n*w).
pub fn baselineCorrect(allocator: std.mem.Allocator, values: []f64, window_pct: f64) void {
    if (values.len == 0) return;

    const n = values.len;
    const nf: f64 = @floatFromInt(n);
    const half_win: usize = @max(1, @as(usize, @intFromFloat(nf * window_pct / 2.0)));

    // Prefix sum array: prefix_sum[i] = sum of values[0..i].
    // prefix_sum has n+1 elements where prefix_sum[0] = 0.
    const prefix_sum = allocator.alloc(f64, n + 1) catch return;
    defer allocator.free(prefix_sum);

    prefix_sum[0] = 0;
    for (0..n) |i| {
        prefix_sum[i + 1] = prefix_sum[i] + values[i];
    }

    // Compute baselines using prefix sums, then subtract.
    // baseline[i] = (prefix_sum[hi] - prefix_sum[lo]) / (hi - lo)
    // where lo = max(0, i - half_win), hi = min(n, i + half_win + 1).
    const baseline = allocator.alloc(f64, n) catch return;
    defer allocator.free(baseline);

    for (0..n) |i| {
        const lo = if (i >= half_win) i - half_win else 0;
        const hi = @min(i + half_win + 1, n);
        const window_sum = prefix_sum[hi] - prefix_sum[lo];
        baseline[i] = window_sum / @as(f64, @floatFromInt(hi - lo));
    }

    for (0..n) |i| values[i] -= baseline[i];
}

/// Z-normalize, returning a NEW allocated slice. Caller must free.
pub fn zNormalizeAlloc(allocator: Allocator, values: []const f64) ![]f64 {
    const result = try allocator.dupe(f64, values);
    zNormalize(result);
    return result;
}

/// Baseline correct, returning a NEW allocated slice. Caller must free.
pub fn baselineCorrectAlloc(allocator: Allocator, values: []const f64, window_pct: f64) ![]f64 {
    const result = try allocator.dupe(f64, values);
    baselineCorrect(allocator, result, window_pct);
    return result;
}

/// Mark gaps in the series where consecutive timestamps differ by more than
/// `max_interp` seconds. Returns a list of (start_idx, end_idx) pairs.
/// Caller owns the returned slice.
pub fn markGaps(
    allocator: Allocator,
    times: []const f64,
    max_interp: f64,
) ![]const [2]usize {
    if (times.len < 2) return &.{};

    var gaps: std.ArrayList([2]usize) = .empty;

    var gap_start: ?usize = null;
    for (0..times.len - 1) |i| {
        const dt = times[i + 1] - times[i];
        if (dt > max_interp) {
            if (gap_start == null) gap_start = i;
        } else {
            if (gap_start) |gs| {
                try gaps.append(allocator, .{ gs, i + 1 });
                gap_start = null;
            }
        }
    }
    if (gap_start) |gs| {
        try gaps.append(allocator, .{ gs, times.len - 1 });
    }

    return try gaps.toOwnedSlice(allocator);
}

/// Compute first differences (derivative) of values.
/// Returns a slice of length (values.len - 1). Caller owns it.
pub fn derivative(allocator: Allocator, values: []const f64) ![]f64 {
    if (values.len < 2) return error.TooShort;

    var result = try allocator.alloc(f64, values.len - 1);
    for (0..values.len - 1) |i| {
        result[i] = values[i + 1] - values[i];
    }
    return result;
}
