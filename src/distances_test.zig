// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const distances = @import("distances.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

// ============================================================================
// Cross-Correlation
// ============================================================================

test "cross-correlate: identical series -> lag 0, correlation 1" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 5, &a, 5, &lag, &corr);
    try expect(rc == 0);
    try expect(lag == 0);
    try expectApprox(corr, 1.0, 1e-10);
}

test "cross-correlate: empty series -> error" {
    const a = [_]f64{1};
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 0, &a, 1, &lag, &corr);
    try expect(rc == -1);
}

test "cross-correlate: shifted series detects lag" {
    const a = [_]f64{ 0, 0, 1, 2, 3, 4, 5, 0, 0 };
    const b = [_]f64{ 0, 0, 0, 0, 1, 2, 3, 4, 5 };
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 9, &b, 9, &lag, &corr);
    try expect(rc == 0);
    try expect(corr > 0.8);
}

// ============================================================================
// SBD
// ============================================================================

test "SBD: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, 5, &a, 5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "SBD: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, 0, &a, 1, &dist);
    try expect(rc == -1);
}

// ============================================================================
// LCSS
// ============================================================================

test "LCSS: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.lcss(std.testing.allocator, &a, 5, &a, 5, 0.5, 2, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "LCSS: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.lcss(std.testing.allocator, &a, 0, &a, 1, 0.5, 2, &dist);
    try expect(rc == -1);
}

// ============================================================================
// EDR
// ============================================================================

test "EDR: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.edr(std.testing.allocator, &a, 5, &a, 5, 0.5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "EDR: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.edr(std.testing.allocator, &a, 0, &a, 1, 0.5, &dist);
    try expect(rc == -1);
}

// ============================================================================
// ERP
// ============================================================================

test "ERP: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.erp(std.testing.allocator, &a, 5, &a, 5, 0.0, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ERP: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.erp(std.testing.allocator, &a, 0, &a, 1, 0.0, &dist);
    try expect(rc == -1);
}

test "ERP: triangle inequality" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const c = [_]f64{ 3, 4, 5, 6, 7 };
    var d_ab: f64 = undefined;
    var d_bc: f64 = undefined;
    var d_ac: f64 = undefined;

    _ = distances.erp(std.testing.allocator, &a, 5, &b, 5, 0.0, &d_ab);
    _ = distances.erp(std.testing.allocator, &b, 5, &c, 5, 0.0, &d_bc);
    _ = distances.erp(std.testing.allocator, &a, 5, &c, 5, 0.0, &d_ac);

    try expect(d_ac <= d_ab + d_bc + 1e-10);
}

test "ERP: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    var d_ab: f64 = undefined;
    var d_ba: f64 = undefined;

    _ = distances.erp(std.testing.allocator, &a, 5, &b, 5, 0.0, &d_ab);
    _ = distances.erp(std.testing.allocator, &b, 5, &a, 5, 0.0, &d_ba);
    try expectApprox(d_ab, d_ba, 1e-10);
}

// ============================================================================
// TWED
// ============================================================================

test "TWED: identical series -> distance 0" {
    const v = [_]f64{ 1, 2, 3, 4, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var dist: f64 = undefined;

    const rc = distances.twed(std.testing.allocator, &v, 5, &t, &v, 5, &t, 0.5, 0.5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "TWED: empty series -> error" {
    const v = [_]f64{1};
    const t = [_]f64{0};
    var dist: f64 = undefined;

    const rc = distances.twed(std.testing.allocator, &v, 0, &t, &v, 1, &t, 0.5, 0.5, &dist);
    try expect(rc == -1);
}

test "TWED: triangle inequality" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const c = [_]f64{ 3, 4, 5, 6, 7 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var d_ab: f64 = undefined;
    var d_bc: f64 = undefined;
    var d_ac: f64 = undefined;

    _ = distances.twed(std.testing.allocator, &a, 5, &t, &b, 5, &t, 0.5, 0.5, &d_ab);
    _ = distances.twed(std.testing.allocator, &b, 5, &t, &c, 5, &t, 0.5, 0.5, &d_bc);
    _ = distances.twed(std.testing.allocator, &a, 5, &t, &c, 5, &t, 0.5, 0.5, &d_ac);

    try expect(d_ac <= d_ab + d_bc + 1e-10);
}

test "TWED: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var d_ab: f64 = undefined;
    var d_ba: f64 = undefined;

    _ = distances.twed(std.testing.allocator, &a, 5, &t, &b, 5, &t, 0.5, 0.5, &d_ab);
    _ = distances.twed(std.testing.allocator, &b, 5, &t, &a, 5, &t, 0.5, 0.5, &d_ba);
    try expectApprox(d_ab, d_ba, 1e-10);
}

// ============================================================================
// Distance symmetry (all)
// ============================================================================

test "all distances: symmetric" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    // LCSS
    var la: f64 = undefined;
    var lb_val: f64 = undefined;
    _ = distances.lcss(std.testing.allocator, &a, 5, &b, 5, 1.0, 5, &la);
    _ = distances.lcss(std.testing.allocator, &b, 5, &a, 5, 1.0, 5, &lb_val);
    try expectApprox(la, lb_val, 1e-10);

    // EDR
    var ea: f64 = undefined;
    var eb: f64 = undefined;
    _ = distances.edr(std.testing.allocator, &a, 5, &b, 5, 1.0, &ea);
    _ = distances.edr(std.testing.allocator, &b, 5, &a, 5, 1.0, &eb);
    try expectApprox(ea, eb, 1e-10);

    // SBD
    var sa: f64 = undefined;
    var sb: f64 = undefined;
    _ = distances.sbd(&a, 5, &b, 5, &sa);
    _ = distances.sbd(&b, 5, &a, 5, &sb);
    try expectApprox(sa, sb, 1e-10);
}

// ============================================================================
// Security: Negative length guards (GAP-0021/S1)
// ============================================================================

test "cross-correlate: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, -1, &a, 3, &lag, &corr);
    try expect(rc == -1);
}

test "SBD: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, -1, &a, 3, &dist);
    try expect(rc == -1);
}

test "LCSS: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.lcss(std.testing.allocator, &a, -1, &a, 3, 0.5, 2, &dist);
    try expect(rc == -1);
}

test "EDR: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.edr(std.testing.allocator, &a, -1, &a, 3, 0.5, &dist);
    try expect(rc == -1);
}

test "ERP: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.erp(std.testing.allocator, &a, -1, &a, 3, 0.0, &dist);
    try expect(rc == -1);
}

test "TWED: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    var dist: f64 = undefined;

    const rc = distances.twed(std.testing.allocator, &a, -1, &t, &a, 3, &t, 0.5, 0.5, &dist);
    try expect(rc == -1);
}
