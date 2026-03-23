// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Core time-series store: Point, Series, and Store with aggregation.
//! Ported from Geode's timeseries.zig with Zig 0.15 API fixes.

const std = @import("std");

/// Time-series data point.
pub const Point = struct {
    ts: i64, // Unix timestamp in milliseconds
    value: i64,
};

/// Floating-point time-series point for advanced analytics.
pub const PointF64 = struct { ts: i64, value: f64 };

/// Series identifier key.
pub const SeriesKey = struct { device_id: i64, metric: []const u8 };

/// Time-series data structure.
pub const Series = struct {
    key: SeriesKey,
    points: std.ArrayList(Point) = .{},

    /// Returns the number of points in the series.
    pub fn len(self: *const Series) usize {
        return self.points.items.len;
    }

    /// Returns true if the series has no points.
    pub fn empty(self: *const Series) bool {
        return self.points.items.len == 0;
    }

    /// Returns a sub-slice of points [start..end].
    pub fn slice(self: *const Series, start: usize, end: usize) []const Point {
        const items = self.points.items;
        const s = @min(start, items.len);
        const e = @min(end, items.len);
        return items[s..e];
    }

    /// Get the last value in the series.
    pub fn lastValue(self: *const Series) ?Point {
        if (self.points.items.len == 0) return null;
        return self.points.items[self.points.items.len - 1];
    }

    /// Get value at specific timestamp (exact or closest before).
    pub fn valueAt(self: *const Series, ts: i64) ?Point {
        const items = self.points.items;
        if (items.len == 0) return null;

        var left: usize = 0;
        var right: usize = items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[mid].ts == ts) {
                return items[mid];
            } else if (items[mid].ts < ts) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (left > 0) return items[left - 1];
        return null;
    }
};

/// Aggregation type for sampleBy queries.
pub const Aggregation = enum { avg, sum, min, max, count, first, last };

/// Output row from sampleBy.
pub const SampleRow = struct { ts: i64, value: ?i64 };

/// Output row from timeBucketAvg.
pub const BucketAvgRow = struct { ts: i64, avg: ?i64 };

