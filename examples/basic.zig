// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for the timeseries library.
//!
//! This example demonstrates:
//! - Inserting data into the Store and aggregating with sampleBy
//! - Z-normalizing a series
//! - Extracting feature vectors and computing cosine similarity
//! - Writing/querying raw points through ChunkStorage (Gorilla compression)
//!
//! Build and run:
//!   zig build examples

const std = @import("std");
const ts = @import("timeseries");

/// Helper to obtain a global single-threaded I/O context, mirroring the
/// `gio()` helper used throughout the library (src/chunk_storage.zig).
inline fn gio() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn main() !void {
    const io = gio();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const allocator = std.heap.page_allocator;

    try stdout.print("timeseries Library -- Basic Example\n", .{});
    try stdout.print("====================================\n\n", .{});

    // -- 1. Store: insert and aggregate --
    try stdout.print("1. Store: insert and aggregate\n", .{});

    // The Store manages time-series data keyed by (device_id, metric).
    var st = ts.Store.init(allocator);
    defer st.deinit();

    const key = ts.SeriesKey{ .device_id = 1, .metric = "cpu" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 50 },
        .{ .ts = 2000, .value = 60 },
        .{ .ts = 3000, .value = 55 },
        .{ .ts = 4000, .value = 70 },
    });

    const rows = try st.sampleBy(key, 2000, 0, 5000, .avg, allocator);
    defer allocator.free(rows);
    for (rows) |row| {
        if (row.value) |v| {
            try stdout.print("   bucket start_ts={d} avg={d}\n", .{ row.ts, v });
        }
    }
    try stdout.print("\n", .{});

    // -- 2. Preprocessing: z-normalization --
    try stdout.print("2. Preprocessing: z-normalization\n", .{});

    var values = [_]f64{ 10, 20, 30, 40, 50 };
    const n: f64 = @floatFromInt(values.len);

    var sum: f64 = 0;
    for (values) |v| sum += v;
    try stdout.print("   Before: mean = {d:.1}\n", .{sum / n});

    const normalized = try ts.zNormalizeAlloc(allocator, &values);
    defer allocator.free(normalized);

    var sum2: f64 = 0;
    for (normalized) |v| sum2 += v;
    try stdout.print("   After:  mean = {d:.6}\n\n", .{sum2 / n});

    // -- 3. Feature extraction and cosine similarity --
    try stdout.print("3. Feature extraction and cosine similarity\n", .{});

    const feats_a = try ts.features.extractFeatures(allocator, &values);
    const feats_b = try ts.features.extractFeatures(allocator, normalized);
    const sim = ts.features.cosineSimilarity(&feats_a, &feats_b);
    try stdout.print("   22 features: length, mean, std, min, max, range, median,\n", .{});
    try stdout.print("                skewness, kurtosis, first, last, slope, 10-bin histogram\n", .{});
    try stdout.print("   cosine similarity(raw, normalized) = {d:.4}\n\n", .{sim});

    // -- 4. Distance algorithms --
    try stdout.print("4. Distance algorithms available:\n", .{});
    try stdout.print("   - Constrained DTW (Sakoe-Chiba band)\n", .{});
    try stdout.print("   - Derivative DTW (offset-invariant)\n", .{});
    try stdout.print("   - Open-End DTW (partial alignment)\n", .{});
    try stdout.print("   - Shape DTW (local shape descriptors)\n", .{});
    try stdout.print("   - Soft DTW (differentiable)\n", .{});
    try stdout.print("   - LB_Keogh (lower bound for pruning)\n", .{});
    try stdout.print("   - Cross-Correlation, SBD, LCSS, EDR, ERP, TWED\n", .{});
    try stdout.print("   - Matrix Profile, MPDist\n\n", .{});

    // -- 5. PELT segmentation --
    try stdout.print("5. PELT change-point detection\n", .{});
    try stdout.print("   Detects structural breaks in time-series data.\n", .{});
    try stdout.print("   Parameters: penalty (BIC-like), min_size (minimum segment length)\n\n", .{});

    // -- 6. Chunk storage with Gorilla compression --
    try stdout.print("6. Chunk storage with Gorilla compression\n", .{});

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&path_buf, "/tmp/ts_example_basic_{d}", .{pid});
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    var storage = try ts.ChunkStorage.init(allocator, data_dir, .{});
    defer storage.deinit();

    const series_id: u64 = 42;
    try storage.writePoints(series_id, &.{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 110 },
        .{ .ts = 3000, .value = 90 },
    });

    const queried = try storage.queryRange(series_id, 0, 5000, allocator);
    defer allocator.free(queried);
    try stdout.print("   writePoints: compressed and persisted {d} points\n", .{3});
    try stdout.print("   queryRange:  round-tripped {d} points -> [", .{queried.len});
    for (queried, 0..) |p, i| {
        if (i != 0) try stdout.print(", ", .{});
        try stdout.print("({d},{d})", .{ p.ts, p.value });
    }
    try stdout.print("]\n", .{});
    try stdout.print("   runRetention: prune expired chunks\n\n", .{});

    // -- 7. C ABI --
    try stdout.print("7. C ABI surface: 18 functions in libai_ts.so/libai_ts.a\n", .{});
    try stdout.print("   Consumable from Go (CGO), Python (ctypes), or any C-compatible FFI.\n\n", .{});

    try stdout.print("Example completed successfully!\n", .{});
}
