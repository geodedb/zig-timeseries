// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Statistical anomaly and change-point detection functions.
//!
//! All public functions use idiomatic Zig signatures:
//! - Bounded slices (`[]const f64`) instead of raw pointers + length pairs
//! - Error unions (`!`) instead of integer return codes
//! - Returned owned slices; caller must free via `allocator.free(result)`
//!
//! References:
//! - Page, "Continuous Inspection Schemes", Biometrika, 1954 (CUSUM).
//! - Roberts, "Control Chart Tests Based on Geometric Moving Averages", Technometrics, 1959 (EWMA).

const std = @import("std");
const math = std.math;
const types = @import("types.zig");
const TsError = types.TsError;

/// CUSUM (Cumulative Sum) change-point detection.
///
/// Tracks upward and downward cumulative sums relative to the series mean.
/// When either exceeds `threshold`, a change point is recorded and the
/// accumulators are reset.
///
/// Parameters:
/// - `values`: input time series
/// - `threshold`: detection threshold (higher = fewer detections)
/// - `drift`: allowable drift before accumulation (typically 0.5 * expected shift)
///
/// Returns an owned slice of indices where changes are detected.
/// Caller must free via `allocator.free(result)`.
pub fn cusum(
    allocator: std.mem.Allocator,
    values: []const f64,
    threshold: f64,
    drift: f64,
) ![]usize {
    if (values.len == 0) return TsError.InvalidInput;

    // Compute series mean.
    var sum: f64 = 0.0;
    for (values) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(values.len));

    // Pre-allocate worst-case buffer (every point is a change).
    const buf = try allocator.alloc(usize, values.len);
    errdefer allocator.free(buf);
    var count: usize = 0;

    var s_pos: f64 = 0.0;
    var s_neg: f64 = 0.0;

    for (values, 0..) |v, i| {
        s_pos = @max(0.0, s_pos + v - mean - drift);
        s_neg = @max(0.0, s_neg - v + mean - drift);

        if (s_pos > threshold or s_neg > threshold) {
            buf[count] = i;
            count += 1;
            s_pos = 0.0;
            s_neg = 0.0;
        }
    }

    // Shrink to actual size.
    if (count == 0) {
        allocator.free(buf);
        return allocator.alloc(usize, 0);
    }
    const result = try allocator.alloc(usize, count);
    @memcpy(result, buf[0..count]);
    allocator.free(buf);
    return result;
}

/// EWMA (Exponentially Weighted Moving Average) anomaly detection.
///
/// Computes a smoothed moving average and flags points where the
/// EWMA statistic exceeds control limits.
///
/// Parameters:
/// - `values`: input time series
/// - `alpha`: smoothing factor in (0, 1]; higher = more responsive
/// - `threshold`: number of sigma-equivalents for control limits
///
/// Returns an owned slice of indices where anomalies are detected.
/// Caller must free via `allocator.free(result)`.
pub fn ewma(
    allocator: std.mem.Allocator,
    values: []const f64,
    alpha: f64,
    threshold: f64,
) ![]usize {
    if (values.len == 0) return TsError.InvalidInput;
    if (alpha <= 0.0 or alpha > 1.0) return TsError.InvalidInput;

    // Compute series mean and standard deviation.
    var sum: f64 = 0.0;
    for (values) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(values.len));

    var var_sum: f64 = 0.0;
    for (values) |v| {
        const d = v - mean;
        var_sum += d * d;
    }
    const sigma = @sqrt(var_sum / @as(f64, @floatFromInt(values.len)));

    if (sigma == 0.0) {
        // Constant series -- no anomalies possible.
        return allocator.alloc(usize, 0);
    }

    // Control limit width: threshold * sigma * sqrt(alpha / (2 - alpha)).
    const limit = threshold * sigma * @sqrt(alpha / (2.0 - alpha));

    // Pre-allocate worst-case buffer.
    const buf = try allocator.alloc(usize, values.len);
    errdefer allocator.free(buf);
    var count: usize = 0;

    var z: f64 = mean; // z_0 = mean

    for (values, 0..) |v, i| {
        z = alpha * v + (1.0 - alpha) * z;
        if (@abs(z - mean) > limit) {
            buf[count] = i;
            count += 1;
        }
    }

    // Shrink to actual size.
    if (count == 0) {
        allocator.free(buf);
        return allocator.alloc(usize, 0);
    }
    const result = try allocator.alloc(usize, count);
    @memcpy(result, buf[0..count]);
    allocator.free(buf);
    return result;
}
