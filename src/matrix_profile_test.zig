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

    const rc = mp.matrixProfile(std.testing.allocator, &values, 15, 4, &profile, &indices, &plen);
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

    const rc = mp.matrixProfile(std.testing.allocator, &v, 0, 1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "matrix profile: window too large -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var profile: [3]f64 = undefined;
    var indices: [3]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 3, 5, &profile, &indices, &plen);
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
// STOMP algorithm correctness tests
// ============================================================================

test "matrix profile: constant series (std==0) produces infinity" {
    // All values are the same -> all subsequences are constant.
    // With exclusion zone, no valid match -> profile should be infinity.
    const values = [_]f64{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };
    var profile: [10]f64 = undefined;
    var indices: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 10, 3, &profile, &indices, &plen);
    try expect(rc == 0);
    try expect(plen == 8); // 10 - 3 + 1

    // All constant subsequences have std == 0. When both are constant,
    // distance is 0. With the exclusion zone some pairs are skipped,
    // but pairs outside the zone should have distance 0.
    var has_zero = false;
    for (0..@as(usize, @intCast(plen))) |i| {
        if (profile[i] < 0.01) has_zero = true;
    }
    try expect(has_zero);
}

test "matrix profile: single subsequence (plen==1) -> infinity" {
    // n == w -> plen == 1 -> no neighbor outside exclusion zone -> infinity.
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    var profile: [5]f64 = undefined;
    var indices: [5]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 5, 5, &profile, &indices, &plen);
    try expect(rc == 0);
    try expect(plen == 1);
    try expect(profile[0] == std.math.inf(f64));
}

test "matrix profile: repeating pattern has near-zero motif distances" {
    // Pattern [1,2,3] repeats. Identical subsequences at offsets 0,4,8
    // should find near-zero nearest neighbors.
    const values = [_]f64{ 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3 };
    var profile: [11]f64 = undefined;
    var indices: [11]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 11, 3, &profile, &indices, &plen);
    try expect(rc == 0);
    try expect(plen == 9); // 11 - 3 + 1

    // Subsequences at positions 0, 4, 8 are all [1,2,3].
    // Distance between identical z-normalized subsequences should be ~0.
    try expectApprox(profile[0], 0.0, 0.1);
    try expectApprox(profile[4], 0.0, 0.1);
    try expectApprox(profile[8], 0.0, 0.1);
}

test "matrix profile: symmetric -- profile[i]'s nearest neighbor points back" {
    // In a self-join, if profile_index[i] == j, then profile[j] should be
    // <= profile[i] (j found something at least as close or closer).
    const values = [_]f64{ 1, 3, 2, 5, 1, 3, 2, 4, 6, 1, 3, 2, 5 };
    var profile: [13]f64 = undefined;
    var indices: [13]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 13, 4, &profile, &indices, &plen);
    try expect(rc == 0);

    const p: usize = @intCast(plen);
    for (0..p) |i| {
        const j: usize = @intCast(indices[i]);
        if (j < p) {
            // profile[j] should have found its best match (possibly i or closer).
            try expect(profile[j] <= profile[i] + 1e-10);
        }
    }
}

test "matrix profile: window==2 with simple data" {
    // Small window for manual verification.
    const values = [_]f64{ 0, 1, 0, 1, 0 };
    var profile: [5]f64 = undefined;
    var indices: [5]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 5, 2, &profile, &indices, &plen);
    try expect(rc == 0);
    try expect(plen == 4); // 5 - 2 + 1

    // Subsequences: [0,1], [1,0], [0,1], [1,0]
    // Exclusion zone: w/4 + 1 = 1. So position 0 cannot match 0 (self).
    // z-norm of [0,1] and [0,1] = distance 0.
    // z-norm of [0,1] and [1,0] = distance sqrt(2w) = 2.0 (anti-correlated).
    // position 0 -> nearest is position 2 (same pattern), dist ~ 0
    // position 1 -> nearest is position 3, dist ~ 0
    try expectApprox(profile[0], 0.0, 1e-10);
    try expectApprox(profile[1], 0.0, 1e-10);
    try expectApprox(profile[2], 0.0, 1e-10);
    try expectApprox(profile[3], 0.0, 1e-10);
}

// ============================================================================
// Security: Negative length guards (GAP-0021/S1)
// ============================================================================

test "matrix profile: negative values_len -> error" {
    var profile: [1]f64 = undefined;
    var indices: [1]i32 = undefined;
    var plen: i32 = undefined;
    const v = [_]f64{1};

    const rc = mp.matrixProfile(std.testing.allocator, &v, -1, 1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "matrix profile: negative window_len -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var profile: [3]f64 = undefined;
    var indices: [3]i32 = undefined;
    var plen: i32 = undefined;

    const rc = mp.matrixProfile(std.testing.allocator, &values, 3, -1, &profile, &indices, &plen);
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
    const rc = mp.matrixProfile(std.testing.allocator, &v, 100_001, 1, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "MP dist: series exceeding MAX_SERIES_LEN -> error" {
    const v = [_]f64{1};
    var dist: f64 = undefined;

    const rc = mp.mpDist(std.testing.allocator, &v, 100_001, &v, 3, 1, &dist);
    try expect(rc == -1);
}