/// Main time-series store.
pub const Store = struct {
    allocator: std.mem.Allocator,
    by_key: std.AutoHashMap(u128, *Series),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .by_key = std.AutoHashMap(u128, *Series).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            s.points.deinit(self.allocator);
            self.allocator.free(s.key.metric);
            self.allocator.destroy(s);
        }
        self.by_key.deinit();
    }

    pub fn hashKey(_: *Store, k: SeriesKey) u128 {
        var h1 = std.hash.Wyhash.init(0);
        h1.update(std.mem.asBytes(&k.device_id));
        h1.update(k.metric);
        const x1 = h1.final();
        var h2 = std.hash.Wyhash.init(0x517cc1b727220a95);
        h2.update(std.mem.asBytes(&k.device_id));
        h2.update(k.metric);
        const x2 = h2.final();
        return (@as(u128, x1) << 64) | @as(u128, x2);
    }

    pub fn getSeries(self: *Store, key: SeriesKey) ?*Series {
        const hk = self.hashKey(key);
        return self.by_key.get(hk);
    }

    fn getOrCreateSeries(self: *Store, key: SeriesKey) !*Series {
        const hk = self.hashKey(key);
        if (self.by_key.get(hk)) |sp| return sp;
        const s = try self.allocator.create(Series);
        s.* = .{
            .key = .{
                .device_id = key.device_id,
                .metric = try self.allocator.dupe(u8, key.metric),
            },
            .points = .{},
        };
        try self.by_key.put(hk, s);
        return s;
    }

    /// Batch-insert points into a series, maintaining sorted order.
    /// Optimized: if the batch is already sorted and all timestamps are >=
    /// the last existing timestamp, avoids re-sorting the entire array.
    pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void {
        const s = try self.getOrCreateSeries(key);
        if (pts.len == 0) return;

        const cmpFn = struct {
            fn less(_: void, a: Point, b: Point) bool {
                return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
            }
        }.less;

        // Check if the incoming batch can be fast-path appended:
        // 1. The batch must be sorted.
        // 2. The first element of the batch must be >= the last existing element.
        const existing_len = s.points.items.len;
        var batch_sorted = true;
        for (1..pts.len) |i| {
            if (cmpFn({}, pts[i], pts[i - 1])) {
                batch_sorted = false;
                break;
            }
        }

        const can_append = batch_sorted and (existing_len == 0 or
            !cmpFn({}, pts[0], s.points.items[existing_len - 1]));

        try s.points.appendSlice(self.allocator, pts);

        if (!can_append) {
            // Fallback: full sort when batch is unordered or overlaps existing data.
            std.sort.pdq(Point, s.points.items, {}, cmpFn);
        }
    }

    /// Get the last point in a series.
    pub fn last(self: *Store, key: SeriesKey) ?Point {
        const hk = self.hashKey(key);
        if (self.by_key.get(hk)) |sp| {
            const s = sp;
            if (s.points.items.len == 0) return null;
            return s.points.items[s.points.items.len - 1];
        }
        return null;
    }

    /// Get the last point at or before the given timestamp.
    pub fn valueBefore(self: *Store, key: SeriesKey, ts: i64) ?Point {
        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return null;
        const arr = sp.points.items;
        if (arr.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = arr.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (arr[mid].ts <= ts) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        return arr[lo - 1];
    }

    pub const Bucket = struct { start_ts: i64, end_ts: i64, count: i64, sum: i128 };

    /// Sample time-series by interval with aggregation.
    pub fn sampleBy(
        self: *Store,
        key: SeriesKey,
        interval_ms: i64,
        start_ts: i64,
        end_ts: i64,
        aggregation: Aggregation,
        allocator: std.mem.Allocator,
    ) ![]const SampleRow {
        if (interval_ms <= 0 or end_ts <= start_ts) return &.{};

        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return &.{};
        const n_buckets: usize = @intCast(@divTrunc((end_ts - start_ts) + interval_ms - 1, interval_ms));

        var buckets = try allocator.alloc(struct {
            start_ts: i64,
            end_ts: i64,
            cnt: i64,
            sum_val: i128,
            min_val: ?i64,
            max_val: ?i64,
            first_pt: ?Point,
            last_pt: ?Point,
        }, n_buckets);
        defer allocator.free(buckets);

        for (0..n_buckets) |i| {
            const s_ts = start_ts + @as(i64, @intCast(i)) * interval_ms;
            buckets[i] = .{
                .start_ts = s_ts,
                .end_ts = s_ts + interval_ms,
                .cnt = 0,
                .sum_val = 0,
                .min_val = null,
                .max_val = null,
                .first_pt = null,
                .last_pt = null,
            };
        }

        for (sp.points.items) |p| {
            if (p.ts < start_ts or p.ts >= end_ts) continue;
            const idx_i64 = @divTrunc(p.ts - start_ts, interval_ms);
            if (idx_i64 < 0) continue;
            const idx: usize = @intCast(idx_i64);
            if (idx >= n_buckets) continue;

            buckets[idx].cnt += 1;
            buckets[idx].sum_val += @as(i128, p.value);

            if (buckets[idx].min_val == null or p.value < buckets[idx].min_val.?) {
                buckets[idx].min_val = p.value;
            }
            if (buckets[idx].max_val == null or p.value > buckets[idx].max_val.?) {
                buckets[idx].max_val = p.value;
            }
            if (buckets[idx].first_pt == null) {
                buckets[idx].first_pt = p;
            }
            buckets[idx].last_pt = p;
        }

        var out = try allocator.alloc(SampleRow, n_buckets);
        for (0..n_buckets) |i| {
            const b = buckets[i];
            const value: ?i64 = switch (aggregation) {
                .avg => if (b.cnt == 0) null else @intCast(@divTrunc(b.sum_val, @as(i128, b.cnt))),
                .sum => if (b.cnt == 0) null else @intCast(b.sum_val),
                .min => b.min_val,
                .max => b.max_val,
                .count => b.cnt,
                .first => if (b.first_pt) |f| f.value else null,
                .last => if (b.last_pt) |l| l.value else null,
            };
            out[i] = .{ .ts = b.start_ts, .value = value };
        }

        return out;
    }

    /// Time-bucket averaging.
    pub fn timeBucketAvg(
        self: *Store,
        key: SeriesKey,
        bucket_seconds: i64,
        t0: i64,
        t1: i64,
        allocator: std.mem.Allocator,
    ) ![]const BucketAvgRow {
        if (bucket_seconds <= 0 or t1 <= t0) return &.{};
        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return &.{};
        const n_buckets: usize = @intCast(@divTrunc((t1 - t0) + bucket_seconds - 1, bucket_seconds));
        var buckets = try allocator.alloc(Bucket, n_buckets);
        defer allocator.free(buckets);

        for (0..n_buckets) |i| {
            const s_ts = t0 + @as(i64, @intCast(i)) * bucket_seconds;
            buckets[i] = .{ .start_ts = s_ts, .end_ts = s_ts + bucket_seconds, .count = 0, .sum = 0 };
        }
        for (sp.points.items) |p| {
            if (p.ts < t0 or p.ts >= t1) continue;
            const idx_i64 = @divTrunc(p.ts - t0, bucket_seconds);
            if (idx_i64 < 0) continue;
            const idx: usize = @intCast(idx_i64);
            if (idx >= n_buckets) continue;
            buckets[idx].count += 1;
            buckets[idx].sum += @as(i128, p.value);
        }
        var out = try allocator.alloc(BucketAvgRow, n_buckets);
        for (0..n_buckets) |i| {
            const b = buckets[i];
            if (b.count == 0) {
                out[i] = .{ .ts = b.start_ts, .avg = null };
            } else {
                const q = @divTrunc(b.sum, @as(i128, b.count));
                const v: i64 = @intCast(q);
                out[i] = .{ .ts = b.start_ts, .avg = v };
            }
        }
        return out;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "store: insert/order/last/asof" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 100, .value = 10 }, .{ .ts = 90, .value = 9 }, .{ .ts = 110, .value = 11 } });
    const l = st.last(key).?;
    try std.testing.expect(l.ts == 110 and l.value == 11);
    const p = st.valueBefore(key, 105).?;
    try std.testing.expect(p.ts == 100 and p.value == 10);
}

