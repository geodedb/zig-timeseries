// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Tests for the C ABI export layer, verifying that the exported functions
//! match the contract expected by the Go CGO caller.

const std = @import("std");
const abi = @import("abi.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "ABI: ts_version returns 1" {
    try expect(abi.ts_version() == 1);
}

test "ABI: ts_dtw identical -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_dtw_derivative identical -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw_derivative(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_dtw_open_end identical" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw_open_end(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_dtw_shape identical" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw_shape(&a, 5, &a, 5, 0, 3, &dist, &pi, &pj, &plen);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_soft_dtw identical" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_soft_dtw(&a, 5, &a, 5, 1.0, &dist);
    try expect(rc == 0);
    try expect(dist < 1.0);
}

test "ABI: ts_lb_keogh lower bound" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const lb = abi.ts_lb_keogh(&a, 5, &b, 5, 1);
    try expect(lb >= 0);

    var dtw_dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    _ = abi.ts_dtw(&a, 5, &b, 5, 1, &dtw_dist, &pi, &pj, &plen);

    try expect(lb <= dtw_dist + 1e-10);
}

test "ABI: ts_cross_correlate identical -> lag 0, corr 1" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var lag: c_int = undefined;
    var corr: f64 = undefined;

    const rc = abi.ts_cross_correlate(&a, 5, &a, 5, &lag, &corr);
    try expect(rc == 0);
    try expect(lag == 0);
    try expectApprox(corr, 1.0, 1e-10);
}

test "ABI: ts_sbd identical -> 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_sbd(&a, 5, &a, 5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_pelt detects change points" {
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    var cps_len: c_int = undefined;

    const rc = abi.ts_pelt(&values, 10, 5.0, 2, &cps, &cps_len);
    try expect(rc == 0);
    try expect(cps_len >= 1);
}

test "ABI: ts_lcss identical -> 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_lcss(&a, 5, &a, 5, 0.5, 2, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_edr identical -> 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_edr(&a, 5, &a, 5, 0.5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_erp identical -> 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_erp(&a, 5, &a, 5, 0.0, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_twed identical -> 0" {
    const v = [_]f64{ 1, 2, 3, 4, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var dist: f64 = undefined;

    const rc = abi.ts_twed(&v, 5, &t, &v, 5, &t, 0.5, 0.5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_matrix_profile" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var profile: [15]f64 = undefined;
    var indices: [15]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_matrix_profile(&values, 15, 4, &profile, &indices, &plen);
    try expect(rc == 0);
    try expect(plen == 12);
}

test "ABI: ts_mp_dist" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_mp_dist(&a, 10, &a, 10, 3, &dist);
    try expect(rc == 0);
    try expect(dist >= 0);
}

test "ABI: ts_extract_features" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    var feats: [22]f64 = undefined;

    const rc = abi.ts_extract_features(&values, 5, &feats);
    try expect(rc == 0);
    try expectApprox(feats[0], 5.0, 1e-10);
    try expectApprox(feats[1], 3.0, 1e-10);
}

test "ABI: ts_cosine_similarity identical -> 1.0" {
    const a = [_]f64{ 1, 2, 3 };
    const sim = abi.ts_cosine_similarity(&a, &a, 3);
    try expectApprox(sim, 1.0, 1e-10);
}

// ============================================================================
// Security: NaN/Inf input validation (S7)
// ============================================================================

