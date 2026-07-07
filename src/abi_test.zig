// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Tests for the C ABI export layer, verifying that the exported functions
//! match the contract expected by the Go CGO caller.

const std = @import("std");
const abi = @import("abi.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "ABI: ts_version returns 2" {
    try expect(abi.ts_version() == 2);
}

test "ABI: ts_dtw identical -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const rc = abi.ts_dtw(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen, 10);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_dtw_derivative identical -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const rc = abi.ts_dtw_derivative(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen, 10);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_dtw_open_end identical" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const rc = abi.ts_dtw_open_end(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen, 10);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ABI: ts_dtw_shape identical" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const rc = abi.ts_dtw_shape(&a, 5, &a, 5, 0, 3, &dist, &pi, &pj, &plen, 10);
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
    var lb: f64 = undefined;
    const lb_rc = abi.ts_lb_keogh(&a, 5, &b, 5, 1, &lb);
    try expect(lb_rc == 0);
    try expect(lb >= 0);
    var dtw_dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    _ = abi.ts_dtw(&a, 5, &b, 5, 1, &dtw_dist, &pi, &pj, &plen, 10);
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
    const rc = abi.ts_pelt(&values, 10, 5.0, 2, &cps, &cps_len, 10);
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
    const rc = abi.ts_matrix_profile(&values, 15, 4, &profile, &indices, &plen, 15);
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
    var sim: f64 = undefined;
    const rc = abi.ts_cosine_similarity(&a, &a, 3, &sim);
    try expect(rc == 0);
    try expectApprox(sim, 1.0, 1e-10);
}

// S5: Output buffer capacity overflow tests

test "ABI: ts_dtw path_cap=0 -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen, 0) == -1);
}

test "ABI: ts_dtw_derivative path_cap=0 -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_derivative(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen, 0) == -1);
}

test "ABI: ts_dtw_open_end path_cap=0 -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_open_end(&a, 5, &a, 5, 0, &dist, &pi, &pj, &plen, 0) == -1);
}

test "ABI: ts_dtw_shape path_cap=0 -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_shape(&a, 5, &a, 5, 0, 3, &dist, &pi, &pj, &plen, 0) == -1);
}

test "ABI: ts_pelt cps_cap=0 -> error" {
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    var cps_len: c_int = undefined;
    try expect(abi.ts_pelt(&values, 10, 5.0, 2, &cps, &cps_len, 0) == -1);
}

test "ABI: ts_matrix_profile out_cap=0 -> error" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var profile: [15]f64 = undefined;
    var indices: [15]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_matrix_profile(&values, 15, 4, &profile, &indices, &plen, 0) == -1);
}

test "ABI: ts_dtw negative path_cap -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, 3, &a, 3, 0, &dist, &pi, &pj, &plen, -1) == -1);
}

// S15: Error signaling for f64-returning functions

test "ABI: ts_lb_keogh returns int 0 on success" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var result: f64 = undefined;
    try expect(abi.ts_lb_keogh(&a, 5, &a, 5, 1, &result) == 0);
    try expect(result >= 0);
}

test "ABI: ts_lb_keogh negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    try expect(abi.ts_lb_keogh(&a, -1, &a, 3, 1, &result) == -1);
}

test "ABI: ts_cosine_similarity returns int 0 on success" {
    const a = [_]f64{ 1, 0, 0 };
    const b = [_]f64{ 0, 1, 0 };
    var result: f64 = undefined;
    try expect(abi.ts_cosine_similarity(&a, &b, 3, &result) == 0);
    try expectApprox(result, 0.0, 1e-10);
}

test "ABI: ts_cosine_similarity negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    try expect(abi.ts_cosine_similarity(&a, &a, -1, &result) == -1);
}

// NaN/Inf input validation (S7)