test "store: timeBucketAvg basic" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 0, .value = 10 }, .{ .ts = 5, .value = 20 }, .{ .ts = 10, .value = 30 } });
    const out = try st.timeBucketAvg(key, 10, 0, 20, allocator);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
    try std.testing.expect(out[0].ts == 0 and out[0].avg.? == 15);
    try std.testing.expect(out[1].ts == 10 and out[1].avg.? == 30);
}

test "store: sampleBy aggregations" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "cpu" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const avg_result = try st.sampleBy(key, 10000, 0, 20000, .avg, allocator);
    defer allocator.free(avg_result);
    try std.testing.expect(avg_result.len == 2);
    try std.testing.expect(avg_result[0].value.? == 20);
    try std.testing.expect(avg_result[1].value.? == 45);

    const min_result = try st.sampleBy(key, 10000, 0, 20000, .min, allocator);
    defer allocator.free(min_result);
    try std.testing.expect(min_result[0].value.? == 10);
    try std.testing.expect(min_result[1].value.? == 40);

    const max_result = try st.sampleBy(key, 10000, 0, 20000, .max, allocator);
    defer allocator.free(max_result);
    try std.testing.expect(max_result[0].value.? == 30);
    try std.testing.expect(max_result[1].value.? == 50);

    const count_result = try st.sampleBy(key, 10000, 0, 20000, .count, allocator);
    defer allocator.free(count_result);
    try std.testing.expect(count_result[0].value.? == 3);
    try std.testing.expect(count_result[1].value.? == 2);
}

test "store: valueAt and lastValue" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "memory" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
        .{ .ts = 3000, .value = 300 },
    });

    const l = st.last(key).?;
    try std.testing.expect(l.ts == 3000 and l.value == 300);

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    const exact = series.valueAt(2000).?;
    try std.testing.expect(exact.ts == 2000 and exact.value == 200);

    const closest = series.valueAt(2500).?;
    try std.testing.expect(closest.ts == 2000 and closest.value == 200);
}

test "store: hashKey uses independent seeds for full 128-bit entropy" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 42, .metric = "test" };
    const h = st.hashKey(key);

    // Upper and lower 64 bits should NOT be derivable from each other via XOR
    // with a constant (the old bug). Verify they are genuinely independent.
    const upper: u64 = @intCast(h >> 64);
    const lower: u64 = @intCast(h & 0xFFFFFFFFFFFFFFFF);

    // With two independent seeds, upper XOR lower should NOT equal the
    // golden ratio constant 0x9e3779b97f4a7c15 (the old derivation).
    try std.testing.expect((upper ^ lower) != 0x9e3779b97f4a7c15);

    // Verify that different keys produce different hashes.
    const key2 = SeriesKey{ .device_id = 42, .metric = "test2" };
    const h2 = st.hashKey(key2);
    try std.testing.expect(h != h2);

    // Verify same key produces same hash (deterministic).
    const h_again = st.hashKey(key);
    try std.testing.expect(h == h_again);
}
