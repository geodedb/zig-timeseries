// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const pelt_mod = @import("pelt.zig");
const expect = std.testing.expect;

test "PELT: detects change points" {
    // Two distinct segments: low values then high values.
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    var cps_len: i32 = undefined;

    const rc = pelt_mod.pelt(std.testing.allocator, &values, 10, 5.0, 2, &cps, &cps_len);
    try expect(rc == 0);
    try expect(cps_len >= 1);
    // Change point should be near index 5.
    try expect(cps[0] >= 3 and cps[0] <= 7);
}

test "PELT: empty series -> no change points" {
    var cps: [1]i32 = undefined;
    var cps_len: i32 = undefined;
    const v = [_]f64{1};

    const rc = pelt_mod.pelt(std.testing.allocator, &v, 0, 5.0, 2, &cps, &cps_len);
    try expect(rc == 0);
    try expect(cps_len == 0);
}

test "PELT: constant series -> no change points" {
    const values = [_]f64{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };
    var cps: [10]i32 = undefined;
    var cps_len: i32 = undefined;

    const rc = pelt_mod.pelt(std.testing.allocator, &values, 10, 5.0, 2, &cps, &cps_len);
    try expect(rc == 0);
    try expect(cps_len == 0);
}

test "PELT: three segments" {
    const values = [_]f64{ 0, 0, 0, 0, 5, 5, 5, 5, 0, 0, 0, 0 };
    var cps: [12]i32 = undefined;
    var cps_len: i32 = undefined;

    const rc = pelt_mod.pelt(std.testing.allocator, &values, 12, 3.0, 2, &cps, &cps_len);
    try expect(rc == 0);
    try expect(cps_len >= 1);
}

// ============================================================================
// Security: Negative length guards (GAP-0021/S1)
// ============================================================================

test "PELT: negative length -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var cps: [3]i32 = undefined;
    var cps_len: i32 = undefined;

    const rc = pelt_mod.pelt(std.testing.allocator, &values, -1, 5.0, 2, &cps, &cps_len);
    try expect(rc == -1);
}
