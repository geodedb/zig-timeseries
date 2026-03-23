// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const dtw = @import("dtw.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

// ============================================================================
// Constrained DTW
// ============================================================================

test "constrained DTW: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.constrainedDTW(std.testing.allocator, &a, 5, &a, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
    try expect(plen == 5);
}

test "constrained DTW: different series -> positive distance" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.constrainedDTW(std.testing.allocator, &a, 5, &b, 5, 2, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expect(dist > 0);
    try expect(plen > 0);
}

test "constrained DTW: empty series -> error" {
    var dist: f64 = undefined;
    var pi: [1]i32 = undefined;
    var pj: [1]i32 = undefined;
    var plen: i32 = undefined;
    const a = [_]f64{1};

    const rc = dtw.constrainedDTW(std.testing.allocator, &a, 0, &a, 1, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "constrained DTW: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    var dist_ab: f64 = undefined;
    var dist_ba: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    _ = dtw.constrainedDTW(std.testing.allocator, &a, 5, &b, 5, 0, &dist_ab, &pi, &pj, &plen);
    _ = dtw.constrainedDTW(std.testing.allocator, &b, 5, &a, 5, 0, &dist_ba, &pi, &pj, &plen);
    try expectApprox(dist_ab, dist_ba, 1e-10);
}

test "constrained DTW: non-negative" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    _ = dtw.constrainedDTW(std.testing.allocator, &a, 5, &b, 5, 0, &dist, &pi, &pj, &plen);
    try expect(dist >= 0);
}

// ============================================================================
// Derivative DTW
// ============================================================================

test "derivative DTW: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.derivativeDTW(std.testing.allocator, &a, 5, &a, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "derivative DTW: too short -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;
    var pi: [1]i32 = undefined;
    var pj: [1]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.derivativeDTW(std.testing.allocator, &a, 1, &a, 1, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

// ============================================================================
// Open-End DTW
// ============================================================================

test "open-end DTW: identical series" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.openEndDTW(std.testing.allocator, &a, 5, &a, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "open-end DTW: partial match" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 100, 200 };
    var dist: f64 = undefined;
    var pi: [20]i32 = undefined;
    var pj: [20]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.openEndDTW(std.testing.allocator, &a, 5, &b, 7, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    // Should match the first 5 elements well.
    try expect(dist < 5.0);
}

// ============================================================================
// Shape DTW
// ============================================================================

test "shape DTW: identical series" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.shapeDTW(std.testing.allocator, &a, 5, &a, 5, 0, 3, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

// ============================================================================
// Soft DTW
// ============================================================================

test "soft DTW: identical series -> near-zero distance" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = dtw.softDTW(std.testing.allocator, &a, 5, &a, 5, 1.0, &dist);
    try expect(rc == 0);
    // Soft DTW on identical series is not exactly 0 due to smoothing, but should be small.
    try expect(dist < 1.0);
}

test "soft DTW: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = dtw.softDTW(std.testing.allocator, &a, 0, &a, 1, 1.0, &dist);
    try expect(rc == -1);
}

// ============================================================================
// LB_Keogh
// ============================================================================

test "LB_Keogh: lower bound property" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const lb = dtw.lbKeogh(&a, 5, &b, 5, 1);

    var dtw_dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;
    _ = dtw.constrainedDTW(std.testing.allocator, &a, 5, &b, 5, 1, &dtw_dist, &pi, &pj, &plen);

    try expect(lb <= dtw_dist + 1e-10);
}

test "LB_Keogh: empty series -> 0" {
    const a = [_]f64{1};
    const lb = dtw.lbKeogh(&a, 0, &a, 1, 1);
    try expectApprox(lb, 0.0, 1e-10);
}

test "LB_Keogh: identical series -> 0" {
    const a = [_]f64{ 1, 2, 3 };
    const lb = dtw.lbKeogh(&a, 3, &a, 3, 1);
    try expectApprox(lb, 0.0, 1e-10);
}

// ============================================================================
// Security: Negative length guards (GAP-0021/S1)
// ============================================================================

test "constrained DTW: negative a_len -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.constrainedDTW(std.testing.allocator, &a, -1, &a, 3, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "constrained DTW: negative b_len -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.constrainedDTW(std.testing.allocator, &a, 3, &a, -5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "derivative DTW: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.derivativeDTW(std.testing.allocator, &a, -3, &a, 3, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "open-end DTW: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.openEndDTW(std.testing.allocator, &a, -1, &a, 3, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "shape DTW: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.shapeDTW(std.testing.allocator, &a, -1, &a, 3, 0, 3, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "shape DTW: negative descriptor_len -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;

    const rc = dtw.shapeDTW(std.testing.allocator, &a, 3, &a, 3, 0, -1, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "soft DTW: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = dtw.softDTW(std.testing.allocator, &a, -1, &a, 3, 1.0, &dist);
    try expect(rc == -1);
}

test "LB_Keogh: negative length -> 0" {
    const a = [_]f64{ 1, 2, 3 };
    const lb = dtw.lbKeogh(&a, -1, &a, 3, 1);
    try expectApprox(lb, 0.0, 1e-10);
}
