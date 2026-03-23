// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const preprocess = @import("preprocess.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "resample: regular grid" {
    const allocator = std.testing.allocator;
    const times = [_]f64{ 0, 2, 4 };
    const values = [_]f64{ 0, 2, 4 };

    const result = try preprocess.resample(allocator, &times, &values, 1.0);
    defer allocator.free(result.times);
    defer allocator.free(result.values);

    try expect(result.times.len == 5); // 0, 1, 2, 3, 4
    try expectApprox(result.values[0], 0.0, 1e-10);
    try expectApprox(result.values[1], 1.0, 1e-10);
    try expectApprox(result.values[2], 2.0, 1e-10);
    try expectApprox(result.values[3], 3.0, 1e-10);
    try expectApprox(result.values[4], 4.0, 1e-10);
}

test "z-normalize: mean=0, stddev=1" {
    var values = [_]f64{ 1, 2, 3, 4, 5 };
    preprocess.zNormalize(&values);

    // Check mean ~ 0.
    var sum: f64 = 0;
    for (values) |v| sum += v;
    try expectApprox(sum / 5.0, 0.0, 1e-10);

    // Check stddev ~ 1.
    var var_sum: f64 = 0;
    for (values) |v| var_sum += v * v;
    try expectApprox(@sqrt(var_sum / 5.0), 1.0, 1e-10);
}

test "z-normalize: constant series -> zeros" {
    var values = [_]f64{ 3, 3, 3 };
    preprocess.zNormalize(&values);

    for (values) |v| try expectApprox(v, 0.0, 1e-10);
}

test "baseline correct: removes trend" {
    var values = [_]f64{ 10, 10, 10, 10, 10, 10, 10, 10 };
    preprocess.baselineCorrect(std.testing.allocator, &values, 1.0);

    // A constant series baseline-corrected should be near zero.
    for (values) |v| try expectApprox(v, 0.0, 1e-10);
}

test "mark gaps: identifies gaps" {
    const allocator = std.testing.allocator;
    const times = [_]f64{ 0, 1, 2, 10, 11, 12 };
    const gaps = try preprocess.markGaps(allocator, &times, 3.0);
    defer allocator.free(gaps);

    try expect(gaps.len >= 1);
    // Gap between index 2 (t=2) and index 3 (t=10).
    try expect(gaps[0][0] == 2);
}

test "derivative: first differences" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 1, 3, 6, 10 };
    const deriv = try preprocess.derivative(allocator, &values);
    defer allocator.free(deriv);

    try expect(deriv.len == 3);
    try expectApprox(deriv[0], 2.0, 1e-10);
    try expectApprox(deriv[1], 3.0, 1e-10);
    try expectApprox(deriv[2], 4.0, 1e-10);
}

test "derivative: too short -> error" {
    const allocator = std.testing.allocator;
    const values = [_]f64{1};
    const result = preprocess.derivative(allocator, &values);
    try expect(result == error.TooShort);
}

test "zNormalizeAlloc: returns new array, preserves original" {
    const allocator = std.testing.allocator;
    const original = [_]f64{ 1, 2, 3, 4, 5 };
    const result = try preprocess.zNormalizeAlloc(allocator, &original);
    defer allocator.free(result);

    // Original should be unchanged.
    try expectApprox(original[0], 1.0, 1e-10);
    try expectApprox(original[4], 5.0, 1e-10);

    // Result should be z-normalized (mean=0, stddev=1).
    var sum: f64 = 0;
    for (result) |v| sum += v;
    try expectApprox(sum / 5.0, 0.0, 1e-10);

    var var_sum: f64 = 0;
    for (result) |v| var_sum += v * v;
    try expectApprox(@sqrt(var_sum / 5.0), 1.0, 1e-10);
}

test "baselineCorrectAlloc: returns new array, preserves original" {
    const allocator = std.testing.allocator;
    const original = [_]f64{ 10, 10, 10, 10, 10, 10, 10, 10 };
    const result = try preprocess.baselineCorrectAlloc(allocator, &original, 1.0);
    defer allocator.free(result);

    // Original should be unchanged.
    try expectApprox(original[0], 10.0, 1e-10);
    try expectApprox(original[7], 10.0, 1e-10);

    // Result should be baseline-corrected (near zero for constant series).
    for (result) |v| try expectApprox(v, 0.0, 1e-10);
}

test "baseline correct: handles 8193+ points" {
    const page_alloc = std.heap.page_allocator;
    const n: usize = 8193;
    const values = try page_alloc.alloc(f64, n);
    defer page_alloc.free(values);

    // Fill with a constant value.
    for (0..n) |i| values[i] = 10.0;

    preprocess.baselineCorrect(std.testing.allocator, values, 0.1);

    // A constant series baseline-corrected should be near zero for all points.
    for (0..n) |i| try expectApprox(values[i], 0.0, 1e-10);
}
