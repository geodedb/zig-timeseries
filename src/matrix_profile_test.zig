// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const mp = @import("matrix_profile.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "matrix profile: basic computation" {
    // Repeating pattern: motif should be detected.
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };

    const result = try mp.matrixProfile(std.testing.allocator, &values, 4);
    defer result.deinit(std.testing.allocator);

    try expect(result.profile.len == 12); // 15 - 4 + 1

    // The repeating pattern should produce near-zero distances for some positions.
    var has_near_zero = false;
    for (result.profile) |p| {
        if (p < 0.5) has_near_zero = true;
    }
    try expect(has_near_zero);
}

test "matrix profile: empty series -> error" {
    const empty: []const f64 = &.{};

    const result = mp.matrixProfile(std.testing.allocator, empty, 1);
    try expect(result == error.InvalidInput);
}

test "matrix profile: window too large -> error" {
    const values = [_]f64{ 1, 2, 3 };

    const result = mp.matrixProfile(std.testing.allocator, &values, 5);
    try expect(result == error.InvalidInput);
}

test "MP dist: basic computation" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };

    const dist = try mp.mpDist(std.testing.allocator, &a, &b, 3);
    try expect(dist >= 0);
}

test "MP dist: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = mp.mpDist(std.testing.allocator, empty, &a, 1);
    try expect(result == error.InvalidInput);
}

test "MP dist: handles 8193+ points (no silent limit)" {
    const page_alloc = std.heap.page_allocator;
    const n: usize = 8193;
    const a_buf = try page_alloc.alloc(f64, n);
    defer page_alloc.free(a_buf);
    const b_buf = try page_alloc.alloc(f64, n);
    defer page_alloc.free(b_buf);

    for (0..n) |i| {
        a_buf[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1);
        b_buf[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1);
    }

    // Use a large window (8190) so plen_a = 4, keeping computation fast.
    const dist = try mp.mpDist(std.testing.allocator, a_buf, b_buf, 8190);

    try expect(dist >= 0);
}

// ============================================================================
// STOMP algorithm correctness tests
// ============================================================================

test "matrix profile: constant series (std==0) produces zeros outside exclusion zone" {
    const values = [_]f64{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };

    const result = try mp.matrixProfile(std.testing.allocator, &values, 3);
    defer result.deinit(std.testing.allocator);

    try expect(result.profile.len == 8); // 10 - 3 + 1

    var has_zero = false;
    for (result.profile) |p| {
        if (p < 0.01) has_zero = true;
    }
    try expect(has_zero);
}

test "matrix profile: single subsequence (plen==1) -> infinity" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };

    const result = try mp.matrixProfile(std.testing.allocator, &values, 5);
    defer result.deinit(std.testing.allocator);

    try expect(result.profile.len == 1);
    try expect(result.profile[0] == std.math.inf(f64));
}

test "matrix profile: repeating pattern has near-zero motif distances" {
    const values = [_]f64{ 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3 };

    const result = try mp.matrixProfile(std.testing.allocator, &values, 3);
    defer result.deinit(std.testing.allocator);

    try expect(result.profile.len == 9); // 11 - 3 + 1

    try expectApprox(result.profile[0], 0.0, 0.1);
    try expectApprox(result.profile[4], 0.0, 0.1);
    try expectApprox(result.profile[8], 0.0, 0.1);
}

test "matrix profile: symmetric -- profile[i]'s nearest neighbor points back" {
    const values = [_]f64{ 1, 3, 2, 5, 1, 3, 2, 4, 6, 1, 3, 2, 5 };

    const result = try mp.matrixProfile(std.testing.allocator, &values, 4);
    defer result.deinit(std.testing.allocator);

    const p = result.profile.len;
    for (0..p) |i| {
        const j = result.indices[i];
        if (j < p) {
            try expect(result.profile[j] <= result.profile[i] + 1e-10);
        }
    }
}

test "matrix profile: window==2 with simple data" {
    const values = [_]f64{ 0, 1, 0, 1, 0 };

    const result = try mp.matrixProfile(std.testing.allocator, &values, 2);
    defer result.deinit(std.testing.allocator);

    try expect(result.profile.len == 4); // 5 - 2 + 1

    try expectApprox(result.profile[0], 0.0, 1e-10);
    try expectApprox(result.profile[1], 0.0, 1e-10);
    try expectApprox(result.profile[2], 0.0, 1e-10);
    try expectApprox(result.profile[3], 0.0, 1e-10);
}

// ============================================================================
// Security: Invalid input guards
// ============================================================================

test "matrix profile: zero window_len -> error" {
    const values = [_]f64{ 1, 2, 3 };

    const result = mp.matrixProfile(std.testing.allocator, &values, 0);
    try expect(result == error.InvalidInput);
}

test "MP dist: zero window_len -> error" {
    const a = [_]f64{ 1, 2, 3 };

    const result = mp.mpDist(std.testing.allocator, &a, &a, 0);
    try expect(result == error.InvalidInput);
}

test "MP dist: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = mp.mpDist(std.testing.allocator, &a, empty, 1);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// Security: CPU DoS length cap (S16)
// ============================================================================

test "matrix profile: series exceeding MAX_SERIES_LEN -> error" {
    // We cannot allocate 100001 elements, but we can test the guard
    // by using a 1-element slice and claiming it is long.
    // With the new API, we pass a slice, so we test via the SeriesTooLong path.
    // We need a slice of length > 100000. Use page_allocator.
    const page_alloc = std.heap.page_allocator;
    const big = try page_alloc.alloc(f64, 100_001);
    defer page_alloc.free(big);
    for (big) |*v| v.* = 1.0;

    const result = mp.matrixProfile(std.testing.allocator, big, 1);
    try expect(result == error.SeriesTooLong);
}

test "MP dist: series exceeding MAX_SERIES_LEN -> error" {
    const page_alloc = std.heap.page_allocator;
    const big = try page_alloc.alloc(f64, 100_001);
    defer page_alloc.free(big);
    for (big) |*v| v.* = 1.0;

    const v3 = [_]f64{ 1, 2, 3 };
    const result = mp.mpDist(std.testing.allocator, big, &v3, 1);
    try expect(result == error.SeriesTooLong);
}