test "ABI: ts_dtw NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, 3, &b, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw Inf input -> error" {
    const a = [_]f64{ 1, std.math.inf(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, 3, &b, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_derivative NaN input -> error" {
    const a = [_]f64{ 1, 2, std.math.nan(f64), 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_derivative(&a, 5, &b, 5, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_soft_dtw NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    try expect(abi.ts_soft_dtw(&a, 3, &b, 3, 1.0, &dist) == -1);
}

test "ABI: ts_lb_keogh NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    try expect(abi.ts_lb_keogh(&a, 3, &b, 3, 1, &result) == -1);
}

test "ABI: ts_cross_correlate NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var lag: c_int = undefined;
    var corr: f64 = undefined;
    try expect(abi.ts_cross_correlate(&a, 3, &b, 3, &lag, &corr) == -1);
}

test "ABI: ts_sbd Inf input -> error" {
    const a = [_]f64{ 1, -std.math.inf(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    try expect(abi.ts_sbd(&a, 3, &b, 3, &dist) == -1);
}

test "ABI: ts_lcss NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    try expect(abi.ts_lcss(&a, 3, &b, 3, 0.5, 2, &dist) == -1);
}

test "ABI: ts_edr NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    try expect(abi.ts_edr(&a, 3, &b, 3, 0.5, &dist) == -1);
}

test "ABI: ts_erp Inf input -> error" {
    const a = [_]f64{ 1, std.math.inf(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    try expect(abi.ts_erp(&a, 3, &b, 3, 0.0, &dist) == -1);
}

test "ABI: ts_twed NaN in times -> error" {
    const v = [_]f64{ 1, 2, 3 };
    const t_ok = [_]f64{ 0, 1, 2 };
    const t_bad = [_]f64{ 0, std.math.nan(f64), 2 };
    var dist: f64 = undefined;
    try expect(abi.ts_twed(&v, 3, &t_bad, &v, 3, &t_ok, 0.5, 0.5, &dist) == -1);
}

test "ABI: ts_matrix_profile NaN input -> error" {
    const values = [_]f64{ 1, 2, std.math.nan(f64), 4, 5, 1, 2, 3, 4, 5 };
    var profile: [10]f64 = undefined;
    var indices: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_matrix_profile(&values, 10, 3, &profile, &indices, &plen, 10) == -1);
}

test "ABI: ts_mp_dist Inf input -> error" {
    const a = [_]f64{ 1, 2, 3, std.math.inf(f64), 5, 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    try expect(abi.ts_mp_dist(&a, 10, &b, 10, 3, &dist) == -1);
}

test "ABI: ts_extract_features NaN input -> error" {
    const values = [_]f64{ 1, std.math.nan(f64), 3 };
    var feats: [22]f64 = undefined;
    try expect(abi.ts_extract_features(&values, 3, &feats) == -1);
}

test "ABI: ts_cosine_similarity NaN input -> error" {
    const a = [_]f64{ 1, std.math.nan(f64), 3 };
    const b = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    try expect(abi.ts_cosine_similarity(&a, &b, 3, &result) == -1);
}

test "ABI: ts_pelt NaN input -> error" {
    const values = [_]f64{ 1, std.math.nan(f64), 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    var cps_len: c_int = undefined;
    try expect(abi.ts_pelt(&values, 10, 5.0, 2, &cps, &cps_len, 10) == -1);
}

// Negative length (S1)

test "ABI: ts_dtw negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, -1, &a, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_extract_features negative length -> error" {
    const values = [_]f64{ 1, 2, 3 };
    var feats: [22]f64 = undefined;
    try expect(abi.ts_extract_features(&values, -1, &feats) == -1);
}

test "ABI: ts_cosine_similarity negative length -> error (via S15)" {
    const a = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    try expect(abi.ts_cosine_similarity(&a, &a, -1, &result) == -1);
}

// NULL output pointer checks (S6)

test "ABI: ts_dtw null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, 3, &a, 3, 0, null, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw null path_len pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    try expect(abi.ts_dtw(&a, 3, &a, 3, 0, &dist, &pi, &pj, null, 10) == -1);
}

test "ABI: ts_dtw null path_i pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw(&a, 3, &a, 3, 0, &dist, null, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_derivative null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_derivative(&a, 5, &a, 5, 0, null, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_open_end null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_open_end(&a, 5, &a, 5, 0, null, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_shape null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_dtw_shape(&a, 5, &a, 5, 0, 3, null, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_soft_dtw null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_soft_dtw(&a, 3, &a, 3, 1.0, null) == -1);
}

test "ABI: ts_cross_correlate null lag pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var corr: f64 = undefined;
    try expect(abi.ts_cross_correlate(&a, 3, &a, 3, null, &corr) == -1);
}

test "ABI: ts_cross_correlate null corr pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var lag: c_int = undefined;
    try expect(abi.ts_cross_correlate(&a, 3, &a, 3, &lag, null) == -1);
}

test "ABI: ts_sbd null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_sbd(&a, 3, &a, 3, null) == -1);
}

