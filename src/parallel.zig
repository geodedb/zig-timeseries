// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel batch entry points for timeseries algorithms that have clean
//! embarrassingly-parallel structure.
//!
//! **In scope:**
//! - `parallelBatchDTW` — DTW (constrained / derivative / open-end / shape
//!   / soft) over a query vs. `candidates.len` candidate series
//! - `parallelBatchLbKeogh` — LB_Keogh prefilter over a batch
//! - `parallelBatchDistances` — SBD / LCSS / EDR / ERP / TWED / cross-corr
//! - `parallelMpDistAbJoin` — MP-distance via AB-join matrix profile,
//!   parallelized over rows (`i`)
//!
//! **Out of scope (requires algorithm redesign):**
//! - `matrixProfile` STOMP self-join — incremental QT updates across rows
//!   create carried dependencies. Needs SCRIMP++ / diagonal decomposition.
//! - softDTW row-level parallelism — rolling-buffer dependence on
//!   `curr_row[j-1]`. Needs wavefront traversal.
//! - Per-call internal parallelism for constrainedDTW — same DP row
//!   dependency as self-join.
//!
//! **C ABI exposure:** NONE. Go/Python FFI consumers dispatch across
//! their own runtime pools; Zig-native callers get this module.

const std = @import("std");
const tp = @import("thread_pool");

const dtw_mod = @import("dtw.zig");
const distances_mod = @import("distances.zig");
const matrix_profile_mod = @import("matrix_profile.zig");
const types = @import("types.zig");

pub const DtwResult = types.DtwResult;
pub const CorrelationResult = types.CorrelationResult;
pub const TsError = types.TsError;

/// Default work items per submitted task. Chosen so per-task submit
/// overhead (~500 ns) is amortized across enough work to hide it.
/// Task 8 retunes this against the bench suite.
pub const default_chunk_size: usize = 16;

/// DTW variant selector for batch calls.
pub const DtwVariant = enum {
    constrained,
    derivative,
    open_end,
    /// Shape DTW requires a descriptor length; see `DtwOptions.descriptor_len`.
    shape,
    /// Soft DTW returns a scalar distance (no path). The result's `path`
    /// is empty.
    soft,
};

pub const DtwOptions = struct {
    variant: DtwVariant = .constrained,
    /// Sakoe-Chiba band. 0 → unconstrained.
    band: usize = 0,
    /// Soft-DTW gamma. Ignored for other variants.
    gamma: f64 = 1.0,
    /// Shape-DTW descriptor length. Ignored for other variants.
    descriptor_len: usize = 8,
};

/// Non-DTW distance metric selector.
pub const DistanceMetric = enum {
    sbd,
    lcss,
    edr,
    erp,
    twed,
    /// Pearson-like cross-correlation — result is a `CorrelationResult`,
    /// not a scalar. Batch callers should use
    /// `parallelBatchCrossCorrelate` instead.
    cross_correlate,
};

pub const DistanceOptions = struct {
    metric: DistanceMetric = .sbd,
    /// LCSS / EDR threshold.
    epsilon: f64 = 0.1,
    /// ERP gap penalty reference value.
    erp_gap: f64 = 0.0,
    /// TWED stiffness.
    twed_nu: f64 = 0.001,
    twed_lambda: f64 = 1.0,
};

pub const BatchOptions = struct {
    /// Candidates per submitted task. 0 → use `default_chunk_size`.
    chunk_size: usize = 0,
    /// Thread-pool lane for submissions.
    lane: tp.TaskLane = .default,
};

/// Per-pair result for batch calls that may fail per-pair.
pub fn BatchResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: TsError,
    };
}

// ============================================================================
// Stubs — Tasks 4–7 fill in
// ============================================================================

/// Batch DTW: run `options.variant` between `query` and each element of
/// `candidates`. `out_results` MUST be the same length as `candidates`.
/// Distances that fail (e.g., candidate too short for derivative DTW)
/// surface as `.err`; successful ones carry an owned `DtwResult.path`
/// the caller must free via `result.ok.deinit(allocator)`.
pub fn parallelBatchDTW(
    allocator: std.mem.Allocator,
    pool: ?*tp.ThreadPool,
    query: []const f64,
    candidates: []const []const f64,
    out_results: []BatchResult(DtwResult),
    options: DtwOptions,
    batch_options: BatchOptions,
) !usize {
    _ = allocator;
    _ = pool;
    _ = query;
    _ = candidates;
    _ = out_results;
    _ = options;
    _ = batch_options;
    @panic("parallelBatchDTW: not implemented");
}

/// Batch LB_Keogh prefilter. Returns distances directly (no allocation
/// per result — `lbKeogh` is stack-only for series <= 8192).
pub fn parallelBatchLbKeogh(
    allocator: std.mem.Allocator,
    pool: ?*tp.ThreadPool,
    query: []const f64,
    candidates: []const []const f64,
    out_distances: []f64,
    band: usize,
    batch_options: BatchOptions,
) !void {
    _ = allocator;
    _ = pool;
    _ = query;
    _ = candidates;
    _ = out_distances;
    _ = band;
    _ = batch_options;
    @panic("parallelBatchLbKeogh: not implemented");
}

/// Batch non-DTW distances. Covers sbd/lcss/edr/erp/twed. For
/// cross-correlation use `parallelBatchCrossCorrelate`.
pub fn parallelBatchDistances(
    allocator: std.mem.Allocator,
    pool: ?*tp.ThreadPool,
    query: []const f64,
    candidates: []const []const f64,
    out_results: []BatchResult(f64),
    options: DistanceOptions,
    batch_options: BatchOptions,
) !usize {
    _ = allocator;
    _ = pool;
    _ = query;
    _ = candidates;
    _ = out_results;
    _ = options;
    _ = batch_options;
    @panic("parallelBatchDistances: not implemented");
}

/// Parallel AB-join MP-distance. `a` and `b` are both non-empty series
/// with `a.len >= window_len` and `b.len >= window_len`. Returns the
/// 5th-percentile AB-join distance (matching serial `mpDist`).
pub fn parallelMpDistAbJoin(
    allocator: std.mem.Allocator,
    pool: ?*tp.ThreadPool,
    a: []const f64,
    b: []const f64,
    window_len: usize,
    batch_options: BatchOptions,
) (TsError || error{OutOfMemory})!f64 {
    _ = allocator;
    _ = pool;
    _ = a;
    _ = b;
    _ = window_len;
    _ = batch_options;
    @panic("parallelMpDistAbJoin: not implemented");
}
