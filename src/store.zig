// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Core time-series store: Point, Series, and Store with aggregation.
//! Ported from Geode's timeseries.zig with Zig 0.15 API fixes.

const std = @import("std");
const chunk_storage = @import("chunk_storage.zig");
const observability = @import("observability");

/// Restrictive file permissions for persisted data (POSIX 0o600; default elsewhere).
fn securePermissions() std.Io.File.Permissions {
    return if (@import("builtin").os.tag == .windows) .default_file else @enumFromInt(0o600);
}

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
    points: std.ArrayListUnmanaged(Point) = .empty,

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

/// Max length of a persisted metric name (corruption/DoS guard).
const MAX_METRIC_LEN: u32 = 4096;

/// Upper bound on the number of buckets sampleBy/timeBucketAvg will
/// allocate for a single query (overflow/DoS guard on caller-supplied
/// time ranges).
const MAX_BUCKETS: u64 = 1 << 26;

/// Configuration for optional disk persistence.
pub const StoreConfig = struct {
    data_dir: ?[]const u8 = null,
    chunk_config: chunk_storage.ChunkConfig = .{},
};

/// Main time-series store.
pub const Store = struct {
    allocator: std.mem.Allocator,
    by_key: std.AutoHashMap(u128, *Series),
    chunk_store: ?*chunk_storage.ChunkStorage = null,
    config: StoreConfig = .{},
    /// Tracks unflushed point counts per series for flush-threshold logic.
    unflushed: std.AutoHashMap(u128, usize),
    /// Maps the lower-64 chunk series_id back to the full u128 hash for loadFromDisk.
    chunk_id_to_hash: std.AutoHashMap(u64, u128),

    /// Initialize an in-memory-only store (backward compatible).
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .by_key = std.AutoHashMap(u128, *Series).init(allocator),
            .unflushed = std.AutoHashMap(u128, usize).init(allocator),
            .chunk_id_to_hash = std.AutoHashMap(u64, u128).init(allocator),
        };
    }

    /// Initialize a store with optional persistence via StoreConfig.
    pub fn initWithConfig(allocator: std.mem.Allocator, config: StoreConfig) !Store {
        var self = Store{
            .allocator = allocator,
            .by_key = std.AutoHashMap(u128, *Series).init(allocator),
            .config = config,
            .unflushed = std.AutoHashMap(u128, usize).init(allocator),
            .chunk_id_to_hash = std.AutoHashMap(u64, u128).init(allocator),
        };

        if (config.data_dir) |dir| {
            const ts_dir = try std.fmt.allocPrint(allocator, "{s}/timeseries", .{dir});
            defer allocator.free(ts_dir);

            const cs = try allocator.create(chunk_storage.ChunkStorage);
            errdefer allocator.destroy(cs);
            cs.* = try chunk_storage.ChunkStorage.init(allocator, ts_dir, config.chunk_config);
            self.chunk_store = cs;
        }

        return self;
    }

    pub fn deinit(self: *Store) void {
        // Flush any unflushed data before shutdown.
        self.sync() catch {};

        var it = self.by_key.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            s.points.deinit(self.allocator);
            self.allocator.free(s.key.metric);
            self.allocator.destroy(s);
        }
        self.by_key.deinit();
        self.unflushed.deinit();
        self.chunk_id_to_hash.deinit();

        if (self.chunk_store) |cs| {
            cs.deinit();
            self.allocator.destroy(cs);
            self.chunk_store = null;
        }
    }

    pub fn hashKey(_: *Store, k: SeriesKey) u128 {
        return hashKeyStatic(k);
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
            .points = .empty,
        };
        try self.by_key.put(hk, s);
        return s;
    }

    /// Batch-insert points into a series, maintaining sorted order.
    /// Optimized: if the batch is already sorted and all timestamps are >=
    /// the last existing timestamp, avoids re-sorting the entire array.
    /// When persistence is enabled, flushes to ChunkStorage when the
    /// unflushed count reaches the chunk_config.max_points_per_chunk threshold.
    pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void {
        var __obs_span = observability.startTimeseriesSpan("insert", key.metric);
        defer __obs_span.end(null);
        errdefer observability.endTimeseriesSpan(__obs_span, false, @intCast(pts.len));

        const s = try self.getOrCreateSeries(key);
        if (pts.len == 0) {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return;
        }

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

        // Persist: track unflushed count and flush when threshold is reached.
        if (self.chunk_store) |cs| {
            const hk = self.hashKey(key);
            const chunk_id = chunkSeriesId(hk);

            // Register the reverse mapping for loadFromDisk.
            const id_gop = try self.chunk_id_to_hash.getOrPut(chunk_id);
            if (!id_gop.found_existing) {
                id_gop.value_ptr.* = hk;

                // Save series key metadata for loadFromDisk recovery. Only
                // needed the first time we see this chunk_id in this
                // process — either brand new (not yet on disk) or just
                // hydrated from series_meta.dat by loadAllSeriesKeyMeta
                // (already persisted). Gating avoids an O(existing-series)
                // file rescan on every insertMany call.
                try self.saveSeriesKeyMeta(key, chunk_id);
            }

            const gop = try self.unflushed.getOrPut(hk);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += pts.len;

            if (gop.value_ptr.* >= cs.config.max_points_per_chunk) {
                // Flush all points in this series to a new chunk.
                try cs.writePoints(chunk_id, s.points.items);
                gop.value_ptr.* = 0;
            }
        }

        observability.endTimeseriesSpan(__obs_span, true, @intCast(pts.len));
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
        // sampleBy is the timeseries query/aggregation entrypoint —
        // span name `"ts.query"`. We span the OUTER call and never the
        // per-bucket inner loop (per the rollout constraint:
        // "Don't span individual data points inside batch/query").
        var __obs_span = observability.startTimeseriesSpan("query", key.metric);
        defer __obs_span.end(null);
        errdefer observability.endTimeseriesSpan(__obs_span, false, 0);

        if (interval_ms <= 0 or end_ts <= start_ts) {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        }

        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        };
        const span = std.math.sub(i64, end_ts, start_ts) catch {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        };
        const span_u: u64 = @intCast(span);
        const interval_u: u64 = @intCast(interval_ms);
        const n_buckets_u: u64 = @divTrunc(span_u + interval_u - 1, interval_u);
        if (n_buckets_u > MAX_BUCKETS) {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        }
        const n_buckets: usize = @intCast(n_buckets_u);

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

        observability.endTimeseriesSpan(__obs_span, true, @intCast(out.len));
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
        // Downsample-shaped operation — span name `"ts.downsample"`.
        // We span the OUTER call only.
        var __obs_span = observability.startTimeseriesSpan("downsample", key.metric);
        defer __obs_span.end(null);
        errdefer observability.endTimeseriesSpan(__obs_span, false, 0);

        if (bucket_seconds <= 0 or t1 <= t0) {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        }
        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        };
        const span = std.math.sub(i64, t1, t0) catch {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        };
        const span_u: u64 = @intCast(span);
        const bucket_seconds_u: u64 = @intCast(bucket_seconds);
        const n_buckets_u: u64 = @divTrunc(span_u + bucket_seconds_u - 1, bucket_seconds_u);
        if (n_buckets_u > MAX_BUCKETS) {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return &.{};
        }
        const n_buckets: usize = @intCast(n_buckets_u);
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
        observability.endTimeseriesSpan(__obs_span, true, @intCast(out.len));
        return out;
    }

    // ========================================================================
    // Persistence helpers
    // ========================================================================

    /// Flush all unflushed in-memory points to ChunkStorage.
    /// Called from deinit and can be called explicitly.
    ///
    /// `sync` is the timeseries compact/flush operation — it forces
    /// every unflushed in-memory point out to the on-disk chunk store.
    /// We span this as `"ts.compact"` (per the rollout spec). The
    /// `ts.metric` attribute is "" because `sync` operates across all
    /// series at once, not a single metric — there is no useful single
    /// metric name to attach.
    pub fn sync(self: *Store) !void {
        var __obs_span = observability.startTimeseriesSpan("compact", "");
        defer __obs_span.end(null);
        errdefer observability.endTimeseriesSpan(__obs_span, false, 0);

        const cs = self.chunk_store orelse {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return;
        };

        var ufit = self.unflushed.iterator();
        var flushed_total: u64 = 0;
        while (ufit.next()) |entry| {
            const count = entry.value_ptr.*;
            if (count == 0) continue;

            const hk = entry.key_ptr.*;
            const series = self.by_key.get(hk) orelse continue;
            if (series.points.items.len == 0) continue;

            const chunk_id = chunkSeriesId(hk);
            try cs.writePoints(chunk_id, series.points.items);
            flushed_total += @intCast(series.points.items.len);
            entry.value_ptr.* = 0;
        }

        observability.endTimeseriesSpan(__obs_span, true, flushed_total);
    }

    /// Load all persisted data from ChunkStorage into memory.
    /// Call after initWithConfig to hydrate the store on startup.
    pub fn loadFromDisk(self: *Store) !void {
        const cs = self.chunk_store orelse return;

        // Load series key metadata first.
        try self.loadAllSeriesKeyMeta();

        // Iterate over all chunk metadata entries and load by series.
        var loaded_series = std.AutoHashMap(u64, bool).init(self.allocator);
        defer loaded_series.deinit();

        for (cs.chunks.items) |chunk| {
            const sid = chunk.series_id;
            if (loaded_series.get(sid) != null) continue;
            try loaded_series.put(sid, true);

            // Look up the SeriesKey from the metadata file.
            const key = try self.readSeriesKeyForChunkId(sid) orelse continue;
            defer self.allocator.free(key.metric);

            // Query all points for this series from disk (full time range).
            const points = try cs.queryRange(sid, std.math.minInt(i64), std.math.maxInt(i64), self.allocator);
            defer self.allocator.free(points);

            if (points.len > 0) {
                try self.insertMany(key, points);
                // Reset unflushed counter since this data is already on disk.
                const hk = self.hashKey(key);
                if (self.unflushed.getPtr(hk)) |ptr| {
                    ptr.* = 0;
                }
            }
        }
    }

    /// Run retention policy on the underlying ChunkStorage.
    ///
    /// Span name `"ts.retention"`. Like `sync`, retention is global —
    /// no single metric — so `ts.metric` is "".
    pub fn runRetention(self: *Store, current_time: i64) !void {
        var __obs_span = observability.startTimeseriesSpan("retention", "");
        defer __obs_span.end(null);
        errdefer observability.endTimeseriesSpan(__obs_span, false, 0);

        const cs = self.chunk_store orelse {
            observability.endTimeseriesSpan(__obs_span, true, 0);
            return;
        };
        try cs.runRetention(current_time);
        observability.endTimeseriesSpan(__obs_span, true, 0);
    }

    /// Persist series key metadata (device_id, metric) to a file so that
    /// loadFromDisk can reconstruct SeriesKey from a chunk series_id.
    fn saveSeriesKeyMeta(self: *Store, key: SeriesKey, chunk_id: u64) !void {
        const cs = self.chunk_store orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();

        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/series_meta.dat", .{cs.data_dir});
        defer self.allocator.free(meta_path);

        // Append-only: open for appending, create if needed.
        const file = try std.Io.Dir.cwd().createFile(io, meta_path, .{
            .read = true,
            .truncate = false,
            .permissions = securePermissions(),
            .resolve_beneath = true,
        });
        defer file.close(io);

        // Check if this chunk_id is already in the file to avoid duplicates.
        var pos: u64 = 0;
        while (true) {
            var id_buf: [8]u8 = undefined;
            const id_read = file.readPositionalAll(io, &id_buf, pos) catch break;
            if (id_read < 8) break;
            pos += id_read;
            const existing_id = std.mem.readInt(u64, &id_buf, .little);

            var dev_buf: [8]u8 = undefined;
            const dev_read = file.readPositionalAll(io, &dev_buf, pos) catch break;
            if (dev_read < 8) break;
            pos += dev_read;

            var len_buf: [4]u8 = undefined;
            const len_read = file.readPositionalAll(io, &len_buf, pos) catch break;
            if (len_read < 4) break;
            pos += len_read;
            const metric_len = std.mem.readInt(u32, &len_buf, .little);

            // Skip metric bytes.
            pos += metric_len;

            if (existing_id == chunk_id) return; // Already stored.
        }

        // Append at end of file.
        var write_pos = file.length(io) catch 0;

        // Write: chunk_id (8) | device_id (8) | metric_len (4) | metric (N).
        var id_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &id_bytes, chunk_id, .little);
        try file.writePositionalAll(io, &id_bytes, write_pos);
        write_pos += 8;

        var dev_bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &dev_bytes, key.device_id, .little);
        try file.writePositionalAll(io, &dev_bytes, write_pos);
        write_pos += 8;

        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(key.metric.len), .little);
        try file.writePositionalAll(io, &len_bytes, write_pos);
        write_pos += 4;

        try file.writePositionalAll(io, key.metric, write_pos);
    }

    /// Load all series key metadata entries into chunk_id_to_hash map.
    fn loadAllSeriesKeyMeta(self: *Store) !void {
        const cs = self.chunk_store orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();

        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/series_meta.dat", .{cs.data_dir});
        defer self.allocator.free(meta_path);

        // SEC-1: never follow a symlink at this path — a planted symlink
        // pointing elsewhere could otherwise cause an attacker-controlled
        // file's bytes to be read and parsed as trusted series metadata.
        // loadFromDisk already tolerates a missing/failed series_meta.dat
        // (this whole open is wrapped in `catch return`), so blocking the
        // symlink here degrades gracefully instead of disclosing data.
        const file = std.Io.Dir.cwd().openFile(io, meta_path, .{ .follow_symlinks = false }) catch return;
        defer file.close(io);

        var pos: u64 = 0;
        while (true) {
            var id_buf: [8]u8 = undefined;
            const id_read = file.readPositionalAll(io, &id_buf, pos) catch break;
            if (id_read < 8) break;
            pos += id_read;
            const chunk_id = std.mem.readInt(u64, &id_buf, .little);

            var dev_buf: [8]u8 = undefined;
            const dev_read = file.readPositionalAll(io, &dev_buf, pos) catch break;
            if (dev_read < 8) break;
            pos += dev_read;
            const device_id = std.mem.readInt(i64, &dev_buf, .little);

            var len_buf: [4]u8 = undefined;
            const len_read = file.readPositionalAll(io, &len_buf, pos) catch break;
            if (len_read < 4) break;
            pos += len_read;
            const metric_len = std.mem.readInt(u32, &len_buf, .little);
            if (metric_len > MAX_METRIC_LEN) return error.CorruptMeta;

            const metric = try self.allocator.alloc(u8, metric_len);
            const m_read = file.readPositionalAll(io, metric, pos) catch {
                self.allocator.free(metric);
                break;
            };
            if (m_read < metric_len) {
                self.allocator.free(metric);
                break;
            }
            pos += m_read;

            // Compute the hash and register the mapping.
            const key = SeriesKey{ .device_id = device_id, .metric = metric };
            const hk = hashKeyStatic(key);
            self.allocator.free(metric);

            try self.chunk_id_to_hash.put(chunk_id, hk);
        }
    }

    /// Read a specific series key from the metadata file given a chunk_id.
    fn readSeriesKeyForChunkId(self: *Store, target_chunk_id: u64) !?SeriesKey {
        const cs = self.chunk_store orelse return null;
        const io = std.Io.Threaded.global_single_threaded.io();

        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/series_meta.dat", .{cs.data_dir});
        defer self.allocator.free(meta_path);

        // SEC-1: same rationale as loadAllSeriesKeyMeta — never follow a
        // symlink planted at this path.
        const file = std.Io.Dir.cwd().openFile(io, meta_path, .{ .follow_symlinks = false }) catch return null;
        defer file.close(io);

        var pos: u64 = 0;
        while (true) {
            var id_buf: [8]u8 = undefined;
            const id_read = file.readPositionalAll(io, &id_buf, pos) catch break;
            if (id_read < 8) break;
            pos += id_read;
            const chunk_id = std.mem.readInt(u64, &id_buf, .little);

            var dev_buf: [8]u8 = undefined;
            const dev_read = file.readPositionalAll(io, &dev_buf, pos) catch break;
            if (dev_read < 8) break;
            pos += dev_read;
            const device_id = std.mem.readInt(i64, &dev_buf, .little);

            var len_buf: [4]u8 = undefined;
            const len_read = file.readPositionalAll(io, &len_buf, pos) catch break;
            if (len_read < 4) break;
            pos += len_read;
            const metric_len = std.mem.readInt(u32, &len_buf, .little);
            if (metric_len > MAX_METRIC_LEN) return error.CorruptMeta;

            const metric = try self.allocator.alloc(u8, metric_len);
            const m_read = file.readPositionalAll(io, metric, pos) catch {
                self.allocator.free(metric);
                break;
            };
            if (m_read < metric_len) {
                self.allocator.free(metric);
                break;
            }
            pos += m_read;

            if (chunk_id == target_chunk_id) {
                return SeriesKey{ .device_id = device_id, .metric = metric };
            }
            self.allocator.free(metric);
        }

        return null;
    }
};

