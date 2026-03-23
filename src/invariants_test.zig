// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const invariants = @import("invariants.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "compute invariants: basic" {
    const times = [_]f64{ 0, 1, 2, 3, 4 };
    const values = [_]f64{ 1, 2, 3, 4, 5 };

    const inv = invariants.computeInvariants(&times, &values);
    try expectApprox(inv.duration, 4.0, 1e-10);
    try expectApprox(inv.min, 1.0, 1e-10);
    try expectApprox(inv.max, 5.0, 1e-10);
    try expectApprox(inv.mean, 3.0, 1e-10);
    try expect(inv.std_dev > 0);
    try expect(inv.area > 0);
}

test "compute invariants: empty series" {
    const inv = invariants.computeInvariants(&.{}, &.{});
    try expectApprox(inv.duration, 0.0, 1e-10);
    try expectApprox(inv.min, 0.0, 1e-10);
    try expectApprox(inv.max, 0.0, 1e-10);
}

test "compute invariants: single point" {
    const times = [_]f64{0};
    const values = [_]f64{42};

    const inv = invariants.computeInvariants(&times, &values);
    try expectApprox(inv.min, 42.0, 1e-10);
    try expectApprox(inv.max, 42.0, 1e-10);
    try expectApprox(inv.mean, 42.0, 1e-10);
    try expectApprox(inv.std_dev, 0.0, 1e-10);
}

test "compute invariants: constant series" {
    const times = [_]f64{ 0, 1, 2, 3, 4 };
    const values = [_]f64{ 5, 5, 5, 5, 5 };

    const inv = invariants.computeInvariants(&times, &values);
    try expectApprox(inv.std_dev, 0.0, 1e-10);
    // Constant series: all values in middle bin.
    try expectApprox(inv.histogram[5], 1.0, 1e-10);
}

test "compute invariants: histogram sums to 1" {
    const times = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const values = [_]f64{ 1, 5, 3, 7, 2, 8, 4, 6, 9, 0 };

    const inv = invariants.computeInvariants(&times, &values);
    var sum: f64 = 0;
    for (inv.histogram) |h| sum += h;
    try expectApprox(sum, 1.0, 1e-10);
}
