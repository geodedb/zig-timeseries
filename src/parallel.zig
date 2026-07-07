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
    /// LCSS Sakoe-Chiba band width (0 = unconstrained).
    delta: usize = 0,
    /// ERP gap penalty reference value.
    erp_gap: f64 = 0.0,
    /// TWED stiffness. NOTE: TWED is NOT supported via
    /// `parallelBatchDistances` because it requires per-timestep time
    /// vectors that don't fit the `(query, candidates[])` batch shape.
    /// Use `twed` directly for single-pair TWED.
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
    if (out_results.len != candidates.len) return error.LengthMismatch;
    if (candidates.len == 0) return 0;

    if (pool == null or candidates.len == 1) {
        var ok_count: usize = 0;
        for (candidates, 0..) |c, idx| {
            out_results[idx] = runDtwOne(allocator, query, c, options);
            if (out_results[idx] == .ok) ok_count += 1;
        }
        return ok_count;
    }

    const chunk_size = if (batch_options.chunk_size == 0) default_chunk_size else batch_options.chunk_size;
    const p = pool.?;
    const n_chunks = (candidates.len + chunk_size - 1) / chunk_size;

    const ctxs = try allocator.alloc(DtwChunkCtx, n_chunks);
    defer allocator.free(ctxs);

    var wg = p.waitGroup();

    var i: usize = 0;
    var ci: usize = 0;
    while (i < candidates.len) : (ci += 1) {
        const end = @min(i + chunk_size, candidates.len);
        ctxs[ci] = .{
            .allocator = allocator,
            .query = query,
            .candidates = candidates[i..end],
            .out_slice = out_results[i..end],
            .options = options,
            .wg = &wg,
        };
        i = end;
    }
    wg.add(@intCast(n_chunks));

    for (ctxs, 0..) |*c, k| {
        _ = p.submit(dtwChunkTask, c, .{ .lane = batch_options.lane }) catch {
            for (ctxs[k..]) |*rest| {
                dtwChunkInline(rest);
                rest.wg.done();
            }
            break;
        };
    }
    wg.wait();

    var ok_count: usize = 0;
    for (out_results) |r| if (r == .ok) {
        ok_count += 1;
    };
    return ok_count;
}

fn runDtwOne(
    allocator: std.mem.Allocator,
    query: []const f64,
    candidate: []const f64,
    options: DtwOptions,
) BatchResult(DtwResult) {
    const result = switch (options.variant) {
        .constrained => dtw_mod.constrainedDTW(allocator, query, candidate, options.band),
        .derivative => dtw_mod.derivativeDTW(allocator, query, candidate, options.band),
        .open_end => dtw_mod.openEndDTW(allocator, query, candidate, options.band),
        .shape => dtw_mod.shapeDTW(allocator, query, candidate, options.band, options.descriptor_len),
        .soft => blk: {
            const dist = dtw_mod.softDTW(allocator, query, candidate, options.gamma) catch |e| {
                break :blk @as(anyerror!DtwResult, e);
            };
            break :blk @as(anyerror!DtwResult, DtwResult{ .distance = dist, .path = &.{} });
        },
    } catch |e| return .{ .err = mapTsError(e) };

    return .{ .ok = result };
}

fn mapTsError(e: anyerror) TsError {
    return switch (e) {
        error.InvalidInput => TsError.InvalidInput,
        error.AllocationTooLarge => TsError.AllocationTooLarge,
        error.SeriesTooLong => TsError.SeriesTooLong,
        error.OutOfMemory => TsError.OutOfMemory,
        else => TsError.InvalidInput, // defensive catch-all for unexpected errors
    };
}

const DtwChunkCtx = struct {
    allocator: std.mem.Allocator,
    query: []const f64,
    candidates: []const []const f64,
    out_slice: []BatchResult(DtwResult),
    options: DtwOptions,
    wg: *tp.WaitGroup,
};

fn dtwChunkTask(ctx_: *anyopaque, _: *tp.TaskContext) void {
    const c: *DtwChunkCtx = @ptrCast(@alignCast(ctx_));
    dtwChunkInline(c);
    c.wg.done();
}