/// Extract the lower 64 bits of a u128 hash for use as ChunkStorage series_id.
fn chunkSeriesId(hk: u128) u64 {
    return @intCast(hk & 0xFFFFFFFFFFFFFFFF);
}

/// Static version of hashKey that does not require a Store instance.
fn hashKeyStatic(k: SeriesKey) u128 {
    // fips-exempt: non-security — series-key hashmap hashing (device_id + metric)
    // into a 128-bit index key via two Wyhash seeds; distribution/lookup only,
    // not a secret.
    var h1 = std.hash.Wyhash.init(0);
    h1.update(std.mem.asBytes(&k.device_id));
    h1.update(k.metric);
    const x1 = h1.final();
    // fips-exempt: non-security — second half of the 128-bit series-key hash (see above).
    var h2 = std.hash.Wyhash.init(0x517cc1b727220a95);
    h2.update(std.mem.asBytes(&k.device_id));
    h2.update(k.metric);
    const x2 = h2.final();
    return (@as(u128, x1) << 64) | @as(u128, x2);
}

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

test "store: sampleBy overflow-safe span (F7)" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "overflow" };
    try st.insertMany(key, &.{.{ .ts = 0, .value = 10 }});

    const result = try st.sampleBy(
        key,
        1,
        std.math.minInt(i64),
        std.math.maxInt(i64),
        .avg,
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expect(result.len == 0);
}

