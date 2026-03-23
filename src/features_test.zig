// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const features = @import("features.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "extract features: basic 22-element vector" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };

    const feats = try features.extractFeatures(std.testing.allocator, &values);

    // Check known features.
    try expectApprox(feats[0], 5.0, 1e-10); // length
    try expectApprox(feats[1], 3.0, 1e-10); // mean
    try expect(feats[2] > 0); // std > 0
    try expectApprox(feats[3], 1.0, 1e-10); // min
    try expectApprox(feats[4], 5.0, 1e-10); // max
    try expectApprox(feats[5], 4.0, 1e-10); // range
    try expectApprox(feats[6], 3.0, 1e-10); // median
    try expectApprox(feats[9], 1.0, 1e-10); // first
    try expectApprox(feats[10], 5.0, 1e-10); // last
    try expect(feats[11] > 0); // positive slope
}

test "extract features: empty series -> error" {
    const empty: []const f64 = &.{};

    const result = features.extractFeatures(std.testing.allocator, empty);
    try expect(result == error.InvalidInput);
}

test "cosine similarity: identical vectors -> 1.0" {
    const a = [_]f64{ 1, 2, 3 };
    const sim = features.cosineSimilarity(&a, &a);
    try expectApprox(sim, 1.0, 1e-10);
}

test "cosine similarity: orthogonal vectors -> 0.0" {
    const a = [_]f64{ 1, 0, 0 };
    const b = [_]f64{ 0, 1, 0 };
    const sim = features.cosineSimilarity(&a, &b);
    try expectApprox(sim, 0.0, 1e-10);
}

test "cosine similarity: empty vectors -> 0.0" {
    const empty: []const f64 = &.{};
    const a = [_]f64{1};
    const sim = features.cosineSimilarity(empty, &a);
    try expectApprox(sim, 0.0, 1e-10);
}

test "extract features + cosine similarity: end-to-end" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };

    const feats_a = try features.extractFeatures(std.testing.allocator, &values);
    const feats_b = try features.extractFeatures(std.testing.allocator, &values);

    const sim = features.cosineSimilarity(&feats_a, &feats_b);
    try expectApprox(sim, 1.0, 1e-10);
}

test "extract features: handles 8193+ points" {
    const page_alloc = std.heap.page_allocator;
    const n: usize = 8193;
    const values = try page_alloc.alloc(f64, n);
    defer page_alloc.free(values);

    for (0..n) |i| values[i] = @as(f64, @floatFromInt(i + 1));

    const feats = try features.extractFeatures(std.testing.allocator, values);

    // Verify length feature.
    try expectApprox(feats[0], @as(f64, @floatFromInt(n)), 1e-10);

    // Verify mean = (n+1)/2.
    const expected_mean = @as(f64, @floatFromInt(n + 1)) / 2.0;
    try expectApprox(feats[1], expected_mean, 1e-6);

    // Verify min = 1, max = n.
    try expectApprox(feats[3], 1.0, 1e-10);
    try expectApprox(feats[4], @as(f64, @floatFromInt(n)), 1e-10);
}

// ============================================================================
// Security: Empty input guards (idiomatic Zig error unions)
// ============================================================================

test "extract features: both slices empty -> error" {
    const empty: []const f64 = &.{};
    const result = features.extractFeatures(std.testing.allocator, empty);
    try expect(result == error.InvalidInput);
}

test "cosine similarity: both empty -> 0" {
    const empty: []const f64 = &.{};
    const sim = features.cosineSimilarity(empty, empty);
    try expectApprox(sim, 0.0, 1e-10);
}

// ============================================================================
// Q14: FeatureIndex named indices
// ============================================================================

test "FeatureIndex: named indices match expected positions" {
    try expect(features.FeatureIndex.length == 0);
    try expect(features.FeatureIndex.mean == 1);
    try expect(features.FeatureIndex.std_dev == 2);
    try expect(features.FeatureIndex.min == 3);
    try expect(features.FeatureIndex.max == 4);
    try expect(features.FeatureIndex.range == 5);
    try expect(features.FeatureIndex.median == 6);
    try expect(features.FeatureIndex.skewness == 7);
    try expect(features.FeatureIndex.kurtosis == 8);
    try expect(features.FeatureIndex.first == 9);
    try expect(features.FeatureIndex.last == 10);
    try expect(features.FeatureIndex.slope == 11);
    try expect(features.FeatureIndex.hist_start == 12);
    try expect(features.FeatureIndex.hist_end == 22);
    try expect(features.FeatureIndex.feature_count == 22);
}

test "FeatureIndex: extractFeatures populates named positions correctly" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };

    const feats = try features.extractFeatures(std.testing.allocator, &values);

    // Verify via named indices.
    try expectApprox(feats[features.FeatureIndex.length], 5.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.mean], 3.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.min], 1.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.max], 5.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.range], 4.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.median], 3.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.first], 1.0, 1e-10);
    try expectApprox(feats[features.FeatureIndex.last], 5.0, 1e-10);
    try expect(feats[features.FeatureIndex.std_dev] > 0);
    try expect(feats[features.FeatureIndex.slope] > 0);

    // Histogram bins should sum to 1.0 (normalized).
    var hist_sum: f64 = 0;
    for (features.FeatureIndex.hist_start..features.FeatureIndex.hist_end) |i| {
        hist_sum += feats[i];
    }
    try expectApprox(hist_sum, 1.0, 1e-10);
}
