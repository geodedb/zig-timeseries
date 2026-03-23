// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Shape-invariant statistics computation.

const std = @import("std");
const math = std.math;
const types = @import("types.zig");

/// Compute shape-invariant statistics for a series.
pub fn computeInvariants(
    times: []const f64,
    values: []const f64,
) types.InvariantSet {
    var result = types.InvariantSet{
        .duration = 0,
        .min = 0,
        .max = 0,
        .mean = 0,
        .std_dev = 0,
        .area = 0,
        .histogram = .{0} ** 10,
    };

    const n = values.len;
    if (n == 0) return result;

    // Duration.
    if (times.len >= 2) {
        result.duration = times[times.len - 1] - times[0];
    }

    // Min, max, mean.
    var sum: f64 = 0;
    result.min = values[0];
    result.max = values[0];
    for (values) |v| {
        sum += v;
        if (v < result.min) result.min = v;
        if (v > result.max) result.max = v;
    }
    const nf: f64 = @floatFromInt(n);
    result.mean = sum / nf;

    // Std dev.
    var var_sum: f64 = 0;
    for (values) |v| {
        const d = v - result.mean;
        var_sum += d * d;
    }
    result.std_dev = @sqrt(var_sum / nf);

    // Area (trapezoidal rule using timestamps if available, else unit spacing).
    if (n >= 2) {
        for (0..n - 1) |i| {
            const dt = if (times.len >= n) times[i + 1] - times[i] else 1.0;
            result.area += (values[i] + values[i + 1]) / 2.0 * dt;
        }
    } else {
        result.area = values[0];
    }

    // 10-bin histogram over value range.
    const range = result.max - result.min;
    if (range > 1e-10) {
        for (values) |v| {
            const frac = (v - result.min) / range;
            const bin: usize = @min(9, @as(usize, @intFromFloat(frac * 10.0)));
            result.histogram[bin] += 1.0;
        }
    } else {
        // All values equal -- put everything in middle bin.
        result.histogram[5] = nf;
    }

    // Normalize histogram.
    for (&result.histogram) |*h| h.* /= nf;

    return result;
}
