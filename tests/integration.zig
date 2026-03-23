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
    try std.testing.expect(lib.abi.ts_version() == 2);
}

test "integration: chunk storage write -> queryRange round-trip" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_integ_rt_{d}", .{pid}) catch unreachable;
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

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_integ_ret_{d}", .{pid}) catch unreachable;
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

test "integration: store aggregation e2e" {
    const ally = std.testing.allocator;

    var st = lib.Store.init(ally);
    defer st.deinit();

    const key_a = lib.SeriesKey{ .device_id = 1, .metric = "cpu" };
    const key_b = lib.SeriesKey{ .device_id = 2, .metric = "mem" };

    // Insert 50 points into each of 2 series (100 total).
    var i: i64 = 0;
    while (i < 50) : (i += 1) {
        try st.insertMany(key_a, &.{.{ .ts = i * 1000, .value = 10 + @rem(i, 5) }});
        try st.insertMany(key_b, &.{.{ .ts = i * 1000, .value = 100 + i }});
    }

    // Verify both series have 50 points.
    const hk_a = st.hashKey(key_a);
    const series_a = st.by_key.get(hk_a).?;
    try std.testing.expect(series_a.len() == 50);

    const hk_b = st.hashKey(key_b);
    const series_b = st.by_key.get(hk_b).?;
    try std.testing.expect(series_b.len() == 50);

    // sampleBy with avg on series A: bucket by 10s (10000ms), range [0, 50000).
    const avg_rows = try st.sampleBy(key_a, 10000, 0, 50000, .avg, ally);
    defer ally.free(avg_rows);

    // 5 buckets: [0..10s), [10..20s), [20..30s), [30..40s), [40..50s)
    try std.testing.expect(avg_rows.len == 5);

    // Each bucket has 10 points. Verify all buckets have non-null values.
    for (avg_rows) |row| {
        try std.testing.expect(row.value != null);
    }

    // Verify first bucket avg: points 0..9 have values 10,11,12,13,14,10,11,12,13,14 -> avg=12
    try std.testing.expect(avg_rows[0].value.? == 12);
}

test "integration: full pipeline insert -> preprocess -> extractFeatures" {
    const ally = std.testing.allocator;

    // Step 1: Create raw data (a ramp signal with some noise).
    var raw_values: [20]f64 = undefined;
    for (0..20) |i| {
        const fi: f64 = @floatFromInt(i);
        raw_values[i] = fi * 2.0 + 1.0; // linear ramp: 1, 3, 5, 7, ...
    }

    // Step 2: Preprocess with zNormalizeAlloc (non-mutating).
    const normalized = try lib.preprocess.zNormalizeAlloc(ally, &raw_values);
    defer ally.free(normalized);

    // Verify original is unchanged.
    try std.testing.expectApproxEqAbs(raw_values[0], 1.0, 1e-10);
    try std.testing.expectApproxEqAbs(raw_values[19], 39.0, 1e-10);

    // Verify normalized has mean ~0.
    var sum: f64 = 0;
    for (normalized) |v| sum += v;
    try std.testing.expectApproxEqAbs(sum / 20.0, 0.0, 1e-10);

    // Step 3: Extract features from the normalized series.
    var feats: [22]f64 = undefined;
    const rc = lib.features.extractFeatures(ally, normalized.ptr, 20, &feats);
    try std.testing.expect(rc == 0);

    // Step 4: Verify feature vector properties.
    // feats[0] = length = 20
    try std.testing.expectApproxEqAbs(feats[0], 20.0, 1e-10);

    // feats[1] = mean ~ 0 (z-normalized)
    try std.testing.expectApproxEqAbs(feats[1], 0.0, 1e-6);

    // feats[2] = stddev ~ 1 (z-normalized)
    try std.testing.expectApproxEqAbs(feats[2], 1.0, 0.05);

    // feats[5] = range = max - min; should be positive
    try std.testing.expect(feats[5] > 0);

    // feats[11] = slope; for a linear ramp, slope should be positive
    try std.testing.expect(feats[11] > 0);

    // Histogram bins [12..22] should sum to ~1.0 (normalized histogram).
    var hist_sum: f64 = 0;
    for (12..22) |j| hist_sum += feats[j];
    try std.testing.expectApproxEqAbs(hist_sum, 1.0, 0.05);
}
