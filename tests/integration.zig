// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integration tests for timeseries
//!
//! These tests verify end-to-end functionality and cross-module interactions.

const std = @import("std");
const lib = @import("timeseries");

// ============================================================================
// Integration Tests
// ============================================================================

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.1.0", lib.version);
}

test "integration: DTW -> feature extraction pipeline" {
    // Compute DTW between two series, then extract features from each.
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 1.5, 2.5, 3.5, 4.5, 5.5 };

    // DTW distance.
    var dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;
    const rc = lib.dtw.constrainedDTW(std.testing.allocator, &a, 5, &b, 5, 2, &dist, &pi, &pj, &plen);
    try std.testing.expect(rc == 0);
    try std.testing.expect(dist > 0);

    // Feature extraction.
    var feats_a: [22]f64 = undefined;
    var feats_b: [22]f64 = undefined;
    try std.testing.expect(lib.features.extractFeatures(std.testing.allocator, &a, 5, &feats_a) == 0);
    try std.testing.expect(lib.features.extractFeatures(std.testing.allocator, &b, 5, &feats_b) == 0);

    // Cosine similarity between feature vectors should be high.
    const sim = lib.features.cosineSimilarity(&feats_a, &feats_b, 22);
    try std.testing.expect(sim > 0.9);
}

test "integration: PELT segmentation -> DTW on segments" {
    // Create a series with two distinct segments.
    const values = [_]f64{ 1, 1, 1, 1, 1, 10, 10, 10, 10, 10 };
    var cps: [10]i32 = undefined;
    var cps_len: i32 = undefined;

    const rc = lib.pelt.pelt(std.testing.allocator, &values, 10, 5.0, 2, &cps, &cps_len);
    try std.testing.expect(rc == 0);
    try std.testing.expect(cps_len >= 1);
}

test "integration: cross-correlation -> SBD" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    // Cross-correlate with self.
    var lag: i32 = undefined;
    var corr: f64 = undefined;
    try std.testing.expect(lib.distances.crossCorrelate(&a, 5, &a, 5, &lag, &corr) == 0);
    try std.testing.expect(lag == 0);

    // SBD with self should be 0.
    var sbd_dist: f64 = undefined;
    try std.testing.expect(lib.distances.sbd(&a, 5, &a, 5, &sbd_dist) == 0);
    try std.testing.expectApproxEqAbs(sbd_dist, 0.0, 1e-10);
}

test "integration: LB_Keogh bounds DTW" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const lb = lib.dtw.lbKeogh(&a, 5, &b, 5, 1);

    var dtw_dist: f64 = undefined;
    var pi: [10]i32 = undefined;
    var pj: [10]i32 = undefined;
    var plen: i32 = undefined;
    _ = lib.dtw.constrainedDTW(std.testing.allocator, &a, 5, &b, 5, 1, &dtw_dist, &pi, &pj, &plen);

    try std.testing.expect(lb <= dtw_dist + 1e-10);
}

test "integration: invariants computation" {
    const times = [_]f64{ 0, 1, 2, 3, 4 };
    const values = [_]f64{ 1, 2, 3, 4, 5 };

    const inv = lib.invariants.computeInvariants(&times, &values);
    try std.testing.expectApproxEqAbs(inv.duration, 4.0, 1e-10);
    try std.testing.expectApproxEqAbs(inv.mean, 3.0, 1e-10);

    // Histogram should sum to 1.
    var sum: f64 = 0;
    for (inv.histogram) |h| sum += h;
    try std.testing.expectApproxEqAbs(sum, 1.0, 1e-10);
}

test "integration: preprocessing z-normalize" {
    var values = [_]f64{ 1, 2, 3, 4, 5 };
    lib.preprocess.zNormalize(&values);

    var sum: f64 = 0;
    for (values) |v| sum += v;
    try std.testing.expectApproxEqAbs(sum / 5.0, 0.0, 1e-10);
}

test "integration: ABI version" {
    try std.testing.expect(lib.abi.ts_version() == 1);
}

test "integration: chunk storage write -> queryRange round-trip" {
    const ally = std.testing.allocator;

    const test_dir = "/tmp/ts_integ_roundtrip";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try lib.ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // Write 50 points with known values.
    var points: std.ArrayList(lib.Point) = .{};
    defer points.deinit(ally);

    var i: i64 = 0;
    while (i < 50) : (i += 1) {
        try points.append(ally, .{
            .ts = 1000 + i * 1000,
            .value = i * 10,
        });
    }

    try storage.writePoints(1, points.items);

    // Query back the full range.
    const result = try storage.queryRange(1, 1000, 50000, ally);
    defer ally.free(result);

    try std.testing.expect(result.len == 50);
    for (0..50) |j| {
        try std.testing.expect(result[j].ts == points.items[j].ts);
        try std.testing.expect(result[j].value == points.items[j].value);
    }
}

test "integration: chunk storage write -> queryRange -> retention" {
    const ally = std.testing.allocator;

    const test_dir = "/tmp/ts_integ_retention";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try lib.ChunkStorage.init(ally, test_dir, .{ .retention_days = 1 });
    defer storage.deinit();

    const current_time: i64 = 1_000_000_000;
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Write old chunk (2 days ago).
    try storage.writePoints(1, &[_]lib.Point{
        .{ .ts = current_time - 2 * day_ms, .value = 10 },
        .{ .ts = current_time - 2 * day_ms + 1000, .value = 20 },
    });

    // Write recent chunk.
    try storage.writePoints(1, &[_]lib.Point{
        .{ .ts = current_time - 1000, .value = 100 },
        .{ .ts = current_time, .value = 200 },
    });

    // Before retention: both chunks visible.
    try std.testing.expect(storage.chunks.items.len == 2);

    // Run retention.
    try storage.runRetention(current_time);

    // After retention: only recent chunk.
    try std.testing.expect(storage.chunks.items.len == 1);

    // Query remaining data.
    const result = try storage.queryRange(1, current_time - 2000, current_time + 1, ally);
    defer ally.free(result);

    try std.testing.expect(result.len == 2);
    try std.testing.expect(result[0].value == 100);
    try std.testing.expect(result[1].value == 200);
}