fn dtwChunkInline(c: *DtwChunkCtx) void {
    for (c.candidates, 0..) |cand, idx| {
        c.out_slice[idx] = runDtwOne(c.allocator, c.query, cand, c.options);
    }
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
    if (out_distances.len != candidates.len) return error.LengthMismatch;
    if (candidates.len == 0) return;

    if (pool == null or candidates.len == 1) {
        for (candidates, 0..) |c, idx| out_distances[idx] = dtw_mod.lbKeogh(query, c, band);
        return;
    }

    const chunk_size = if (batch_options.chunk_size == 0) default_chunk_size else batch_options.chunk_size;
    const p = pool.?;
    const n_chunks = (candidates.len + chunk_size - 1) / chunk_size;

    const ctxs = try allocator.alloc(LbKeoghChunkCtx, n_chunks);
    defer allocator.free(ctxs);

    var wg = p.waitGroup();

    var i: usize = 0;
    var ci: usize = 0;
    while (i < candidates.len) : (ci += 1) {
        const end = @min(i + chunk_size, candidates.len);
        ctxs[ci] = .{
            .query = query,
            .candidates = candidates[i..end],
            .out_slice = out_distances[i..end],
            .band = band,
            .wg = &wg,
        };
        i = end;
    }
    wg.add(@intCast(n_chunks));

    for (ctxs, 0..) |*c, k| {
        _ = p.submit(lbKeoghChunkTask, c, .{ .lane = batch_options.lane }) catch {
            for (ctxs[k..]) |*rest| {
                lbKeoghChunkInline(rest);
                rest.wg.done();
            }
            break;
        };
    }
    wg.wait();
}

const LbKeoghChunkCtx = struct {
    query: []const f64,
    candidates: []const []const f64,
    out_slice: []f64,
    band: usize,
    wg: *tp.WaitGroup,
};

fn lbKeoghChunkTask(ctx_: *anyopaque, _: *tp.TaskContext) void {
    const c: *LbKeoghChunkCtx = @ptrCast(@alignCast(ctx_));
    lbKeoghChunkInline(c);
    c.wg.done();
}

fn lbKeoghChunkInline(c: *LbKeoghChunkCtx) void {
    for (c.candidates, 0..) |cand, idx| {
        c.out_slice[idx] = dtw_mod.lbKeogh(c.query, cand, c.band);
    }
}

/// Batch non-DTW distances. Covers sbd/lcss/edr/erp. For
/// cross-correlation use `parallelBatchCrossCorrelate`.
/// NOTE: `.twed` returns `.err = TsError.InvalidInput` — TWED requires
/// per-timestep time vectors that don't fit the `(query, candidates[])`
/// batch shape. Use `distances.twed` directly for single-pair TWED.
pub fn parallelBatchDistances(
    allocator: std.mem.Allocator,
    pool: ?*tp.ThreadPool,
    query: []const f64,
    candidates: []const []const f64,
    out_results: []BatchResult(f64),
    options: DistanceOptions,
    batch_options: BatchOptions,
) !usize {
    if (out_results.len != candidates.len) return error.LengthMismatch;
    if (candidates.len == 0) return 0;

    if (pool == null or candidates.len == 1) {
        var ok_count: usize = 0;
        for (candidates, 0..) |c, idx| {
            out_results[idx] = runDistanceOne(allocator, query, c, options);
            if (out_results[idx] == .ok) ok_count += 1;
        }
        return ok_count;
    }

    const chunk_size = if (batch_options.chunk_size == 0) default_chunk_size else batch_options.chunk_size;
    const p = pool.?;
    const n_chunks = (candidates.len + chunk_size - 1) / chunk_size;

    const ctxs = try allocator.alloc(DistanceChunkCtx, n_chunks);
    defer allocator.free(ctxs);

    var wg = p.waitGroup();

    var i: usize = 0;
    var ci: usize = 0;
    while (i < candidates.len) : (ci += 1) {
        const end = @min(i + chunk_size, candidates.len);
        ctxs[ci] = .{
            .allocator = allocator,
            .query = query,
            .candidates = candidates[i..end],
            .out_slice = out_results[i..end],
            .options = options,
            .wg = &wg,
        };
        i = end;
    }
    wg.add(@intCast(n_chunks));

    for (ctxs, 0..) |*c, k| {
        _ = p.submit(distanceChunkTask, c, .{ .lane = batch_options.lane }) catch {
            for (ctxs[k..]) |*rest| {
                distanceChunkInline(rest);
                rest.wg.done();
            }
            break;
        };
    }
    wg.wait();

    var ok_count: usize = 0;
    for (out_results) |r| if (r == .ok) {
        ok_count += 1;
    };
    return ok_count;
}

fn runDistanceOne(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    options: DistanceOptions,
) BatchResult(f64) {
    const d: f64 = switch (options.metric) {
        .sbd => distances_mod.sbd(allocator, a, b) catch |e| return .{ .err = mapTsError(e) },
        .lcss => distances_mod.lcss(allocator, a, b, options.epsilon, options.delta) catch |e|
            return .{ .err = mapTsError(e) },
        .edr => distances_mod.edr(allocator, a, b, options.epsilon) catch |e|
            return .{ .err = mapTsError(e) },
        .erp => distances_mod.erp(allocator, a, b, options.erp_gap) catch |e|
            return .{ .err = mapTsError(e) },
        .twed => return .{ .err = TsError.InvalidInput }, // TWED requires paired time vectors; not supported via batch API
        .cross_correlate => return .{ .err = TsError.InvalidInput }, // wrong entry point — use parallelBatchCrossCorrelate if needed
    };
    return .{ .ok = d };
}