test "ABI: ts_pelt null cps pointer -> error" {
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps_len: c_int = undefined;
    try expect(abi.ts_pelt(&values, 10, 5.0, 2, null, &cps_len, 10) == -1);
}

test "ABI: ts_pelt null cps_len pointer -> error" {
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    try expect(abi.ts_pelt(&values, 10, 5.0, 2, &cps, null, 10) == -1);
}

test "ABI: ts_lcss null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_lcss(&a, 3, &a, 3, 0.5, 2, null) == -1);
}

test "ABI: ts_edr null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_edr(&a, 3, &a, 3, 0.5, null) == -1);
}

test "ABI: ts_erp null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_erp(&a, 3, &a, 3, 0.0, null) == -1);
}

test "ABI: ts_twed null dist pointer -> error" {
    const v = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    try expect(abi.ts_twed(&v, 3, &t, &v, 3, &t, 0.5, 0.5, null) == -1);
}

test "ABI: ts_matrix_profile null profile pointer -> error" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var indices: [10]i32 = undefined;
    var plen: c_int = undefined;
    try expect(abi.ts_matrix_profile(&values, 10, 3, null, &indices, &plen, 10) == -1);
}

test "ABI: ts_matrix_profile null profile_len pointer -> error" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var profile: [10]f64 = undefined;
    var indices: [10]i32 = undefined;
    try expect(abi.ts_matrix_profile(&values, 10, 3, &profile, &indices, null, 10) == -1);
}

test "ABI: ts_mp_dist null dist pointer -> error" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    try expect(abi.ts_mp_dist(&a, 10, &a, 10, 3, null) == -1);
}

test "ABI: ts_extract_features null features_out pointer -> error" {
    const values = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_extract_features(&values, 3, null) == -1);
}

test "ABI: ts_lb_keogh null result pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_lb_keogh(&a, 3, &a, 3, 1, null) == -1);
}

test "ABI: ts_cosine_similarity null result pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    try expect(abi.ts_cosine_similarity(&a, &a, 3, null) == -1);
}

// NULL input data pointer checks (F6)
//
// Zig's own `@ptrFromInt`/`@ptrCast` insert a runtime safety check that
// rejects constructing a zero-valued `[*]const f64` directly (these
// pointer types don't allow the zero address), so a plain
// `@ptrFromInt(0)` panics before we ever reach the function under test.
// A real C caller has no such guard: it can pass a raw NULL through the
// C calling convention without Zig ever materializing an invalid pointer
// value. `asRaw` reinterprets the exported function's pointer with one
// parameter widened to `usize` so the test can hand the callee a literal
// zero bit pattern exactly the way an FFI caller would -- reproducing the
// F6 scenario faithfully instead of tripping over Zig's own safety net.
fn asRaw(comptime RawFn: type, func: anytype) RawFn {
    return @ptrCast(func);
}

test "ABI: ts_dtw null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, c_int, ?*f64, ?[*]i32, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_dtw);
    try expect(raw(0, 3, &b, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw null b pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const RawFn = *const fn ([*]const f64, c_int, usize, c_int, c_int, ?*f64, ?[*]i32, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_dtw);
    try expect(raw(&a, 3, 0, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_derivative null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, c_int, ?*f64, ?[*]i32, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_dtw_derivative);
    try expect(raw(0, 3, &b, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_open_end null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, c_int, ?*f64, ?[*]i32, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_dtw_open_end);
    try expect(raw(0, 3, &b, 3, 0, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_dtw_shape null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: c_int = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, c_int, c_int, ?*f64, ?[*]i32, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_dtw_shape);
    try expect(raw(0, 3, &b, 3, 0, 3, &dist, &pi, &pj, &plen, 10) == -1);
}

test "ABI: ts_soft_dtw null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_soft_dtw);
    try expect(raw(0, 3, &b, 3, 1.0, &dist) == -1);
}

test "ABI: ts_lb_keogh null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, c_int, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_lb_keogh);
    try expect(raw(0, 3, &b, 3, 1, &result) == -1);
}

test "ABI: ts_cross_correlate null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var lag: c_int = undefined;
    var corr: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, ?*c_int, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_cross_correlate);
    try expect(raw(0, 3, &b, 3, &lag, &corr) == -1);
}