test "store: timeBucketAvg overflow-safe span (F7)" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "overflow" };
    try st.insertMany(key, &.{.{ .ts = 0, .value = 10 }});

    const result = try st.timeBucketAvg(
        key,
        1,
        std.math.minInt(i64),
        std.math.maxInt(i64),
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expect(result.len == 0);
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

// ============================================================================
// Persistence Tests (GAP-0292)
// ============================================================================

test "store: initWithConfig backward compat — no data_dir" {
    const allocator = std.testing.allocator;
    var st = try Store.initWithConfig(allocator, .{});
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{.{ .ts = 100, .value = 10 }});
    const l = st.last(key).?;
    try std.testing.expectEqual(@as(i64, 100), l.ts);
    try std.testing.expectEqual(@as(i64, 10), l.value);
    try std.testing.expect(st.chunk_store == null);
}

test "store: persist-restart-query round-trip" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_persist_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    const key = SeriesKey{ .device_id = 42, .metric = "cpu_temp" };

    // Phase 1: Create store, insert data, deinit (flushes to disk).
    {
        var st = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 10 },
        });
        defer st.deinit();

        try st.insertMany(key, &.{
            .{ .ts = 1000, .value = 10 },
            .{ .ts = 2000, .value = 20 },
            .{ .ts = 3000, .value = 30 },
            .{ .ts = 4000, .value = 40 },
            .{ .ts = 5000, .value = 50 },
        });
    }

    // Phase 2: Re-create store from same data_dir, loadFromDisk, query.
    {
        var st2 = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 10 },
        });
        defer st2.deinit();

        try st2.loadFromDisk();

        // Verify data is present and queryable.
        const l = st2.last(key);
        try std.testing.expect(l != null);
        try std.testing.expectEqual(@as(i64, 5000), l.?.ts);
        try std.testing.expectEqual(@as(i64, 50), l.?.value);

        // Verify all points loaded.
        const series = st2.getSeries(key);
        try std.testing.expect(series != null);
        try std.testing.expectEqual(@as(usize, 5), series.?.points.items.len);

        // Verify ordering preserved.
        try std.testing.expectEqual(@as(i64, 1000), series.?.points.items[0].ts);
        try std.testing.expectEqual(@as(i64, 10), series.?.points.items[0].value);
    }
}

