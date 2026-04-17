// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Benchmark suite for the timeseries library.
//!
//! Measures wall-clock time for core algorithms at representative input sizes.
//! Run with: `zig build bench`

const std = @import("std");
const ts = @import("timeseries");
const tp = @import("thread_pool");

const allocator = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Timing helper
// ---------------------------------------------------------------------------

/// Monotonic nanosecond timestamp. Replaces std.time.Timer (removed in 0.16).
fn monoNs() u64 {
    var tspec: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &tspec);
    return @as(u64, @intCast(tspec.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(tspec.nsec));
}

/// Write a formatted string to stdout using a direct Linux syscall.
/// std.posix.write was removed in Zig 0.16; use std.os.linux.write instead.
fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.os.linux.write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);
}

/// Run a benchmark function `iterations` times, reporting min/mean/max ns/op.
fn runBench(
    comptime name: []const u8,
    comptime benchFn: fn () void,
    iterations: usize,
) void {
    // Warmup: 10% of iterations (minimum 1).
    const warmup = @max(1, iterations / 10);
    for (0..warmup) |_| {
        benchFn();
    }

    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    for (0..iterations) |_| {
        const t0 = monoNs();
        benchFn();
        const elapsed = monoNs() - t0;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
        total_ns += elapsed;
    }

    const mean_ns = total_ns / iterations;
    writeStdout("  {s:<35} {d:>10} iters   min={d:>10} ns   mean={d:>10} ns   max={d:>10} ns\n", .{
        name,
        iterations,
        min_ns,
        mean_ns,
        max_ns,
    });
}

// ---------------------------------------------------------------------------
// Deterministic test data generators
// ---------------------------------------------------------------------------

/// Generate a sine wave of the given length. Uses page_allocator; caller must free.
fn generateSine(n: usize) []f64 {
    const data = allocator.alloc(f64, n) catch @panic("alloc failed");
    for (0..n) |i| {
        const fi: f64 = @floatFromInt(i);
        data[i] = @sin(fi * 0.1);
    }
    return data;
}

/// Generate a linear ramp of the given length. Uses page_allocator; caller must free.
fn generateRamp(n: usize) []f64 {
    const data = allocator.alloc(f64, n) catch @panic("alloc failed");
    for (0..n) |i| {
        const fi: f64 = @floatFromInt(i);
        data[i] = fi / @as(f64, @floatFromInt(n));
    }
    return data;
}

/// Generate a step function with a change point at the midpoint.
fn generateStep(n: usize) []f64 {
    const data = allocator.alloc(f64, n) catch @panic("alloc failed");
    for (0..n) |i| {
        data[i] = if (i < n / 2) 1.0 else 10.0;
    }
    return data;
}

/// Generate timestamps 0..n-1 as f64.
fn generateTimestamps(n: usize) []f64 {
    const data = allocator.alloc(f64, n) catch @panic("alloc failed");
    for (0..n) |i| {
        data[i] = @floatFromInt(i);
    }
    return data;
}

// ---------------------------------------------------------------------------
// Optimization barrier
// ---------------------------------------------------------------------------

/// Prevent the compiler from optimizing away a value or function call.
/// Uses a volatile store to a global sink variable to force materialization.
var sink: f64 = 0;

