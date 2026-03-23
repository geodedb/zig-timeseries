// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! C ABI exports for the time-series library.
//!
//! These functions are callable from Go via CGO (or any C-compatible FFI).
//! Each export function:
//! 1. Validates inputs (null pointers, negative lengths, NaN/Inf values)
//! 2. Creates BOUNDED slices from raw C pointers -- prevents out-of-bounds access
//! 3. Calls the idiomatic Zig API
//! 4. Copies results to C output parameters
//! 5. Returns 0 on success, -1 on error

const std = @import("std");
const dtw = @import("dtw.zig");
const distances = @import("distances.zig");
const mp = @import("matrix_profile.zig");
const features = @import("features.zig");
const pelt_mod = @import("pelt.zig");

/// Allocator used by all ABI functions. C consumers get page_allocator;
/// internal Zig callers can use the module functions directly with any allocator.
const abi_allocator = std.heap.page_allocator;

/// Validate that all elements in a bounded slice are finite (not NaN or Inf).
/// Returns true if all values are finite, false otherwise.
fn validateFiniteSlice(slice: []const f64) bool {
    for (slice) |v| {
        if (std.math.isNan(v) or std.math.isInf(v)) return false;
    }
    return true;
}

/// Library ABI version. Returns 2.
pub export fn ts_version() callconv(.c) c_int {
    return 2;
}

// ============================================================================
// DTW exports -- use idiomatic Zig API with bounded slices at ABI boundary
// ============================================================================

/// Helper to copy a DtwResult's path into C output arrays and free the result.
fn copyDtwPath(
    result: anytype,
    path_i: [*]i32,
    path_j: [*]i32,
    path_cap: c_int,
    path_len: *c_int,
    dist: *f64,
) c_int {
    defer result.deinit(abi_allocator);
    const plen: i32 = @intCast(result.path.len);
    if (plen > path_cap) return -1;
    dist.* = result.distance;
    for (0..result.path.len) |k| {
        path_i[k] = result.path[k].i;
        path_j[k] = result.path[k].j;
    }
    path_len.* = plen;
    return 0;
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
    // Create bounded slices from raw C pointers
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const band_u: usize = if (band <= 0) 0 else @intCast(band);
    const result = dtw.constrainedDTW(abi_allocator, a_slice, b_slice, band_u) catch return -1;
    return copyDtwPath(result, path_i, path_j, path_cap, path_len, dist);
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const band_u: usize = if (band <= 0) 0 else @intCast(band);
    const result = dtw.derivativeDTW(abi_allocator, a_slice, b_slice, band_u) catch return -1;
    return copyDtwPath(result, path_i, path_j, path_cap, path_len, dist);
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const band_u: usize = if (band <= 0) 0 else @intCast(band);
    const result = dtw.openEndDTW(abi_allocator, a_slice, b_slice, band_u) catch return -1;
    return copyDtwPath(result, path_i, path_j, path_cap, path_len, dist);
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
    if (descriptor_len <= 0) return -1;
    if (path_cap < 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const band_u: usize = if (band <= 0) 0 else @intCast(band);
    const dlen: usize = @intCast(descriptor_len);
    const result = dtw.shapeDTW(abi_allocator, a_slice, b_slice, band_u, dlen) catch return -1;
    return copyDtwPath(result, path_i, path_j, path_cap, path_len, dist);
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    dist.* = dtw.softDTW(abi_allocator, a_slice, b_slice, gamma) catch return -1;
    return 0;
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const band_u: usize = if (band <= 0) 0 else @intCast(band);
    result.* = dtw.lbKeogh(a_slice, b_slice, band_u);
    return 0;
}

// ============================================================================
// Distance exports -- use idiomatic Zig API with bounded slices at ABI boundary
// ============================================================================

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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const result = distances.crossCorrelate(a_slice, b_slice) catch return -1;
    lag.* = result.lag;
    corr.* = result.correlation;
    return 0;
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    dist.* = distances.sbd(a_slice, b_slice) catch return -1;
    return 0;
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
    const n: usize = @intCast(values_len);
    if (n > 0) {
        const v_slice = values[0..n];
        if (!validateFiniteSlice(v_slice)) return -1;
        const ms: usize = if (min_size <= 0) 1 else @intCast(min_size);
        const result = pelt_mod.pelt(abi_allocator, v_slice, penalty, ms) catch return -1;
        defer abi_allocator.free(result);
        const clen: c_int = @intCast(result.len);
        if (clen > cps_cap) return -1;
        for (0..result.len) |i| {
            cps[i] = @intCast(result[i]);
        }
        cps_len.* = clen;
    } else {
        cps_len.* = 0;
    }
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    const delta_u: usize = if (delta <= 0) 0 else @intCast(delta);
    dist.* = distances.lcss(abi_allocator, a_slice, b_slice, epsilon, delta_u) catch return -1;
    return 0;
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    dist.* = distances.edr(abi_allocator, a_slice, b_slice, epsilon) catch return -1;
    return 0;
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    dist.* = distances.erp(abi_allocator, a_slice, b_slice, gap_value) catch return -1;
    return 0;
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
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    const at_slice = a_times[0..n];
    const bt_slice = b_times[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    if (!validateFiniteSlice(at_slice) or !validateFiniteSlice(bt_slice)) return -1;
    dist.* = distances.twed(abi_allocator, a_slice, at_slice, b_slice, bt_slice, lambda, nu) catch return -1;
    return 0;
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
    if (values_len <= 0 or window_len <= 0) return -1;
    if (out_cap < 0) return -1;
    const n: usize = @intCast(values_len);
    const w: usize = @intCast(window_len);
    const v_slice = values[0..n];
    if (!validateFiniteSlice(v_slice)) return -1;
    // Pre-check: profile length = values_len - window_len + 1.
    if (w <= n) {
        const expected_plen: c_int = @intCast(n - w + 1);
        if (expected_plen > out_cap) return -1;
    }
    const result = mp.matrixProfile(abi_allocator, v_slice, w) catch return -1;
    defer result.deinit(abi_allocator);
    const plen = result.profile.len;
    for (0..plen) |i| {
        profile[i] = result.profile[i];
        indices[i] = @intCast(result.indices[i]);
    }
    profile_len.* = @intCast(plen);
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
    if (a_len <= 0 or b_len <= 0 or window_len <= 0) return -1;
    const n: usize = @intCast(a_len);
    const m: usize = @intCast(b_len);
    const w: usize = @intCast(window_len);
    const a_slice = a[0..n];
    const b_slice = b[0..m];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    dist.* = mp.mpDist(abi_allocator, a_slice, b_slice, w) catch return -1;
    return 0;
}

/// Extract 22-element feature vector.
pub export fn ts_extract_features(
    values: [*]const f64,
    values_len: c_int,
    features_out: [*]f64,
) callconv(.c) c_int {
    if (@intFromPtr(features_out) == 0) return -1;
    if (values_len <= 0) return -1;
    const n: usize = @intCast(values_len);
    const v_slice = values[0..n];
    if (!validateFiniteSlice(v_slice)) return -1;
    const feats = features.extractFeatures(abi_allocator, v_slice) catch return -1;
    for (0..features.FeatureIndex.feature_count) |i| {
        features_out[i] = feats[i];
    }
    return 0;
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
    const n: usize = @intCast(len);
    const a_slice = a[0..n];
    const b_slice = b[0..n];
    if (!validateFiniteSlice(a_slice) or !validateFiniteSlice(b_slice)) return -1;
    result.* = features.cosineSimilarity(a_slice, b_slice);
    return 0;
}