test "store: series key persisted exactly once across many inserts, recovered once after reload" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_persist_many_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    const key = SeriesKey{ .device_id = 7, .metric = "many_inserts" };
    const n_inserts: i64 = 50;

    // Phase 1: Insert the same series across many separate insertMany calls
    // (exercises the saveSeriesKeyMeta gate on every call, not just once),
    // then deinit (flushes to disk).
    {
        var st = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 1000 },
        });
        defer st.deinit();

        var i: i64 = 0;
        while (i < n_inserts) : (i += 1) {
            try st.insertMany(key, &.{.{ .ts = 1000 + i, .value = i }});
        }
    }

    // The series_meta.dat file should contain exactly one record for this
    // series, even though insertMany was called n_inserts times.
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        var meta_path_buf: [160]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/timeseries/series_meta.dat", .{test_dir}) catch unreachable;
        const file = try std.Io.Dir.cwd().openFile(io, meta_path, .{});
        defer file.close(io);

        var record_count: usize = 0;
        var pos: u64 = 0;
        while (true) {
            var id_buf: [8]u8 = undefined;
            const id_read = file.readPositionalAll(io, &id_buf, pos) catch break;
            if (id_read < 8) break;
            pos += id_read;

            var dev_buf: [8]u8 = undefined;
            const dev_read = file.readPositionalAll(io, &dev_buf, pos) catch break;
            if (dev_read < 8) break;
            pos += dev_read;

            var len_buf: [4]u8 = undefined;
            const len_read = file.readPositionalAll(io, &len_buf, pos) catch break;
            if (len_read < 4) break;
            pos += len_read;
            const metric_len = std.mem.readInt(u32, &len_buf, .little);

            pos += metric_len;
            record_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), record_count);
    }

    // Phase 2: Re-create store from same data_dir, loadFromDisk, query.
    {
        var st2 = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 1000 },
        });
        defer st2.deinit();

        try st2.loadFromDisk();

        // Verify the series key was recovered exactly once (single Series
        // entry, all points present, no duplication).
        const series = st2.getSeries(key);
        try std.testing.expect(series != null);
        try std.testing.expectEqual(@as(usize, @intCast(n_inserts)), series.?.points.items.len);

        const l = st2.last(key);
        try std.testing.expect(l != null);
        try std.testing.expectEqual(@as(i64, 1000 + n_inserts - 1), l.?.ts);
    }
}