fn doNotOptimize(val: anytype) void {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const as_f64: f64 = @floatFromInt(val);
            @as(*volatile f64, @ptrCast(&sink)).* = as_f64;
        },
        .float, .comptime_float => {
            @as(*volatile f64, @ptrCast(&sink)).* = @floatCast(val);
        },
        .@"struct" => {
            // For structs (like InvariantSet), just reference a field.
            if (@hasField(T, "mean")) {
                @as(*volatile f64, @ptrCast(&sink)).* = val.mean;
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Benchmark functions
// ---------------------------------------------------------------------------

// -- DTW benchmarks (100, 500, 1000 points) --

fn makeDTWBench(comptime n: usize) type {
    return struct {
        var a: []f64 = &.{};
        var b: []f64 = &.{};

        fn init() void {
            if (a.len == 0) {
                a = generateSine(n);
                b = generateRamp(n);
            }
        }

        fn run() void {
            init();
            const result = ts.dtw.constrainedDTW(allocator, a, b, n / 5) catch return;
            defer result.deinit(allocator);
            doNotOptimize(result.distance);
        }
    };
}

const DTW100 = makeDTWBench(100);
const DTW500 = makeDTWBench(500);
const DTW1000 = makeDTWBench(1000);

// -- CrossCorrelate benchmark (500 points) --

const CrossCorr = struct {
    var a: []f64 = &.{};
    var b: []f64 = &.{};

    fn init() void {
        if (a.len == 0) {
            a = generateSine(500);
            b = generateRamp(500);
        }
    }

    fn run() void {
        init();
        const result = ts.distances.crossCorrelate(a, b) catch return;
        doNotOptimize(result.correlation);
    }
};

// -- PELT benchmark (500 points) --

const PELTBench = struct {
    var data: []f64 = &.{};

    fn init() void {
        if (data.len == 0) {
            data = generateStep(500);
        }
    }

    fn run() void {
        init();
        const cps = ts.pelt.pelt(allocator, data, 5.0, 2) catch return;
        defer allocator.free(cps);
        doNotOptimize(@as(f64, @floatFromInt(cps.len)));
    }
};

// -- ExtractFeatures benchmark (500 points) --

const FeatureBench = struct {
    var data: []f64 = &.{};

    fn init() void {
        if (data.len == 0) {
            data = generateSine(500);
        }
    }

    fn run() void {
        init();
        const feats = ts.features.extractFeatures(allocator, data) catch return;
        doNotOptimize(feats[0]);
    }
};

// -- Invariant computation benchmark (500 points) --

const InvariantBench = struct {
    var times: []f64 = &.{};
    var values: []f64 = &.{};

    fn init() void {
        if (values.len == 0) {
            times = generateTimestamps(500);
            values = generateSine(500);
        }
    }

    fn run() void {
        init();
        const inv = ts.invariants.computeInvariants(times, values);
        doNotOptimize(inv);
    }
};

// -- ZNormalize benchmark (500 points) --

const ZNormBench = struct {
    var template: []f64 = &.{};
    var work: []f64 = &.{};

    fn init() void {
        if (template.len == 0) {
            template = generateSine(500);
            work = allocator.alloc(f64, 500) catch @panic("alloc failed");
        }
    }

    fn run() void {
        init();
        // Copy template into work buffer so we don't modify the source.
        @memcpy(work, template);
        ts.preprocess.zNormalize(work);
        doNotOptimize(work[0]);
    }
};

// -- ERP benchmark (500 points) --

const ERPBench = struct {
    var a: []f64 = &.{};
    var b: []f64 = &.{};

    fn init() void {
        if (a.len == 0) {
            a = generateSine(500);
            b = generateRamp(500);
        }
    }

    fn run() void {
        init();
        const dist = ts.distances.erp(allocator, a, b, 0.0) catch return;
        doNotOptimize(dist);
    }
};

// ---------------------------------------------------------------------------
// Parallel batch benchmarks (introduced 2026-04-16)
// ---------------------------------------------------------------------------

fn benchBatchDTWSerial(N: usize, len: usize, query: []const f64, cands: []const []const f64) !u64 {
    const results = try allocator.alloc(ts.parallel.BatchResult(ts.DtwResult), N);
    defer {
        for (results) |*r| switch (r.*) {
            .ok => |*dr| dr.deinit(allocator),
            .err => {},
        };
        allocator.free(results);
    }
    const t0 = monoNs();
    _ = try ts.parallel.parallelBatchDTW(
        allocator,
        null,
        query,
        cands,
        results,
        .{ .variant = .constrained, .band = @intCast(len / 4) },
        .{},
    );
    return monoNs() - t0;
}

fn benchBatchDTWParallel(
    N: usize,
    len: usize,
    query: []const f64,
    cands: []const []const f64,
    pool: *tp.ThreadPool,
    chunk_size: usize,
) !u64 {
    const results = try allocator.alloc(ts.parallel.BatchResult(ts.DtwResult), N);
    defer {
        for (results) |*r| switch (r.*) {
            .ok => |*dr| dr.deinit(allocator),
            .err => {},
        };
        allocator.free(results);
    }
    const t0 = monoNs();
    _ = try ts.parallel.parallelBatchDTW(
        allocator,
        pool,
        query,
        cands,
        results,
        .{ .variant = .constrained, .band = @intCast(len / 4) },
        .{ .chunk_size = chunk_size },
    );
    return monoNs() - t0;
}

fn runParallelBenchSuite() !void {
    writeStdout("\n== Parallel DTW batch: N=500 series, len=128 ==\n", .{});
    const N: usize = 500;
    const len: usize = 128;

    const query = generateSine(len);
    defer allocator.free(query);

    const cand_bufs = try allocator.alloc([]f64, N);
    defer {
        for (cand_bufs) |b| allocator.free(b);
        allocator.free(cand_bufs);
    }
    const cands = try allocator.alloc([]const f64, N);
    defer allocator.free(cands);
    for (0..N) |k| {
        cand_bufs[k] = try allocator.alloc(f64, len);
        for (cand_bufs[k], 0..) |*v, i|
            v.* = @sin(@as(f64, @floatFromInt(i)) * 0.1 + @as(f64, @floatFromInt(k)) * 0.01);
        cands[k] = cand_bufs[k];
    }

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 8 });
    defer {
        pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        pool.deinit();
    }

    _ = try benchBatchDTWSerial(N, len, query, cands); // warmup
    const serial_ns = try benchBatchDTWSerial(N, len, query, cands);
    writeStdout("  serial:              {d:>10} ns  ({d:.2} series/ms)\n", .{
        serial_ns, @as(f64, @floatFromInt(N)) / (@as(f64, @floatFromInt(serial_ns)) / 1e6),
    });

    for ([_]usize{ 4, 8, 16, 32, 64 }) |cs| {
        const ns = try benchBatchDTWParallel(N, len, query, cands, &pool, cs);
        writeStdout("  parallel chunk={d:>3}:   {d:>10} ns  ({d:.2} series/ms)\n", .{
            cs, ns, @as(f64, @floatFromInt(N)) / (@as(f64, @floatFromInt(ns)) / 1e6),
        });
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    writeStdout("\n=== timeseries benchmarks ===\n\n", .{});

    runBench("BenchmarkDTW100", DTW100.run, 500);
    runBench("BenchmarkDTW500", DTW500.run, 100);
    runBench("BenchmarkDTW1000", DTW1000.run, 20);
    runBench("BenchmarkCrossCorrelate", CrossCorr.run, 100);
    runBench("BenchmarkPELT", PELTBench.run, 200);
    runBench("BenchmarkExtractFeatures", FeatureBench.run, 500);
    runBench("BenchmarkInvariantCompute", InvariantBench.run, 1000);
    runBench("BenchmarkZNormalize", ZNormBench.run, 1000);
    runBench("BenchmarkERP", ERPBench.run, 100);

    try runParallelBenchSuite();

    writeStdout("\n=== done ===\n\n", .{});
}
