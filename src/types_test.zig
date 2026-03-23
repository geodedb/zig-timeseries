// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Tests for core types defined in types.zig and store.zig.
//! Covers Gap.contains, Series.len/empty/slice, and MatchDecision enum values.

const std = @import("std");
const types = @import("types.zig");
const store = @import("store.zig");
const expect = std.testing.expect;

// ============================================================================
// Gap.contains tests
// ============================================================================

test "Gap.contains: start is inclusive" {
    const gap = types.Gap{ .start = 5, .end = 10 };
    try expect(gap.contains(5) == true);
}

test "Gap.contains: end minus one is inclusive" {
    const gap = types.Gap{ .start = 5, .end = 10 };
    try expect(gap.contains(9) == true);
}

test "Gap.contains: end is exclusive" {
    const gap = types.Gap{ .start = 5, .end = 10 };
    try expect(gap.contains(10) == false);
}

test "Gap.contains: before start is excluded" {
    const gap = types.Gap{ .start = 5, .end = 10 };
    try expect(gap.contains(4) == false);
}

test "Gap.contains: middle value is included" {
    const gap = types.Gap{ .start = 5, .end = 10 };
    try expect(gap.contains(7) == true);
}

test "Gap.contains: zero-length gap contains nothing" {
    const gap = types.Gap{ .start = 5, .end = 5 };
    try expect(gap.contains(5) == false);
    try expect(gap.contains(4) == false);
}

// ============================================================================
// Series.len tests
// ============================================================================

test "Series.len: returns correct count after insert" {
    const allocator = std.testing.allocator;
    var st = store.Store.init(allocator);
    defer st.deinit();

    const key = store.SeriesKey{ .device_id = 1, .metric = "len_test" };
    try st.insertMany(key, &.{
        .{ .ts = 1, .value = 10 },
        .{ .ts = 2, .value = 20 },
        .{ .ts = 3, .value = 30 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    try expect(series.len() == 3);
}

// ============================================================================
// Series.empty tests
// ============================================================================

test "Series.empty: true for new series" {
    const allocator = std.testing.allocator;
    var st = store.Store.init(allocator);
    defer st.deinit();

    const key = store.SeriesKey{ .device_id = 1, .metric = "empty_test" };
    // Insert zero points to create the series.
    try st.insertMany(key, &.{});

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    try expect(series.empty() == true);
}

test "Series.empty: false after insert" {
    const allocator = std.testing.allocator;
    var st = store.Store.init(allocator);
    defer st.deinit();

    const key = store.SeriesKey{ .device_id = 1, .metric = "nonempty_test" };
    try st.insertMany(key, &.{
        .{ .ts = 1, .value = 42 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    try expect(series.empty() == false);
}

// ============================================================================
// Series.slice tests
// ============================================================================

test "Series.slice: returns correct sub-range" {
    const allocator = std.testing.allocator;
    var st = store.Store.init(allocator);
    defer st.deinit();

    const key = store.SeriesKey{ .device_id = 1, .metric = "slice_test" };
    try st.insertMany(key, &.{
        .{ .ts = 10, .value = 1 },
        .{ .ts = 20, .value = 2 },
        .{ .ts = 30, .value = 3 },
        .{ .ts = 40, .value = 4 },
        .{ .ts = 50, .value = 5 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    const sl = series.slice(1, 4);

    try expect(sl.len == 3);
    try expect(sl[0].ts == 20 and sl[0].value == 2);
    try expect(sl[1].ts == 30 and sl[1].value == 3);
    try expect(sl[2].ts == 40 and sl[2].value == 4);
}

test "Series.slice: handles out-of-bounds gracefully" {
    const allocator = std.testing.allocator;
    var st = store.Store.init(allocator);
    defer st.deinit();

    const key = store.SeriesKey{ .device_id = 1, .metric = "slice_oob" };
    try st.insertMany(key, &.{
        .{ .ts = 10, .value = 1 },
        .{ .ts = 20, .value = 2 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;

    // end > items.len should be clamped.
    const sl = series.slice(0, 100);
    try expect(sl.len == 2);

    // start > items.len should return empty.
    const sl2 = series.slice(100, 200);
    try expect(sl2.len == 0);

    // start == end should return empty.
    const sl3 = series.slice(1, 1);
    try expect(sl3.len == 0);
}

// ============================================================================
// MatchDecision enum tests
// ============================================================================

test "MatchDecision: enum values match expected integers" {
    try expect(@intFromEnum(types.MatchDecision.match_yes) == 0);
    try expect(@intFromEnum(types.MatchDecision.review) == 1);
    try expect(@intFromEnum(types.MatchDecision.reject) == 2);
}