test "store: retention integration with persistence" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_retention_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    var st = try Store.initWithConfig(allocator, .{
        .data_dir = test_dir,
        .chunk_config = .{ .retention_days = 1, .max_points_per_chunk = 5 },
    });
    defer st.deinit();

    const current_time: i64 = 1_000_000_000;
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Insert old data (2 days ago) and recent data.
    const key = SeriesKey{ .device_id = 1, .metric = "disk" };
    try st.insertMany(key, &.{
        .{ .ts = current_time - 2 * day_ms, .value = 1 },
        .{ .ts = current_time - 1000, .value = 2 },
    });

    // Force flush.
    try st.sync();

    // Run retention.
    try st.runRetention(current_time);

    // After retention, querying from chunk storage should only find the recent chunk.
    const cs = st.chunk_store.?;
    try std.testing.expectEqual(@as(usize, 1), cs.chunks.items.len);
}

test "store: sync flushes unflushed data" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_sync_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    var st = try Store.initWithConfig(allocator, .{
        .data_dir = test_dir,
        .chunk_config = .{ .max_points_per_chunk = 100000 },
    });
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "mem" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
    });

    // Before sync, ChunkStorage should have no chunks (threshold not reached).
    try std.testing.expectEqual(@as(usize, 0), st.chunk_store.?.chunks.items.len);

    // After sync, data should be persisted.
    try st.sync();
    try std.testing.expectEqual(@as(usize, 1), st.chunk_store.?.chunks.items.len);
}

