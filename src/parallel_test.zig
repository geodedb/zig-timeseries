// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Tests for parallel batch entry points. Each test constructs a small
//! `ThreadPool`, drives a batch call, and verifies results against
//! per-pair serial calls.

const std = @import("std");

const tp = @import("thread_pool");
const ts = @import("root.zig");
const parallel = ts.parallel;

test "parallelBatchDTW constrained: serial path matches per-pair serial calls" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const query = [_]f64{ 1, 2, 3, 4, 5, 4, 3, 2, 1 };
    var cand_bufs: [4][9]f64 = .{
        .{ 1, 2, 3, 4, 5, 4, 3, 2, 1 },
        .{ 0, 1, 2, 3, 4, 3, 2, 1, 0 },
        .{ 2, 3, 4, 5, 6, 5, 4, 3, 2 },
        .{ 5, 4, 3, 2, 1, 2, 3, 4, 5 },
    };
    var candidates: [4][]const f64 = undefined;
    for (&cand_bufs, 0..) |*b, i| candidates[i] = b[0..];

    var results: [4]parallel.BatchResult(ts.DtwResult) = undefined;
    const ok = try parallel.parallelBatchDTW(
        allocator,
        null, // serial path
        &query,
        candidates[0..],
        &results,
        .{ .variant = .constrained, .band = 0 },
        .{},
    );
    defer for (&results) |*r| switch (r.*) {
        .ok => |*dr| dr.deinit(allocator),
        .err => {},
    };
    try std.testing.expectEqual(@as(usize, 4), ok);

    // Compare against serial per-pair call.
    for (candidates, 0..) |c, idx| {
        var expected = try ts.dtw.constrainedDTW(allocator, &query, c, 0);
        defer expected.deinit(allocator);
        try std.testing.expectApproxEqAbs(expected.distance, results[idx].ok.distance, 1e-9);
    }
}

test "parallelBatchDTW parallel path: 256 candidates match serial results" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 4 });
    defer {
        _ = pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        pool.deinit();
    }

    const N = 256;
    const query = try allocator.alloc(f64, 32);
    defer allocator.free(query);
    for (query, 0..) |*v, i| v.* = @sin(@as(f64, @floatFromInt(i)) * 0.1);

    const cand_bufs = try allocator.alloc([]f64, N);
    defer {
        for (cand_bufs) |b| allocator.free(b);
        allocator.free(cand_bufs);
    }
    const candidates = try allocator.alloc([]const f64, N);
    defer allocator.free(candidates);
    for (0..N) |k| {
        cand_bufs[k] = try allocator.alloc(f64, 32);
        for (cand_bufs[k], 0..) |*v, i|
            v.* = @sin((@as(f64, @floatFromInt(i)) + @as(f64, @floatFromInt(k)) * 0.05) * 0.1);
        candidates[k] = cand_bufs[k];
    }

    const results = try allocator.alloc(parallel.BatchResult(ts.DtwResult), N);
    defer {
        for (results) |*r| switch (r.*) {
            .ok => |*dr| dr.deinit(allocator),
            .err => {},
        };
        allocator.free(results);
    }
    const ok = try parallel.parallelBatchDTW(
        allocator,
        &pool,
        query,
        candidates,
        results,
        .{ .variant = .constrained, .band = 4 },
        .{ .chunk_size = 8 },
    );
    try std.testing.expectEqual(N, ok);

    // Spot-check 3 candidates against serial.
    for ([_]usize{ 0, 100, 255 }) |idx| {
        var expected = try ts.dtw.constrainedDTW(allocator, query, candidates[idx], 4);
        defer expected.deinit(allocator);
        try std.testing.expectApproxEqAbs(expected.distance, results[idx].ok.distance, 1e-9);
    }
}

test "parallelBatchLbKeogh: matches per-pair serial" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer {
        _ = pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
        pool.deinit();
    }

    const query = [_]f64{ 1, 2, 3, 4, 5, 4, 3, 2, 1, 0 };
    var cand_bufs: [8][10]f64 = undefined;
    for (&cand_bufs, 0..) |*b, k| {
        for (b, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i)) + @as(f64, @floatFromInt(k)) * 0.25;
    }
    var candidates: [8][]const f64 = undefined;
    for (&cand_bufs, 0..) |*b, i| candidates[i] = b[0..];

    var out: [8]f64 = undefined;
    try parallel.parallelBatchLbKeogh(allocator, &pool, &query, candidates[0..], &out, 3, .{ .chunk_size = 2 });

    for (candidates, 0..) |c, idx| {
        const expected = ts.dtw.lbKeogh(&query, c, 3);
        try std.testing.expectApproxEqAbs(expected, out[idx], 1e-12);
    }
}
