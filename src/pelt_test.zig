// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const pelt_mod = @import("pelt.zig");
const expect = std.testing.expect;

test "PELT: detects change points" {
    // Two distinct segments: low values then high values.
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };

    const cps = try pelt_mod.pelt(std.testing.allocator, &values, 5.0, 2);
    defer std.testing.allocator.free(cps);

    try expect(cps.len >= 1);
    // Change point should be near index 5.
    try expect(cps[0] >= 3 and cps[0] <= 7);
}

test "PELT: empty series -> no change points" {
    const empty: []const f64 = &.{};

    const cps = try pelt_mod.pelt(std.testing.allocator, empty, 5.0, 2);
    defer std.testing.allocator.free(cps);

    try expect(cps.len == 0);
}

test "PELT: constant series -> no change points" {
    const values = [_]f64{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };

    const cps = try pelt_mod.pelt(std.testing.allocator, &values, 5.0, 2);
    defer std.testing.allocator.free(cps);

    try expect(cps.len == 0);
}

test "PELT: three segments" {
    const values = [_]f64{ 0, 0, 0, 0, 5, 5, 5, 5, 0, 0, 0, 0 };

    const cps = try pelt_mod.pelt(std.testing.allocator, &values, 3.0, 2);
    defer std.testing.allocator.free(cps);

    try expect(cps.len >= 1);
}

// ============================================================================
// Security: Empty input guards (idiomatic Zig error unions)
// ============================================================================

test "PELT: single element -> no change points" {
    const values = [_]f64{42};

    const cps = try pelt_mod.pelt(std.testing.allocator, &values, 5.0, 2);
    defer std.testing.allocator.free(cps);

    try expect(cps.len == 0);
}
