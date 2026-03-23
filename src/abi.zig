// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! C ABI exports for the time-series library.
//! These functions are callable from Go via CGO (or any C-compatible FFI).

const std = @import("std");
const dtw = @import("dtw.zig");
const distances = @import("distances.zig");
const mp = @import("matrix_profile.zig");
const features = @import("features.zig");
const pelt_mod = @import("pelt.zig");

/// Allocator used by all ABI functions. C consumers get page_allocator;
/// internal Zig callers can use the module functions directly with any allocator.
const abi_allocator = std.heap.page_allocator;

/// Validate that all elements in a slice are finite (not NaN or Inf).
/// Returns true if all values are finite, false otherwise.
fn validateFinite(ptr: [*]const f64, len: usize) bool {
    for (0..len) |i| {
        if (std.math.isNan(ptr[i]) or std.math.isInf(ptr[i])) return false;
    }
    return true;
}

/// Library ABI version. Returns 2.
pub export fn ts_version() callconv(.c) c_int {
    return 2;
}

/// Constrained DTW with Sakoe-Chiba band.
pub export fn ts_dtw(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    band: c_int,
    dist: *f64,
    path_i: [*]i32,
    path_j: [*]i32,
    path_len: *c_int,
    path_cap: c_int,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (@intFromPtr(path_i) == 0) return -1;
    if (@intFromPtr(path_j) == 0) return -1;
    if (@intFromPtr(path_len) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (path_cap < 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    var plen: i32 = undefined;
    const rc = dtw.constrainedDTW(abi_allocator, a, a_len, b, b_len, band, dist, path_i, path_j, &plen);
    if (rc != 0) return rc;
    if (plen > path_cap) return -1;
    path_len.* = plen;
    return 0;
}

/// Derivative DTW.
pub export fn ts_dtw_derivative(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    band: c_int,
    dist: *f64,
    path_i: [*]i32,
    path_j: [*]i32,
    path_len: *c_int,
    path_cap: c_int,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (@intFromPtr(path_i) == 0) return -1;
    if (@intFromPtr(path_j) == 0) return -1;
    if (@intFromPtr(path_len) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (path_cap < 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    var plen: i32 = undefined;
    const rc = dtw.derivativeDTW(abi_allocator, a, a_len, b, b_len, band, dist, path_i, path_j, &plen);
    if (rc != 0) return rc;
    if (plen > path_cap) return -1;
    path_len.* = plen;
    return 0;
}

/// Open-end DTW.
pub export fn ts_dtw_open_end(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    band: c_int,
    dist: *f64,
    path_i: [*]i32,
    path_j: [*]i32,
    path_len: *c_int,
    path_cap: c_int,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (@intFromPtr(path_i) == 0) return -1;
    if (@intFromPtr(path_j) == 0) return -1;
    if (@intFromPtr(path_len) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (path_cap < 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    var plen: i32 = undefined;
    const rc = dtw.openEndDTW(abi_allocator, a, a_len, b, b_len, band, dist, path_i, path_j, &plen);
    if (rc != 0) return rc;
    if (plen > path_cap) return -1;
    path_len.* = plen;
    return 0;
}

/// Shape DTW with local descriptors.
pub export fn ts_dtw_shape(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    band: c_int,
    descriptor_len: c_int,
    dist: *f64,
    path_i: [*]i32,
    path_j: [*]i32,
    path_len: *c_int,
    path_cap: c_int,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (@intFromPtr(path_i) == 0) return -1;
    if (@intFromPtr(path_j) == 0) return -1;
    if (@intFromPtr(path_len) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (path_cap < 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    var plen: i32 = undefined;
    const rc = dtw.shapeDTW(abi_allocator, a, a_len, b, b_len, band, descriptor_len, dist, path_i, path_j, &plen);
    if (rc != 0) return rc;
    if (plen > path_cap) return -1;
    path_len.* = plen;
    return 0;
}

/// Soft DTW (differentiable).
pub export fn ts_soft_dtw(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    gamma: f64,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    return dtw.softDTW(abi_allocator, a, a_len, b, b_len, gamma, dist);
}

/// LB_Keogh lower bound on DTW.
pub export fn ts_lb_keogh(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    band: c_int,
    result: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(result) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    result.* = dtw.lbKeogh(a, a_len, b, b_len, band);
    return 0;
}

/// Normalized cross-correlation.
pub export fn ts_cross_correlate(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    lag: *c_int,
    corr: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(lag) == 0) return -1;
    if (@intFromPtr(corr) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    var lag_i32: i32 = undefined;
    const rc = distances.crossCorrelate(a, a_len, b, b_len, &lag_i32, corr);
    lag.* = lag_i32;
    return rc;
}

/// Shape-based distance.
pub export fn ts_sbd(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    return distances.sbd(a, a_len, b, b_len, dist);
}

/// PELT segmentation.
pub export fn ts_pelt(
    values: [*]const f64,
    values_len: c_int,
    penalty: f64,
    min_size: c_int,
    cps: [*]i32,
    cps_len: *c_int,
    cps_cap: c_int,
) callconv(.c) c_int {
    if (@intFromPtr(cps) == 0) return -1;
    if (@intFromPtr(cps_len) == 0) return -1;
    if (values_len < 0) return -1;
    if (cps_cap < 0) return -1;
    if (values_len > 0 and !validateFinite(values, @intCast(values_len))) return -1;
    var clen: i32 = undefined;
    const rc = pelt_mod.pelt(abi_allocator, values, values_len, penalty, min_size, cps, &clen);
    if (rc != 0) return rc;
    if (clen > cps_cap) return -1;
    cps_len.* = clen;
    return 0;
}

/// LCSS distance.
pub export fn ts_lcss(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    epsilon: f64,
    delta: c_int,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    return distances.lcss(abi_allocator, a, a_len, b, b_len, epsilon, delta, dist);
}

/// EDR distance.
pub export fn ts_edr(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    epsilon: f64,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    return distances.edr(abi_allocator, a, a_len, b, b_len, epsilon, dist);
}

/// ERP distance.
pub export fn ts_erp(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    gap_value: f64,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    return distances.erp(abi_allocator, a, a_len, b, b_len, gap_value, dist);
}

/// TWED distance.
pub export fn ts_twed(
    a: [*]const f64,
    a_len: c_int,
    a_times: [*]const f64,
    b: [*]const f64,
    b_len: c_int,
    b_times: [*]const f64,
    lambda: f64,
    nu: f64,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    if (!validateFinite(a_times, @intCast(a_len)) or !validateFinite(b_times, @intCast(b_len))) return -1;
    return distances.twed(abi_allocator, a, a_len, a_times, b, b_len, b_times, lambda, nu, dist);
}

/// Matrix profile computation.
pub export fn ts_matrix_profile(
    values: [*]const f64,
    values_len: c_int,
    window_len: c_int,
    profile: [*]f64,
    indices: [*]i32,
    profile_len: *c_int,
    out_cap: c_int,
) callconv(.c) c_int {
    if (@intFromPtr(profile) == 0) return -1;
    if (@intFromPtr(indices) == 0) return -1;
    if (@intFromPtr(profile_len) == 0) return -1;
    if (values_len <= 0) return -1;
    if (out_cap < 0) return -1;
    if (!validateFinite(values, @intCast(values_len))) return -1;
    // Pre-check: profile length = values_len - window_len + 1.
    if (window_len > 0 and values_len >= window_len) {
        const expected_plen = values_len - window_len + 1;
        if (expected_plen > out_cap) return -1;
    }
    var plen: i32 = undefined;
    const rc = mp.matrixProfile(abi_allocator, values, values_len, window_len, profile, indices, &plen);
    if (rc != 0) return rc;
    profile_len.* = plen;
    return 0;
}

/// Matrix Profile distance.
pub export fn ts_mp_dist(
    a: [*]const f64,
    a_len: c_int,
    b: [*]const f64,
    b_len: c_int,
    window_len: c_int,
    dist: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(dist) == 0) return -1;
    if (a_len <= 0 or b_len <= 0) return -1;
    if (!validateFinite(a, @intCast(a_len)) or !validateFinite(b, @intCast(b_len))) return -1;
    return mp.mpDist(abi_allocator, a, a_len, b, b_len, window_len, dist);
}

/// Extract 22-element feature vector.
pub export fn ts_extract_features(
    values: [*]const f64,
    values_len: c_int,
    features_out: [*]f64,
) callconv(.c) c_int {
    if (@intFromPtr(features_out) == 0) return -1;
    if (values_len <= 0) return -1;
    if (!validateFinite(values, @intCast(values_len))) return -1;
    return features.extractFeatures(abi_allocator, values, values_len, features_out);
}

/// Cosine similarity between two vectors.
pub export fn ts_cosine_similarity(
    a: [*]const f64,
    b: [*]const f64,
    len: c_int,
    result: *f64,
) callconv(.c) c_int {
    if (@intFromPtr(result) == 0) return -1;
    if (len <= 0) return -1;
    if (!validateFinite(a, @intCast(len)) or !validateFinite(b, @intCast(len))) return -1;
    result.* = features.cosineSimilarity(a, b, len);
    return 0;
}
