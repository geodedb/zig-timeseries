// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Benchmark suite for the timeseries library.
//!
//! Measures wall-clock time for core algorithms at representative input sizes.
//! Run with: `zig build bench`

const std = @import("std");
const ts = @import("timeseries");

const allocator = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Timing helper
// ---------------------------------------------------------------------------

/// Write a formatted string to stdout using direct syscall.
fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.write(std.posix.STDOUT_FILENO, msg) catch return;
}

/// Run a benchmark function `iterations` times, reporting min/mean/max ns/op.
fn runBench(
    comptime name: []const u8,
    comptime benchFn: fn () void,
    iterations: usize,
) void {
    var timer = std.time.Timer.start() catch return;

    // Warmup: 10% of iterations (minimum 1).
    const warmup = @max(1, iterations / 10);
    for (0..warmup) |_| {
        benchFn();
    }

    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    for (0..iterations) |_| {
        timer.reset();
        benchFn();
        const elapsed = timer.read();
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
            var dist: f64 = undefined;
            var pi: [n * 2]i32 = undefined;
            var pj: [n * 2]i32 = undefined;
            var plen: i32 = undefined;
            const rc = ts.dtw.constrainedDTW(
                allocator,
                a.ptr,
                @intCast(n),
                b.ptr,
                @intCast(n),
                @intCast(n / 5),
                &dist,
                &pi,
                &pj,
                &plen,
            );
            doNotOptimize(rc);
            doNotOptimize(dist);
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
        var lag: i32 = undefined;
        var corr: f64 = undefined;
        const rc = ts.distances.crossCorrelate(a.ptr, 500, b.ptr, 500, &lag, &corr);
        doNotOptimize(rc);
        doNotOptimize(corr);
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
        var cps: [500]i32 = undefined;
        var cps_len: i32 = undefined;
        const rc = ts.pelt.pelt(allocator, data.ptr, 500, 5.0, 2, &cps, &cps_len);
        doNotOptimize(rc);
        doNotOptimize(cps_len);
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
        var feats: [22]f64 = undefined;
        const rc = ts.features.extractFeatures(allocator, data.ptr, 500, &feats);
        doNotOptimize(rc);
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
        var dist: f64 = undefined;
        const rc = ts.distances.erp(allocator, a.ptr, 500, b.ptr, 500, 0.0, &dist);
        doNotOptimize(rc);
        doNotOptimize(dist);
    }
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() void {
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

    writeStdout("\n=== done ===\n\n", .{});
}