const DistanceChunkCtx = struct {
    allocator: std.mem.Allocator,
    query: []const f64,
    candidates: []const []const f64,
    out_slice: []BatchResult(f64),
    options: DistanceOptions,
    wg: *tp.WaitGroup,
};

fn distanceChunkTask(ctx_: *anyopaque, _: *tp.TaskContext) void {
    const c: *DistanceChunkCtx = @ptrCast(@alignCast(ctx_));
    distanceChunkInline(c);
    c.wg.done();
}

fn distanceChunkInline(c: *DistanceChunkCtx) void {
    for (c.candidates, 0..) |cand, idx| {
        c.out_slice[idx] = runDistanceOne(c.allocator, c.query, cand, c.options);
    }
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
) TsError!f64 {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0 or window_len == 0) return TsError.InvalidInput;
    if (window_len > n or window_len > m) return TsError.InvalidInput;
    if (n > matrix_profile_mod.MAX_SERIES_LEN or m > matrix_profile_mod.MAX_SERIES_LEN) return TsError.SeriesTooLong;

    const w = window_len;
    const plen_a = n - w + 1;
    const plen_b = m - w + 1;

    const ab_buf = try allocator.alloc(f64, plen_a);
    defer allocator.free(ab_buf);

    const means_a = try allocator.alloc(f64, plen_a);
    defer allocator.free(means_a);
    const stds_a = try allocator.alloc(f64, plen_a);
    defer allocator.free(stds_a);
    const means_b = try allocator.alloc(f64, plen_b);
    defer allocator.free(means_b);
    const stds_b = try allocator.alloc(f64, plen_b);
    defer allocator.free(stds_b);

    matrix_profile_mod.precomputeStats(a, w, means_a, stds_a);
    matrix_profile_mod.precomputeStats(b, w, means_b, stds_b);

    if (pool == null or plen_a == 1) {
        for (0..plen_a) |i| {
            ab_buf[i] = matrix_profile_mod.mpDistAbJoinRow(
                a,
                b,
                means_a,
                stds_a,
                means_b,
                stds_b,
                i,
                w,
            );
        }
    } else {
        const chunk_size = if (batch_options.chunk_size == 0) default_chunk_size else batch_options.chunk_size;
        const p = pool.?;
        const n_chunks = (plen_a + chunk_size - 1) / chunk_size;

        const ctxs = try allocator.alloc(MpRowChunkCtx, n_chunks);
        defer allocator.free(ctxs);

        var wg = p.waitGroup();

        var i: usize = 0;
        var ci: usize = 0;
        while (i < plen_a) : (ci += 1) {
            const end = @min(i + chunk_size, plen_a);
            ctxs[ci] = .{
                .a = a,
                .b = b,
                .means_a = means_a,
                .stds_a = stds_a,
                .means_b = means_b,
                .stds_b = stds_b,
                .row_lo = i,
                .row_hi = end,
                .w = w,
                .out = ab_buf,
                .wg = &wg,
            };
            i = end;
        }
        wg.add(@intCast(n_chunks));

        for (ctxs, 0..) |*c, k| {
            _ = p.submit(mpRowChunkTask, c, .{ .lane = batch_options.lane }) catch {
                for (ctxs[k..]) |*rest| {
                    mpRowChunkInline(rest);
                    rest.wg.done();
                }
                break;
            };
        }
        wg.wait();
    }

    std.mem.sort(f64, ab_buf, {}, std.sort.asc(f64));
    const k = @max(@as(usize, 1), plen_a * 5 / 100);
    return ab_buf[k - 1];
}

const MpRowChunkCtx = struct {
    a: []const f64,
    b: []const f64,
    means_a: []const f64,
    stds_a: []const f64,
    means_b: []const f64,
    stds_b: []const f64,
    row_lo: usize,
    row_hi: usize,
    w: usize,
    out: []f64,
    wg: *tp.WaitGroup,
};

fn mpRowChunkTask(ctx_: *anyopaque, _: *tp.TaskContext) void {
    const c: *MpRowChunkCtx = @ptrCast(@alignCast(ctx_));
    mpRowChunkInline(c);
    c.wg.done();
}

fn mpRowChunkInline(c: *MpRowChunkCtx) void {
    for (c.row_lo..c.row_hi) |i| {
        c.out[i] = matrix_profile_mod.mpDistAbJoinRow(
            c.a,
            c.b,
            c.means_a,
            c.stds_a,
            c.means_b,
            c.stds_b,
            i,
            c.w,
        );
    }
}