test "store: init backward compat — in-memory only" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 99, .metric = "test" };
    try st.insertMany(key, &.{
        .{ .ts = 500, .value = 5 },
        .{ .ts = 600, .value = 6 },
    });

    const l = st.last(key).?;
    try std.testing.expectEqual(@as(i64, 600), l.ts);
    try std.testing.expect(st.chunk_store == null);
}

test "store: loadAllSeriesKeyMeta does not follow a symlinked series_meta.dat (SEC-1)" {
    // POSIX-only: relies on O_NOFOLLOW semantics for symlinks.
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_symlink_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // Create the store directory structure (and a real series_meta.dat)
    // first, then tear the store down.
    {
        var st = try Store.initWithConfig(allocator, .{ .data_dir = test_dir });
        defer st.deinit();
        try st.insertMany(.{ .device_id = 1, .metric = "cpu_temp" }, &.{.{ .ts = 1000, .value = 1 }});
    }

    var meta_path_buf: [160]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/timeseries/series_meta.dat", .{test_dir}) catch unreachable;

    // Remove the real metadata file and plant a well-formed record
    // elsewhere, then replace series_meta.dat with a symlink to the
    // planted file. If the read path followed the symlink, this planted
    // (attacker-controlled) record would be ingested as if it were
    // legitimate series metadata — an information-disclosure primitive.
    try std.Io.Dir.cwd().deleteFile(io, meta_path);

    var planted_path_buf: [160]u8 = undefined;
    const planted_path = std.fmt.bufPrint(&planted_path_buf, "{s}/planted.dat", .{test_dir}) catch unreachable;
    {
        const planted_metric = "pwned";
        const planted_file = try std.Io.Dir.cwd().createFile(io, planted_path, .{ .read = true, .truncate = true });
        defer planted_file.close(io);

        var buf: [20]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], 0xdeadbeef, .little); // chunk_id
        std.mem.writeInt(i64, buf[8..16], 1234, .little); // device_id
        std.mem.writeInt(u32, buf[16..20], @intCast(planted_metric.len), .little); // metric_len
        try planted_file.writePositionalAll(io, &buf, 0);
        try planted_file.writePositionalAll(io, planted_metric, 20);
    }

    try std.Io.Dir.symLinkAbsolute(io, planted_path, meta_path, .{});

    // Re-open the store and attempt to hydrate series-key metadata. The
    // symlink must not be followed: loadAllSeriesKeyMeta should degrade
    // gracefully (no crash, no error) and must not ingest the planted
    // record.
    var st2 = try Store.initWithConfig(allocator, .{ .data_dir = test_dir });
    defer st2.deinit();

    try st2.loadAllSeriesKeyMeta();
    try std.testing.expectEqual(@as(usize, 0), st2.chunk_id_to_hash.count());

    // loadFromDisk (the real public entrypoint) must also not crash and
    // must degrade gracefully.
    try st2.loadFromDisk();
}