test "ABI: ts_dtw NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw(&a, 3, &b, 3, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_dtw Inf input -> error" {
    const a = [_]f64{ 1, std.math.inf(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw(&a, 3, &b, 3, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_dtw_derivative NaN input -> error" {
    const a = [_]f64{ 1, 2, std.math.nan(f64), 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw_derivative(&a, 5, &b, 5, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_soft_dtw NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = abi.ts_soft_dtw(&a, 3, &b, 3, 1.0, &dist);
    try expect(rc == -1);
}

test "ABI: ts_lb_keogh NaN input -> 0" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };

    const lb = abi.ts_lb_keogh(&a, 3, &b, 3, 1);
    try expectApprox(lb, 0.0, 1e-10);
}

test "ABI: ts_cross_correlate NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var lag: c_int = undefined;
    var corr: f64 = undefined;

    const rc = abi.ts_cross_correlate(&a, 3, &b, 3, &lag, &corr);
    try expect(rc == -1);
}

test "ABI: ts_sbd Inf input -> error" {
    const a = [_]f64{ 1, -std.math.inf(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = abi.ts_sbd(&a, 3, &b, 3, &dist);
    try expect(rc == -1);
}

test "ABI: ts_lcss NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = abi.ts_lcss(&a, 3, &b, 3, 0.5, 2, &dist);
    try expect(rc == -1);
}

test "ABI: ts_edr NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = abi.ts_edr(&a, 3, &b, 3, 0.5, &dist);
    try expect(rc == -1);
}

test "ABI: ts_erp Inf input -> error" {
    const a = [_]f64{ 1, std.math.inf(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = abi.ts_erp(&a, 3, &b, 3, 0.0, &dist);
    try expect(rc == -1);
}

test "ABI: ts_twed NaN in times -> error" {
    const v = [_]f64{ 1, 2, 3 };
    const t_ok = [_]f64{ 0, 1, 2 };
    const t_bad = [_]f64{ 0, std.math.nan(f64), 2 };
    var dist: f64 = undefined;

    const rc = abi.ts_twed(&v, 3, &t_bad, &v, 3, &t_ok, 0.5, 0.5, &dist);
    try expect(rc == -1);
}

test "ABI: ts_matrix_profile NaN input -> error" {
    const values = [_]f64{ 1, 2, std.math.nan(f64), 4, 5, 1, 2, 3, 4, 5 };
    var profile: [10]f64 = undefined;
    var indices: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_matrix_profile(&values, 10, 3, &profile, &indices, &plen);
    try expect(rc == -1);
}

test "ABI: ts_mp_dist Inf input -> error" {
    const a = [_]f64{ 1, 2, 3, std.math.inf(f64), 5, 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = abi.ts_mp_dist(&a, 10, &b, 10, 3, &dist);
    try expect(rc == -1);
}

test "ABI: ts_extract_features NaN input -> error" {
    const values = [_]f64{ 1, std.math.nan(f64), 3 };
    var feats: [22]f64 = undefined;

    const rc = abi.ts_extract_features(&values, 3, &feats);
    try expect(rc == -1);
}

test "ABI: ts_cosine_similarity NaN input -> 0" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };

    const sim = abi.ts_cosine_similarity(&a, &b, 3);
    try expectApprox(sim, 0.0, 1e-10);
}

test "ABI: ts_pelt NaN input -> error" {
    const values = [_]f64{ 1, std.math.nan(f64), 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    var cps_len: c_int = undefined;

    const rc = abi.ts_pelt(&values, 10, 5.0, 2, &cps, &cps_len);
    try expect(rc == -1);
}

// ============================================================================
// Security: Negative length through ABI (GAP-0021/S1)
// ============================================================================

test "ABI: ts_dtw negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const rc = abi.ts_dtw(&a, -1, &a, 3, 0, &dist, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_extract_features negative length -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var feats: [22]f64 = undefined;

    const rc = abi.ts_extract_features(&values, -1, &feats);
    try expect(rc == -1);
}

test "ABI: ts_cosine_similarity negative length -> 0" {
    const a = [_]f64{ 1, 2, 3 };

    const sim = abi.ts_cosine_similarity(&a, &a, -1);
    try expectApprox(sim, 0.0, 1e-10);
}

// ============================================================================
// Security: NULL output pointer checks (S6)
// ============================================================================

// The ABI functions use callconv(.c), so we call them via C function pointer
// types that accept optional pointers, which allows passing null (address 0).
// This mirrors a C caller passing NULL for output parameters.

const NullTestHelpers = struct {
    // C-compatible function pointer type for DTW-family functions with path output.
    const DtwFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        c_int,
        ?*f64,
        ?[*]i32,
        ?[*]i32,
        ?*c_int,
    ) callconv(.c) c_int;

    // Shape DTW has an extra descriptor_len param.
    const ShapeDtwFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        c_int,
        c_int,
        ?*f64,
        ?[*]i32,
        ?[*]i32,
        ?*c_int,
    ) callconv(.c) c_int;

    // Soft DTW / SBD / EDR / ERP / MP dist style: two series + params + dist out.
    const DistFn2 = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        f64,
        ?*f64,
    ) callconv(.c) c_int;

    const SbdFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        ?*f64,
    ) callconv(.c) c_int;

    const CrossCorrFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        ?*c_int,
        ?*f64,
    ) callconv(.c) c_int;

    const PeltFn = *const fn (
        [*]const f64,
        c_int,
        f64,
        c_int,
        ?[*]i32,
        ?*c_int,
    ) callconv(.c) c_int;

    const LcssFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        f64,
        c_int,
        ?*f64,
    ) callconv(.c) c_int;

    const ErpFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        f64,
        ?*f64,
    ) callconv(.c) c_int;

    const TwedFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        [*]const f64,
        c_int,
        [*]const f64,
        f64,
        f64,
        ?*f64,
    ) callconv(.c) c_int;

    const MatrixProfileFn = *const fn (
        [*]const f64,
        c_int,
        c_int,
        ?[*]f64,
        ?[*]i32,
        ?*c_int,
    ) callconv(.c) c_int;

    const MpDistFn = *const fn (
        [*]const f64,
        c_int,
        [*]const f64,
        c_int,
        c_int,
        ?*f64,
    ) callconv(.c) c_int;

    const ExtractFeaturesFn = *const fn (
        [*]const f64,
        c_int,
        ?[*]f64,
    ) callconv(.c) c_int;
};

