// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const anomaly = @import("anomaly.zig");
const expect = std.testing.expect;

// ============================================================================
// CUSUM
// ============================================================================

test "cusum: detects mean shift" {
    const allocator = std.testing.allocator;
    // 20 values at mean=0, then 20 values at mean=5 -> clear shift.
    // Global mean = 2.5, drift = 0.5.
    // In the first half (values=0): each step adds -2.5-0.5=-3 to s_pos (clamped to 0)
    //   and +2.5-0.5=+2.0 to s_neg, so s_neg triggers early.
    // In the second half (values=5): each step adds 5-2.5-0.5=+2.0 to s_pos,
    //   so s_pos triggers there too.
    // CUSUM detects deviations from the global mean in both halves.
    var values: [40]f64 = undefined;
    for (0..20) |i| values[i] = 0.0;
    for (20..40) |i| values[i] = 5.0;

    const indices = try anomaly.cusum(allocator, &values, 4.0, 0.5);
    defer allocator.free(indices);

    // Should detect change points in both the low and high regions.
    try expect(indices.len >= 2);

    // There should be detections in both halves since both deviate from the global mean.
    var found_first_half = false;
    var found_second_half = false;
    for (indices) |idx| {
        if (idx < 20) found_first_half = true;
        if (idx >= 20) found_second_half = true;
    }
    try expect(found_first_half);
    try expect(found_second_half);
}

test "cusum: no change in constant series" {
    const allocator = std.testing.allocator;
    var values: [20]f64 = undefined;
    for (0..20) |i| values[i] = 3.0;

    const indices = try anomaly.cusum(allocator, &values, 5.0, 1.0);
    defer allocator.free(indices);

    // Constant series: all values equal mean, so S_pos and S_neg stay at 0.
    try expect(indices.len == 0);
}

test "cusum: detects downward shift" {
    const allocator = std.testing.allocator;
    var values: [40]f64 = undefined;
    for (0..20) |i| values[i] = 10.0;
    for (20..40) |i| values[i] = 0.0;

    const indices = try anomaly.cusum(allocator, &values, 4.0, 0.5);
    defer allocator.free(indices);

    try expect(indices.len > 0);
}

test "cusum: empty input -> error" {
    const allocator = std.testing.allocator;
    const empty: []const f64 = &.{};

    const result = anomaly.cusum(allocator, empty, 1.0, 0.5);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// EWMA
// ============================================================================

test "ewma: detects outliers in otherwise stable series" {
    const allocator = std.testing.allocator;
    // Stable series around 0, with a large outlier at index 15.
    var values: [30]f64 = undefined;
    for (0..30) |i| values[i] = 0.0;
    values[15] = 50.0; // Inject outlier.

    const indices = try anomaly.ewma(allocator, &values, 0.3, 3.0);
    defer allocator.free(indices);

    // Should detect the outlier region.
    try expect(indices.len > 0);

    // At least one detection should be at or shortly after the outlier.
    var found_near_outlier = false;
    for (indices) |idx| {
        if (idx >= 15 and idx <= 20) {
            found_near_outlier = true;
            break;
        }
    }
    try expect(found_near_outlier);
}

test "ewma: no anomalies in constant series" {
    const allocator = std.testing.allocator;
    var values: [20]f64 = undefined;
    for (0..20) |i| values[i] = 5.0;

    const indices = try anomaly.ewma(allocator, &values, 0.2, 3.0);
    defer allocator.free(indices);

    try expect(indices.len == 0);
}

test "ewma: invalid alpha -> error" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 1.0, 2.0, 3.0 };

    // alpha = 0 is invalid.
    const result = anomaly.ewma(allocator, &values, 0.0, 3.0);
    try expect(result == error.InvalidInput);
}

test "ewma: alpha = 1 tracks raw values" {
    const allocator = std.testing.allocator;
    // With alpha=1, z_i = x_i exactly, so this becomes a simple threshold test.
    var values: [20]f64 = undefined;
    for (0..20) |i| values[i] = 0.0;
    values[10] = 100.0;

    const indices = try anomaly.ewma(allocator, &values, 1.0, 2.0);
    defer allocator.free(indices);

    // The spike at index 10 should be detected.
    try expect(indices.len > 0);
    var found = false;
    for (indices) |idx| {
        if (idx == 10) {
            found = true;
            break;
        }
    }
    try expect(found);
}

test "ewma: empty input -> error" {
    const allocator = std.testing.allocator;
    const empty: []const f64 = &.{};

    const result = anomaly.ewma(allocator, empty, 0.3, 3.0);
    try expect(result == error.InvalidInput);
}