test "ABI: ts_sbd null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_sbd);
    try expect(raw(0, 3, &b, 3, &dist) == -1);
}

test "ABI: ts_pelt null values pointer -> error" {
    var cps: [10]i32 = undefined;
    var cps_len: c_int = undefined;
    const RawFn = *const fn (usize, c_int, f64, c_int, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_pelt);
    try expect(raw(0, 10, 5.0, 2, &cps, &cps_len, 10) == -1);
}

test "ABI: ts_lcss null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, f64, c_int, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_lcss);
    try expect(raw(0, 3, &b, 3, 0.5, 2, &dist) == -1);
}

test "ABI: ts_edr null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_edr);
    try expect(raw(0, 3, &b, 3, 0.5, &dist) == -1);
}

test "ABI: ts_erp null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_erp);
    try expect(raw(0, 3, &b, 3, 0.0, &dist) == -1);
}

test "ABI: ts_twed null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, [*]const f64, c_int, [*]const f64, f64, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_twed);
    try expect(raw(0, 3, &t, &b, 3, &t, 0.5, 0.5, &dist) == -1);
}

test "ABI: ts_twed null b pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    var dist: f64 = undefined;
    const RawFn = *const fn ([*]const f64, c_int, [*]const f64, usize, c_int, [*]const f64, f64, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_twed);
    try expect(raw(&a, 3, &t, 0, 3, &t, 0.5, 0.5, &dist) == -1);
}

test "ABI: ts_twed null a_times pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    var dist: f64 = undefined;
    const RawFn = *const fn ([*]const f64, c_int, usize, [*]const f64, c_int, [*]const f64, f64, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_twed);
    try expect(raw(&a, 3, 0, &a, 3, &t, 0.5, 0.5, &dist) == -1);
}

test "ABI: ts_twed null b_times pointer -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    var dist: f64 = undefined;
    const RawFn = *const fn ([*]const f64, c_int, [*]const f64, [*]const f64, c_int, usize, f64, f64, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_twed);
    try expect(raw(&a, 3, &t, &a, 3, 0, 0.5, 0.5, &dist) == -1);
}

test "ABI: ts_matrix_profile null values pointer -> error" {
    var profile: [10]f64 = undefined;
    var indices: [10]i32 = undefined;
    var plen: c_int = undefined;
    const RawFn = *const fn (usize, c_int, c_int, ?[*]f64, ?[*]i32, ?*c_int, c_int) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_matrix_profile);
    try expect(raw(0, 10, 3, &profile, &indices, &plen, 10) == -1);
}

test "ABI: ts_mp_dist null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3, 4, 5, 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;
    const RawFn = *const fn (usize, c_int, [*]const f64, c_int, c_int, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_mp_dist);
    try expect(raw(0, 10, &b, 10, 3, &dist) == -1);
}

test "ABI: ts_extract_features null values pointer -> error" {
    var feats: [22]f64 = undefined;
    const RawFn = *const fn (usize, c_int, ?[*]f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_extract_features);
    try expect(raw(0, 3, &feats) == -1);
}

test "ABI: ts_cosine_similarity null a pointer -> error" {
    const b = [_]f64{ 1, 2, 3 };
    var result: f64 = undefined;
    const RawFn = *const fn (usize, [*]const f64, c_int, ?*f64) callconv(.c) c_int;
    const raw = asRaw(RawFn, &abi.ts_cosine_similarity);
    try expect(raw(0, &b, 3, &result) == -1);
}