test "store: loadFromDisk rejects oversized metric_len in series_meta.dat" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_bad_metric_len_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    var st = try Store.initWithConfig(allocator, .{ .data_dir = test_dir });
    defer st.deinit();

    const cs = st.chunk_store.?;
    const io = std.Io.Threaded.global_single_threaded.io();

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/series_meta.dat", .{cs.data_dir});
    defer allocator.free(meta_path);

    const file = try std.Io.Dir.cwd().createFile(io, meta_path, .{ .read = true, .truncate = true });
    defer file.close(io);

    // Single record: chunk_id (8) | device_id (8) | metric_len (4) = 0xFFFFFFFF, no metric bytes.
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 1, .little);
    std.mem.writeInt(i64, buf[8..16], 1, .little);
    std.mem.writeInt(u32, buf[16..20], 0xFFFFFFFF, .little);
    try file.writePositionalAll(io, &buf, 0);

    const result = st.loadFromDisk();
    try std.testing.expectError(error.CorruptMeta, result);
}

test "store: initWithConfig leak-free when ChunkStorage.init returns error.CorruptMeta" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_store_init_corrupt_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // Phase 1: create a store, write one valid chunk, and let deinit flush
    // + close cleanly.
    {
        var st = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 1 },
        });
        defer st.deinit();
        try st.insertMany(.{ .device_id = 1, .metric = "cpu" }, &.{.{ .ts = 1000, .value = 1 }});
    }

    // Phase 2: append a corrupt trailing record directly to chunk_meta.dat
    // so the next ChunkStorage.init (invoked transitively by
    // Store.initWithConfig) fails with error.CorruptMeta.
    {
        var meta_path_buf: [160]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/timeseries/chunk_meta.dat", .{test_dir}) catch unreachable;
        const file = try std.Io.Dir.cwd().openFile(io, meta_path, .{ .mode = .read_write });
        defer file.close(io);
        const end_pos = file.length(io) catch 0;

        // ChunkMeta is fixed-size when serialized: 8+8+8+4+4+4+4+8 = 48 bytes
        // (see chunk_storage.zig's chunk_meta_size).
        var buf: [48]u8 = undefined;
        var off: usize = 0;
        std.mem.writeInt(u64, buf[off..][0..8], 2, .little); // series_id
        off += 8;
        std.mem.writeInt(i64, buf[off..][0..8], 0, .little); // start_ts
        off += 8;
        std.mem.writeInt(i64, buf[off..][0..8], 0, .little); // end_ts
        off += 8;
        std.mem.writeInt(u32, buf[off..][0..4], 1, .little); // num_points
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], 0, .little); // compressed_size
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], 0, .little); // uncompressed_size
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], 99, .little); // invalid compression tag
        off += 4;
        std.mem.writeInt(u64, buf[off..][0..8], 0, .little); // page_offset
        try file.writePositionalAll(io, &buf, end_pos);
    }

    // Phase 3: re-init should surface error.CorruptMeta with zero leaks —
    // both the heap-allocated ChunkStorage (`cs`) and its internal
    // chunks/index/data_dir must be freed on this error path.
    const result = Store.initWithConfig(allocator, .{
        .data_dir = test_dir,
        .chunk_config = .{ .max_points_per_chunk = 1 },
    });
    try std.testing.expectError(error.CorruptMeta, result);
}

test "fips-exempt annotation present on series-key Wyhash site" {
    const src = @embedFile("store.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "fips-exempt: non-security — series-key hashmap") != null);
}
