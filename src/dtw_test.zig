// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const dtw = @import("dtw.zig");
const types = @import("types.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

// ============================================================================
// Constrained DTW
// ============================================================================

test "constrained DTW: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const result = try dtw.constrainedDTW(std.testing.allocator, &a, &a, 0);
    defer result.deinit(std.testing.allocator);
    try expectApprox(result.distance, 0.0, 1e-10);
    try expect(result.path.len == 5);
}

test "constrained DTW: different series -> positive distance" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };

    const result = try dtw.constrainedDTW(std.testing.allocator, &a, &b, 2);
    defer result.deinit(std.testing.allocator);
    try expect(result.distance > 0);
    try expect(result.path.len > 0);
}

test "constrained DTW: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = dtw.constrainedDTW(std.testing.allocator, empty, &a, 0);
    try expect(result == error.InvalidInput);
}

test "constrained DTW: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const result_ab = try dtw.constrainedDTW(std.testing.allocator, &a, &b, 0);
    defer result_ab.deinit(std.testing.allocator);
    const result_ba = try dtw.constrainedDTW(std.testing.allocator, &b, &a, 0);
    defer result_ba.deinit(std.testing.allocator);
    try expectApprox(result_ab.distance, result_ba.distance, 1e-10);
}

test "constrained DTW: non-negative" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const result = try dtw.constrainedDTW(std.testing.allocator, &a, &b, 0);
    defer result.deinit(std.testing.allocator);
    try expect(result.distance >= 0);
}

// ============================================================================
// Derivative DTW
// ============================================================================

test "derivative DTW: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const result = try dtw.derivativeDTW(std.testing.allocator, &a, &a, 0);
    defer result.deinit(std.testing.allocator);
    try expectApprox(result.distance, 0.0, 1e-10);
}

test "derivative DTW: too short -> error" {
    const a = [_]f64{1};

    const result = dtw.derivativeDTW(std.testing.allocator, &a, &a, 0);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// Open-End DTW
// ============================================================================

test "open-end DTW: identical series" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const result = try dtw.openEndDTW(std.testing.allocator, &a, &a, 0);
    defer result.deinit(std.testing.allocator);
    try expectApprox(result.distance, 0.0, 1e-10);
}

test "open-end DTW: partial match" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 100, 200 };

    const result = try dtw.openEndDTW(std.testing.allocator, &a, &b, 0);
    defer result.deinit(std.testing.allocator);
    // Should match the first 5 elements well.
    try expect(result.distance < 5.0);
}

// ============================================================================
// Shape DTW
// ============================================================================

test "shape DTW: identical series" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const result = try dtw.shapeDTW(std.testing.allocator, &a, &a, 0, 3);
    defer result.deinit(std.testing.allocator);
    try expectApprox(result.distance, 0.0, 1e-10);
}

// ============================================================================
// Soft DTW
// ============================================================================

test "soft DTW: identical series -> near-zero distance" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const dist = try dtw.softDTW(std.testing.allocator, &a, &a, 1.0);
    // Soft DTW on identical series is not exactly 0 due to smoothing, but should be small.
    try expect(dist < 1.0);
}

test "soft DTW: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = dtw.softDTW(std.testing.allocator, empty, &a, 1.0);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// LB_Keogh
// ============================================================================

test "LB_Keogh: lower bound property" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const lb = dtw.lbKeogh(&a, &b, 1);

    const result = try dtw.constrainedDTW(std.testing.allocator, &a, &b, 1);
    defer result.deinit(std.testing.allocator);

    try expect(lb <= result.distance + 1e-10);
}

test "LB_Keogh: empty series -> 0" {
    const empty: []const f64 = &.{};
    const a = [_]f64{1};
    const lb = dtw.lbKeogh(empty, &a, 1);
    try expectApprox(lb, 0.0, 1e-10);
}

test "LB_Keogh: identical series -> 0" {
    const a = [_]f64{ 1, 2, 3 };
    const lb = dtw.lbKeogh(&a, &a, 1);
    try expectApprox(lb, 0.0, 1e-10);
}

// ============================================================================
// Security: Empty and invalid input guards (idiomatic Zig error unions)
// ============================================================================

test "constrained DTW: first slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = dtw.constrainedDTW(std.testing.allocator, empty, &a, 0);
    try expect(result == error.InvalidInput);
}

test "constrained DTW: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = dtw.constrainedDTW(std.testing.allocator, &a, empty, 0);
    try expect(result == error.InvalidInput);
}

test "derivative DTW: single-element slices -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const short = [_]f64{1};

    const result = dtw.derivativeDTW(std.testing.allocator, &short, &a, 0);
    try expect(result == error.InvalidInput);
}

test "open-end DTW: empty slice -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = dtw.openEndDTW(std.testing.allocator, empty, &a, 0);
    try expect(result == error.InvalidInput);
}

test "shape DTW: empty slice -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = dtw.shapeDTW(std.testing.allocator, empty, &a, 0, 3);
    try expect(result == error.InvalidInput);
}

test "shape DTW: zero descriptor_len -> error" {
    const a = [_]f64{ 1, 2, 3 };

    const result = dtw.shapeDTW(std.testing.allocator, &a, &a, 0, 0);
    try expect(result == error.InvalidInput);
}

test "soft DTW: empty slice -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = dtw.softDTW(std.testing.allocator, empty, &a, 1.0);
    try expect(result == error.InvalidInput);
}

test "soft DTW: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = dtw.softDTW(std.testing.allocator, &a, empty, 1.0);
    try expect(result == error.InvalidInput);
}
