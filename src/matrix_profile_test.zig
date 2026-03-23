// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const mp = @import("matrix_profile.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "matrix profile: basic computation" {
    // Repeating pattern: motif should be detected.
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var profile: [15]f64 = undefined;
    var indices: [15]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(&values, 15, 4, &profile, &indices, &plen);
    try expect(rc == 0);
    try expect(plen == 12); // 15 - 4 + 1

    // The repeating pattern should produce near-zero distances for some positions.
    var has_near_zero = false;
    for (0..@as(usize, @intCast(plen))) |i| {
        if (profile[i] < 0.5) has_near_zero = true;
    }
    try expect(has_near_zero);
}

test "matrix profile: empty series -> error" {
    var profile: [1]f64 = undefined;
    var indices: [1]i32 = undefined;
    var plen: i32 = undefined;
    const v = [_]f64{1};

    const rc = mp.matrixProfile(&v, 0, 1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "matrix profile: window too large -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var profile: [3]f64 = undefined;
    var indices: [3]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(&values, 3, 5, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "MP dist: basic computation" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = mp.mpDist(std.testing.allocator, &a, 10, &b, 10, 3, &dist);
    try expect(rc == 0);
    try expect(dist >= 0);
}

test "MP dist: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = mp.mpDist(std.testing.allocator, &a, 0, &a, 1, 1, &dist);
    try expect(rc == -1);
}

test "MP dist: handles 8193+ points (no silent limit)" {
    const page_alloc = std.heap.page_allocator;
    const n: usize = 8193;
    const a_buf = try page_alloc.alloc(f64, n);
    defer page_alloc.free(a_buf);
    const b_buf = try page_alloc.alloc(f64, n);
    defer page_alloc.free(b_buf);

    // Fill with identical repeating patterns.
    for (0..n) |i| {
        a_buf[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1);
        b_buf[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1);
    }

    var dist: f64 = undefined;
    // Use a large window (8190) so plen_a = 4, keeping computation fast.
    const rc = mp.mpDist(std.testing.allocator, a_buf.ptr, @intCast(n), b_buf.ptr, @intCast(n), 8190, &dist);

    // Should succeed (not -1), proving 8192 limit is removed.
    try expect(rc == 0);
    try expect(dist >= 0);
}

// ============================================================================
// Security: Negative length guards (GAP-0021/S1)
// ============================================================================

test "matrix profile: negative values_len -> error" {
    var profile: [1]f64 = undefined;
    var indices: [1]i32 = undefined;
    var plen: i32 = undefined;
    const v = [_]f64{1};

    const rc = mp.matrixProfile(&v, -1, 1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "matrix profile: negative window_len -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var profile: [3]f64 = undefined;
    var indices: [3]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(&values, 3, -1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "MP dist: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = mp.mpDist(std.testing.allocator, &a, -1, &a, 3, 1, &dist);
    try expect(rc == -1);
}

// ============================================================================
// Security: CPU DoS length cap (S16)
// ============================================================================

test "matrix profile: series exceeding MAX_SERIES_LEN -> error" {
    const v = [_]f64{1};
    var profile: [1]f64 = undefined;
    var indices: [1]i32 = undefined;
    var plen: i32 = undefined;

    // Pass a length of 100001 (exceeds MAX_SERIES_LEN=100000).
    // The guard rejects before any pointer access beyond the first element.
    const rc = mp.matrixProfile(&v, 100_001, 1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "MP dist: series exceeding MAX_SERIES_LEN -> error" {
    const v = [_]f64{1};
    var dist: f64 = undefined;

    const rc = mp.mpDist(std.testing.allocator, &v, 100_001, &v, 3, 1, &dist);
    try expect(rc == -1);
}