test "ABI: ts_dtw null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const f: NullTestHelpers.DtwFn = @ptrCast(&abi.ts_dtw);
    const rc = f(&a, 3, &a, 3, 0, null, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_dtw null path_len pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;

    const f: NullTestHelpers.DtwFn = @ptrCast(&abi.ts_dtw);
    const rc = f(&a, 3, &a, 3, 0, &dist, &pi, &pj, null);
    try expect(rc == -1);
}

test "ABI: ts_dtw null path_i pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const f: NullTestHelpers.DtwFn = @ptrCast(&abi.ts_dtw);
    const rc = f(&a, 3, &a, 3, 0, &dist, null, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_dtw_derivative null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const f: NullTestHelpers.DtwFn = @ptrCast(&abi.ts_dtw_derivative);
    const rc = f(&a, 5, &a, 5, 0, null, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_dtw_open_end null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const f: NullTestHelpers.DtwFn = @ptrCast(&abi.ts_dtw_open_end);
    const rc = f(&a, 5, &a, 5, 0, null, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_dtw_shape null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;

    const f: NullTestHelpers.ShapeDtwFn = @ptrCast(&abi.ts_dtw_shape);
    const rc = f(&a, 5, &a, 5, 0, 3, null, &pi, &pj, &plen);
    try expect(rc == -1);
}

test "ABI: ts_soft_dtw null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const f: NullTestHelpers.DistFn2 = @ptrCast(&abi.ts_soft_dtw);

    const rc = f(&a, 3, &a, 3, 1.0, null);
    try expect(rc == -1);
}

test "ABI: ts_cross_correlate null lag pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var corr: f64 = undefined;

    const f: NullTestHelpers.CrossCorrFn = @ptrCast(&abi.ts_cross_correlate);
    const rc = f(&a, 3, &a, 3, null, &corr);
    try expect(rc == -1);
}

test "ABI: ts_cross_correlate null corr pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var lag: c_int = undefined;

    const f: NullTestHelpers.CrossCorrFn = @ptrCast(&abi.ts_cross_correlate);
    const rc = f(&a, 3, &a, 3, &lag, null);
    try expect(rc == -1);
}

test "ABI: ts_sbd null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const f: NullTestHelpers.SbdFn = @ptrCast(&abi.ts_sbd);

    const rc = f(&a, 3, &a, 3, null);
    try expect(rc == -1);
}

test "ABI: ts_pelt null cps pointer -> error" {
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps_len: c_int = undefined;

    const f: NullTestHelpers.PeltFn = @ptrCast(&abi.ts_pelt);
    const rc = f(&values, 10, 5.0, 2, null, &cps_len);
    try expect(rc == -1);
}

test "ABI: ts_pelt null cps_len pointer -> error" {
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;

    const f: NullTestHelpers.PeltFn = @ptrCast(&abi.ts_pelt);
    const rc = f(&values, 10, 5.0, 2, &cps, null);
    try expect(rc == -1);
}

test "ABI: ts_lcss null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const f: NullTestHelpers.LcssFn = @ptrCast(&abi.ts_lcss);

    const rc = f(&a, 3, &a, 3, 0.5, 2, null);
    try expect(rc == -1);
}

test "ABI: ts_edr null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const f: NullTestHelpers.DistFn2 = @ptrCast(&abi.ts_edr);

    const rc = f(&a, 3, &a, 3, 0.5, null);
    try expect(rc == -1);
}

test "ABI: ts_erp null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const f: NullTestHelpers.ErpFn = @ptrCast(&abi.ts_erp);

    const rc = f(&a, 3, &a, 3, 0.0, null);
    try expect(rc == -1);
}

test "ABI: ts_twed null dist pointer -> error" {
    const v = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    const f: NullTestHelpers.TwedFn = @ptrCast(&abi.ts_twed);

    const rc = f(&v, 3, &t, &v, 3, &t, 0.5, 0.5, null);
    try expect(rc == -1);
}

test "ABI: ts_matrix_profile null profile pointer -> error" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var indices: [10]i32 = undefined;
    var plen: c_int = undefined;

    const f: NullTestHelpers.MatrixProfileFn = @ptrCast(&abi.ts_matrix_profile);
    const rc = f(&values, 10, 3, null, &indices, &plen);
    try expect(rc == -1);
}

test "ABI: ts_matrix_profile null profile_len pointer -> error" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var profile: [10]f64 = undefined;
    var indices: [10]i32 = undefined;

    const f: NullTestHelpers.MatrixProfileFn = @ptrCast(&abi.ts_matrix_profile);
    const rc = f(&values, 10, 3, &profile, &indices, null);
    try expect(rc == -1);
}

test "ABI: ts_mp_dist null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    const f: NullTestHelpers.MpDistFn = @ptrCast(&abi.ts_mp_dist);

    const rc = f(&a, 10, &a, 10, 3, null);
    try expect(rc == -1);
}

test "ABI: ts_extract_features null features_out pointer -> error" {
    const values = [_]f64{ 1, 2, 3 };
    const f: NullTestHelpers.ExtractFeaturesFn = @ptrCast(&abi.ts_extract_features);

    const rc = f(&values, 3, null);
    try expect(rc == -1);
}
