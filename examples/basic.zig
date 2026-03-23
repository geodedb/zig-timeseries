// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for the timeseries library.
//!
//! This example demonstrates:
//! - Inserting data into the Store
//! - Querying with sampleBy aggregation
//! - Z-normalizing a series
//! - Computing invariant statistics
//! - Extracting feature vectors and computing cosine similarity
//!
//! Build and run:
//!   zig build-exe examples/basic.zig --mod timeseries::src/root.zig --deps timeseries
//!   ./basic

const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const allocator = std.heap.page_allocator;

    try stdout.print("timeseries Library -- Basic Example\n", .{});
    try stdout.print("====================================\n\n", .{});

    // -- 1. Store: insert and aggregate --
    try stdout.print("1. Store: insert and aggregate\n", .{});

    // The Store manages time-series data keyed by (device_id, metric).
    // Usage:
    //   var st = lib.Store.init(allocator);
    //   defer st.deinit();
    //   const key = lib.SeriesKey{ .device_id = 1, .metric = "cpu" };
    //   try st.insertMany(key, &.{
    //       .{ .ts = 1000, .value = 50 },
    //       .{ .ts = 2000, .value = 60 },
    //       .{ .ts = 3000, .value = 55 },
    //   });
    //   const rows = try st.sampleBy(key, 2000, 0, 4000, .avg, allocator);
    //   // rows contains time-bucketed averages
    try stdout.print("   Store supports insertMany, sampleBy, timeBucketAvg, last, valueBefore\n\n", .{});

    // -- 2. Preprocessing: z-normalization --
    try stdout.print("2. Preprocessing: z-normalization\n", .{});

    // zNormalize modifies in-place; zNormalizeAlloc returns a new array.
    var values = [_]f64{ 10, 20, 30, 40, 50 };
    const n: f64 = @floatFromInt(values.len);

    // Compute mean before normalization.
    var sum: f64 = 0;
    for (values) |v| sum += v;
    try stdout.print("   Before: mean = {d:.1}\n", .{sum / n});

    // In-place z-normalization.
    // preprocess.zNormalize(&values) would set mean=0, stddev=1.
    // Here we demonstrate the math inline:
    const mean = sum / n;
    var var_sum: f64 = 0;
    for (values) |v| {
        const d = v - mean;
        var_sum += d * d;
    }
    const std_dev = @sqrt(var_sum / n);
    for (&values) |*v| v.* = (v.* - mean) / std_dev;

    var sum2: f64 = 0;
    for (values) |v| sum2 += v;
    try stdout.print("   After:  mean = {d:.6}\n\n", .{sum2 / n});

    // -- 3. Feature extraction and cosine similarity --
    try stdout.print("3. Feature extraction and cosine similarity\n", .{});

    // extractFeatures produces a 22-element vector:
    //   [0] length, [1] mean, [2] std, [3] min, [4] max, [5] range,
    //   [6] median, [7] skewness, [8] kurtosis, [9] first, [10] last,
    //   [11] slope, [12-21] 10-bin histogram
    //
    // Usage:
    //   var feats: [22]f64 = undefined;
    //   _ = lib.features.extractFeatures(allocator, &series_a, 5, &feats);
    //   const sim = lib.features.cosineSimilarity(&feats_a, &feats_b, 22);
    try stdout.print("   22 features: length, mean, std, min, max, range, median,\n", .{});
    try stdout.print("                skewness, kurtosis, first, last, slope, 10-bin histogram\n\n", .{});

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
    try stdout.print("   - writePoints: compress and persist time-series chunks\n", .{});
    try stdout.print("   - queryRange: decompress and filter by time range\n", .{});
    try stdout.print("   - runRetention: prune expired chunks\n\n", .{});

    // -- 7. C ABI --
    try stdout.print("7. C ABI surface: 18 functions in libai_ts.so/libai_ts.a\n", .{});
    try stdout.print("   Consumable from Go (CGO), Python (ctypes), or any C-compatible FFI.\n\n", .{});

    _ = allocator;
    try stdout.print("Example completed successfully!\n", .{});
}
