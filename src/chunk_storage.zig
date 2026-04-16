// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Chunk storage with Gorilla compression for time-series data.
//! Ported from Geode's chunk_storage.zig with Zig 0.16.0 API fixes.

const std = @import("std");
const store = @import("store.zig");

/// Helper to obtain a global single-threaded I/O context for file operations.
inline fn gio() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Gorilla-inspired compression for time-series data.
pub const ChunkConfig = struct {
    max_points_per_chunk: usize = 4096,
    compression_algorithm: CompressionAlgorithm = .gorilla,
    retention_days: u32 = 30,
};

pub const CompressionAlgorithm = enum {
    none,
    gorilla,
    delta_of_delta,
    zstd,
};

/// Compressed chunk metadata.
pub const ChunkMeta = struct {
    series_id: u64,
    start_ts: i64,
    end_ts: i64,
    num_points: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    compression: CompressionAlgorithm,
    page_offset: u64,
};

/// Gorilla compression context.
pub const GorillaEncoder = struct {
    bits: std.DynamicBitSet,
    bit_pos: usize,
    point_count: usize,
    prev_ts: i64,
    prev_delta: i64,
    prev_value: i64,
    prev_xor: u64,
    prev_leading: u8,
    prev_trailing: u8,

    pub fn init(allocator: std.mem.Allocator) !GorillaEncoder {
        return .{
            .bits = try std.DynamicBitSet.initEmpty(allocator, 65536),
            .bit_pos = 0,
            .point_count = 0,
            .prev_ts = 0,
            .prev_delta = 0,
            .prev_value = 0,
            .prev_xor = 0,
            .prev_leading = 0,
            .prev_trailing = 0,
        };
    }

    pub fn deinit(self: *GorillaEncoder) void {
        self.bits.deinit();
    }

    /// Encode a time-series point using Gorilla compression.
    pub fn encodePoint(self: *GorillaEncoder, point: store.Point) !void {
        if (self.point_count == 0) {
            try self.writeRaw(64, @bitCast(point.ts));
            try self.writeRaw(64, @bitCast(point.value));
            self.prev_ts = point.ts;
            self.prev_value = point.value;
            self.point_count = 1;
            return;
        }

        self.point_count += 1;

        // Encode timestamp using delta-of-delta.
        const delta = point.ts - self.prev_ts;
        const delta_of_delta = delta - self.prev_delta;

        if (delta_of_delta == 0) {
            try self.writeBit(0);
        } else if (delta_of_delta >= -63 and delta_of_delta <= 64) {
            try self.writeBits(2, 0b10);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0x7F;
            try self.writeBits(7, v);
        } else if (delta_of_delta >= -255 and delta_of_delta <= 256) {
            try self.writeBits(3, 0b110);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0x1FF;
            try self.writeBits(9, v);
        } else if (delta_of_delta >= -2047 and delta_of_delta <= 2048) {
            try self.writeBits(4, 0b1110);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0xFFF;
            try self.writeBits(12, v);
        } else {
            try self.writeBits(4, 0b1111);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0xFFFFFFFF;
            try self.writeBits(32, v);
        }

        self.prev_delta = delta;
        self.prev_ts = point.ts;

        // Encode value using XOR compression.
        const xor: u64 = @bitCast(point.value ^ self.prev_value);

        if (xor == 0) {
            try self.writeBit(0);
        } else {
            try self.writeBit(1);

            const leading = @clz(xor);
            const trailing = @ctz(xor);

            if (leading >= self.prev_leading and trailing >= self.prev_trailing) {
                try self.writeBit(0);
                const significant_bits = 64 - self.prev_leading - self.prev_trailing;
                const shifted = xor >> @intCast(self.prev_trailing);
                try self.writeBits(@intCast(significant_bits), shifted);
            } else {
                try self.writeBit(1);
                try self.writeBits(5, leading);
                const significant_bits = 64 - leading - trailing;
                try self.writeBits(6, significant_bits);
                const shifted = xor >> @intCast(trailing);
                try self.writeBits(@intCast(significant_bits), shifted);

                self.prev_leading = leading;
                self.prev_trailing = trailing;
            }
        }

        self.prev_value = point.value;
        self.prev_xor = xor;
    }

    fn writeBit(self: *GorillaEncoder, bit: u1) !void {
        if (self.bit_pos >= self.bits.capacity()) {
            try self.bits.resize(self.bits.capacity() * 2, false);
        }
        self.bits.setValue(self.bit_pos, bit == 1);
        self.bit_pos += 1;
    }

    /// Write up to 64 bits at once using direct mask manipulation.
    /// Bits are written MSB-first: the highest bit of `value` (bit num_bits-1)
    /// is placed at the current bit_pos, and the lowest bit (bit 0) at
    /// bit_pos + num_bits - 1.
    ///
    /// Performance: Single capacity check for all bits instead of per-bit,
    /// and direct mask pointer writes without per-bit bounds checking or
    /// function call overhead.
    fn writeBits(self: *GorillaEncoder, num_bits: u8, value: u64) !void {
        if (num_bits == 0) return;

        // Ensure capacity for all bits in one check instead of per-bit.
        const required = self.bit_pos + num_bits;
        if (required > self.bits.capacity()) {
            var new_cap = self.bits.capacity();
            while (new_cap < required) new_cap *= 2;
            try self.bits.resize(new_cap, false);
        }

        const masks = self.bits.unmanaged.masks;
        const mask_bits: u8 = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        const ShiftInt = std.DynamicBitSetUnmanaged.ShiftInt;

        // Write bits directly into the mask words without per-bit capacity
        // checks. Each bit at position `p` maps to masks[p / mask_bits] at
        // bit (p % mask_bits). We write MSB-first: bit (num_bits-1) of
        // value goes to bit_pos, bit 0 goes to bit_pos + num_bits - 1.
        var bit_idx: u8 = num_bits;
        var pos = self.bit_pos;
        while (bit_idx > 0) {
            const word_idx = pos / mask_bits;
            const dst_bit: ShiftInt = @intCast(pos % mask_bits);
            const src_bit: u6 = @intCast(bit_idx - 1);
            const b: usize = @intCast((value >> src_bit) & 1);
            masks[word_idx] = (masks[word_idx] & ~(@as(usize, 1) << dst_bit)) | (b << dst_bit);
            bit_idx -= 1;
            pos += 1;
        }

        self.bit_pos = pos;
    }

    fn writeRaw(self: *GorillaEncoder, num_bits: u8, value: u64) !void {
        try self.writeBits(num_bits, value);
    }

    /// Extract compressed data as a byte array.
    ///
    /// Performance: Reads full words from the internal mask array and
    /// extracts bytes with bit-reversal, avoiding per-bit isSet() calls
    /// and their associated bounds checks.
    pub fn getCompressedData(self: *GorillaEncoder, allocator: std.mem.Allocator) ![]u8 {
        const byte_count = (self.bit_pos + 7) / 8;
        const result = try allocator.alloc(u8, byte_count);

        const masks = self.bits.unmanaged.masks;
        const mask_bits = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        const bytes_per_word = mask_bits / 8;

        // Process full words: extract bytes directly from each mask word.
        // Within each word, bits are stored LSB-first (bit 0 = least significant).
        // Output bytes need MSB-first ordering (bitset position i*8+0 -> byte bit 7).
        // So each byte is @bitReverse of the corresponding 8 bits in the word.
        const full_words = byte_count / bytes_per_word;
        for (0..full_words) |word_idx| {
            const word = masks[word_idx];
            const base = word_idx * bytes_per_word;
            inline for (0..bytes_per_word) |b| {
                const raw: u8 = @truncate(word >> (b * 8));
                result[base + b] = @bitReverse(raw);
            }
        }

        // Process remaining bytes that don't fill a complete word.
        const remaining_start = full_words * bytes_per_word;
        if (remaining_start < byte_count) {
            const word = masks[full_words];
            for (remaining_start..byte_count) |i| {
                const byte_in_word = i - remaining_start;
                var raw: u8 = @truncate(word >> @intCast(byte_in_word * 8));
                // Mask off bits beyond bit_pos for the final byte.
                if (i == byte_count - 1 and self.bit_pos % 8 != 0) {
                    const valid_bits: u3 = @intCast(self.bit_pos % 8);
                    // Only the first `valid_bits` bits of this byte are valid.
                    // In the raw byte (LSB-first from the word), those are
                    // the lowest `valid_bits` bits.
                    const keep_mask: u8 = (@as(u8, 1) << valid_bits) - 1;
                    raw &= keep_mask;
                }
                result[i] = @bitReverse(raw);
            }
        }

        return result;
    }
};

/// Gorilla decompression context -- reverses GorillaEncoder.
pub const GorillaDecoder = struct {
    data: []const u8,
    bit_pos: usize,
    total_bits: usize,
    prev_ts: i64,
    prev_delta: i64,
    prev_value: i64,
    prev_leading: u8,
    prev_trailing: u8,
    point_count: usize,
    num_points: u32,

    pub fn init(data: []const u8, num_points: u32) GorillaDecoder {
        return .{
            .data = data,
            .bit_pos = 0,
            .total_bits = data.len * 8,
            .prev_ts = 0,
            .prev_delta = 0,
            .prev_value = 0,
            .prev_leading = 0,
            .prev_trailing = 0,
            .point_count = 0,
            .num_points = num_points,
        };
    }

    fn readBit(self: *GorillaDecoder) !u1 {
        if (self.bit_pos >= self.total_bits) return error.EndOfStream;
        const byte_idx = self.bit_pos / 8;
        const bit_idx: u3 = @intCast(7 - (self.bit_pos % 8));
        const bit: u1 = @intCast((self.data[byte_idx] >> bit_idx) & 1);
        self.bit_pos += 1;
        return bit;
    }

    fn readBits(self: *GorillaDecoder, num_bits: u8) !u64 {
        var value: u64 = 0;
        for (0..num_bits) |_| {
            value = (value << 1) | @as(u64, try self.readBit());
        }
        return value;
    }

    /// Sign-extend a value from `bits`-wide to i64.
    fn signExtend(value: u64, bits: u8) i64 {
        if (bits == 0 or bits >= 64) return @bitCast(value);
        const sign_bit: u64 = @as(u64, 1) << @intCast(bits - 1);
        if (value & sign_bit != 0) {
            // Negative: fill upper bits with 1s.
            const mask = @as(u64, std.math.maxInt(u64)) << @intCast(bits);
            return @bitCast(value | mask);
        }
        return @bitCast(value);
    }

    /// Decode the next point from the compressed bitstream.
    pub fn decodePoint(self: *GorillaDecoder) !store.Point {
        if (self.point_count >= self.num_points) return error.EndOfStream;

        if (self.point_count == 0) {
            // First point: raw 64-bit timestamp + raw 64-bit value.
            const ts_raw = try self.readBits(64);
            const val_raw = try self.readBits(64);
            self.prev_ts = @bitCast(ts_raw);
            self.prev_value = @bitCast(val_raw);
            self.point_count = 1;
            return .{ .ts = self.prev_ts, .value = self.prev_value };
        }

        self.point_count += 1;

        // Decode timestamp delta-of-delta.
        var delta_of_delta: i64 = 0;
        const first_bit = try self.readBit();
        if (first_bit == 0) {
            delta_of_delta = 0;
        } else {
            const second_bit = try self.readBit();
            if (second_bit == 0) {
                // Prefix 10: 7-bit value.
                const raw = try self.readBits(7);
                delta_of_delta = signExtend(raw, 7);
            } else {
                const third_bit = try self.readBit();
                if (third_bit == 0) {
                    // Prefix 110: 9-bit value.
                    const raw = try self.readBits(9);
                    delta_of_delta = signExtend(raw, 9);
                } else {
                    const fourth_bit = try self.readBit();
                    if (fourth_bit == 0) {
                        // Prefix 1110: 12-bit value.
                        const raw = try self.readBits(12);
                        delta_of_delta = signExtend(raw, 12);
                    } else {
                        // Prefix 1111: 32-bit value.
                        const raw = try self.readBits(32);
                        delta_of_delta = signExtend(raw, 32);
                    }
                }
            }
        }

        const delta = self.prev_delta + delta_of_delta;
        const ts = self.prev_ts + delta;
        self.prev_delta = delta;
        self.prev_ts = ts;

        // Decode value using XOR compression.
        const xor_control = try self.readBit();
        var value: i64 = undefined;
        if (xor_control == 0) {
            // XOR is 0: same value as previous.
            value = self.prev_value;
        } else {
            const xor_type = try self.readBit();
            var xor: u64 = undefined;
            if (xor_type == 0) {
                // Reuse previous leading/trailing: read significant bits.
                const significant_bits = 64 - @as(u8, self.prev_leading) - @as(u8, self.prev_trailing);
                const shifted = try self.readBits(significant_bits);
                xor = shifted << @intCast(self.prev_trailing);
            } else {
                // New leading/trailing.
                const leading: u8 = @intCast(try self.readBits(5));
                const significant_bits: u8 = @intCast(try self.readBits(6));
                const trailing: u8 = 64 - leading - significant_bits;
                const shifted = try self.readBits(significant_bits);
                xor = shifted << @intCast(trailing);
                self.prev_leading = leading;
                self.prev_trailing = trailing;
            }
            value = self.prev_value ^ @as(i64, @bitCast(xor));
        }

        self.prev_value = value;
        return .{ .ts = ts, .value = value };
    }

    /// Decode all points from the compressed bitstream.
    pub fn decodeAll(self: *GorillaDecoder, allocator: std.mem.Allocator) ![]store.Point {
        var points: std.ArrayList(store.Point) = .{};
        errdefer points.deinit(allocator);
        try points.ensureTotalCapacity(allocator, self.num_points);

        while (self.point_count < self.num_points) {
            const point = try self.decodePoint();
            try points.append(allocator, point);
        }

        return try points.toOwnedSlice(allocator);
    }
};

/// Chunk storage manager with filesystem persistence.
pub const ChunkStorage = struct {
    allocator: std.mem.Allocator,
    config: ChunkConfig,
    chunks: std.ArrayList(ChunkMeta),
    index: std.AutoHashMap(u64, std.ArrayList(usize)),
    data_file: ?std.Io.File,
    data_offset: u64,
    data_dir: []const u8,

    pub const InitError = error{InvalidPath};

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: ChunkConfig) !ChunkStorage {
        // Reject path traversal attempts.
        if (std.mem.indexOf(u8, data_dir, "..") != null) return error.InvalidPath;

        const io = gio();
        // Ensure the data directory exists.
        std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};

        const chunks_path = try std.fmt.allocPrint(allocator, "{s}/chunks.dat", .{data_dir});
        defer allocator.free(chunks_path);

        const file = try std.Io.Dir.cwd().createFile(io, chunks_path, .{
            .read = true,
            .truncate = false,
        });

        // Determine current file length so new writes append after existing data.
        const end_pos = file.length(io) catch 0;

        var self = ChunkStorage{
            .allocator = allocator,
            .config = config,
            .chunks = .{},
            .index = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator),
            .data_file = file,
            .data_offset = end_pos,
            .data_dir = try allocator.dupe(u8, data_dir),
        };

        // Load persisted chunk metadata if available.
        try self.loadChunkMeta();

        return self;
    }

    pub fn deinit(self: *ChunkStorage) void {
        var it = self.index.valueIterator();
        while (it.next()) |vp| {
            var list = vp.*;
            list.deinit(self.allocator);
        }
        self.index.deinit();
        self.chunks.deinit(self.allocator);
        if (self.data_file) |file| {
            file.close(gio());
        }
        self.allocator.free(self.data_dir);
    }

    /// Write a batch of points to chunks.
    pub fn writePoints(self: *ChunkStorage, series_id: u64, points: []const store.Point) !void {
        if (points.len == 0) return;

        var encoder = try GorillaEncoder.init(self.allocator);
        defer encoder.deinit();

        for (points) |point| {
            try encoder.encodePoint(point);
        }

        const compressed = try encoder.getCompressedData(self.allocator);
        defer self.allocator.free(compressed);

        const meta = ChunkMeta{
            .series_id = series_id,
            .start_ts = points[0].ts,
            .end_ts = points[points.len - 1].ts,
            .num_points = @intCast(points.len),
            .compressed_size = @intCast(compressed.len),
            .uncompressed_size = @intCast(points.len * @sizeOf(store.Point)),
            .compression = self.config.compression_algorithm,
            .page_offset = self.data_offset,
        };

        if (self.data_file) |file| {
            try file.writePositionalAll(gio(), compressed, self.data_offset);
            self.data_offset += compressed.len;
        }

        const chunk_idx = self.chunks.items.len;
        try self.chunks.append(self.allocator, meta);

        // Update the series index.
        const gop = try self.index.getOrPut(series_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, chunk_idx);

        // Persist chunk metadata to disk.
        try self.appendChunkMeta(meta);
    }

    /// Query chunks for a time range.
    pub fn queryRange(
        self: *ChunkStorage,
        series_id: u64,
        start_ts: i64,
        end_ts: i64,
        allocator: std.mem.Allocator,
    ) ![]store.Point {
        const list = self.index.get(series_id) orelse return &.{};

        var results: std.ArrayList(store.Point) = .{};
        errdefer results.deinit(allocator);

        for (list.items) |idx| {
            const chunk = self.chunks.items[idx];
            if (chunk.end_ts < start_ts or chunk.start_ts > end_ts) continue;

            // Read compressed data from file.
            const file = self.data_file orelse continue;
            const compressed = try allocator.alloc(u8, chunk.compressed_size);
            defer allocator.free(compressed);

            const bytes_read = file.readPositionalAll(gio(), compressed, chunk.page_offset) catch continue;
            if (bytes_read != chunk.compressed_size) continue;

            // Decompress and filter to requested range.
            var decoder = GorillaDecoder.init(compressed, chunk.num_points);
            const points = try decoder.decodeAll(allocator);
            defer allocator.free(points);

            for (points) |point| {
                if (point.ts >= start_ts and point.ts <= end_ts) {
                    try results.append(allocator, point);
                }
            }
        }

        return try results.toOwnedSlice(allocator);
    }

    /// Run retention policy to prune old chunks.
    pub fn runRetention(self: *ChunkStorage, current_time: i64) !void {
        const retention_ms = @as(i64, self.config.retention_days) * 24 * 60 * 60 * 1000;
        const cutoff_time = current_time - retention_ms;

        var new_chunks: std.ArrayList(ChunkMeta) = .{};

        // Clear index.
        var it = self.index.valueIterator();
        while (it.next()) |vp| {
            var list = vp.*;
            list.deinit(self.allocator);
        }
        self.index.clearAndFree();

        // Rebuild with non-expired chunks.
        for (self.chunks.items) |chunk| {
            if (chunk.end_ts >= cutoff_time) {
                try new_chunks.append(self.allocator, chunk);

                const gop = try self.index.getOrPut(chunk.series_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{};
                }
                try gop.value_ptr.append(self.allocator, new_chunks.items.len - 1);
            }
        }

        self.chunks.deinit(self.allocator);
        self.chunks = new_chunks;
    }

    /// Get compression ratio statistics.
    pub fn getCompressionStats(self: *ChunkStorage) struct {
        total_compressed: u64,
        total_uncompressed: u64,
        ratio: f64,
        avg_chunk_size: f64,
        total_chunks: usize,
    } {
        var total_compressed: u64 = 0;
        var total_uncompressed: u64 = 0;

        for (self.chunks.items) |chunk| {
            total_compressed += chunk.compressed_size;
            total_uncompressed += chunk.uncompressed_size;
        }

        const ratio = if (total_uncompressed > 0)
            @as(f64, @floatFromInt(total_compressed)) / @as(f64, @floatFromInt(total_uncompressed))
        else
            0.0;

        const avg_size = if (self.chunks.items.len > 0)
            @as(f64, @floatFromInt(total_compressed)) / @as(f64, @floatFromInt(self.chunks.items.len))
        else
            0.0;

        return .{
            .total_compressed = total_compressed,
            .total_uncompressed = total_uncompressed,
            .ratio = ratio,
            .avg_chunk_size = avg_size,
            .total_chunks = self.chunks.items.len,
        };
    }

    // ====================================================================
    // Chunk metadata persistence
    // ====================================================================

    /// ChunkMeta is fixed-size when serialized: 8+8+8+4+4+4+4+8 = 48 bytes.
    const chunk_meta_size: usize = 48;

    /// Append a single ChunkMeta record to the chunk_meta.dat file.
    fn appendChunkMeta(self: *ChunkStorage, meta: ChunkMeta) !void {
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/chunk_meta.dat", .{self.data_dir});
        defer self.allocator.free(meta_path);

        const io = gio();
        const file = try std.Io.Dir.cwd().createFile(io, meta_path, .{
            .read = true,
            .truncate = false,
        });
        defer file.close(io);

        const end_pos = file.length(io) catch 0;

        var buf: [chunk_meta_size]u8 = undefined;
        serializeChunkMeta(&buf, meta);
        try file.writePositionalAll(io, &buf, end_pos);
    }

    /// Load all ChunkMeta records from chunk_meta.dat and rebuild the in-memory index.
    fn loadChunkMeta(self: *ChunkStorage) !void {
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/chunk_meta.dat", .{self.data_dir});
        defer self.allocator.free(meta_path);

        const io = gio();
        const file = std.Io.Dir.cwd().openFile(io, meta_path, .{}) catch return; // No metadata yet.
        defer file.close(io);

        var read_off: u64 = 0;
        while (true) {
            var buf: [chunk_meta_size]u8 = undefined;
            const n = file.readPositionalAll(io, &buf, read_off) catch break;
            if (n < chunk_meta_size) break;
            read_off += n;

            const meta = deserializeChunkMeta(&buf);
            const chunk_idx = self.chunks.items.len;
            try self.chunks.append(self.allocator, meta);

            const gop = try self.index.getOrPut(meta.series_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(self.allocator, chunk_idx);
        }
    }

    fn serializeChunkMeta(buf: *[chunk_meta_size]u8, m: ChunkMeta) void {
        var off: usize = 0;
        std.mem.writeInt(u64, buf[off..][0..8], m.series_id, .little);
        off += 8;
        std.mem.writeInt(i64, buf[off..][0..8], m.start_ts, .little);
        off += 8;
        std.mem.writeInt(i64, buf[off..][0..8], m.end_ts, .little);
        off += 8;
        std.mem.writeInt(u32, buf[off..][0..4], m.num_points, .little);
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], m.compressed_size, .little);
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], m.uncompressed_size, .little);
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], @intFromEnum(m.compression), .little);
        off += 4;
        std.mem.writeInt(u64, buf[off..][0..8], m.page_offset, .little);
    }

    fn deserializeChunkMeta(buf: *const [chunk_meta_size]u8) ChunkMeta {
        var off: usize = 0;
        const series_id = std.mem.readInt(u64, buf[off..][0..8], .little);
        off += 8;
        const start_ts = std.mem.readInt(i64, buf[off..][0..8], .little);
        off += 8;
        const end_ts = std.mem.readInt(i64, buf[off..][0..8], .little);
        off += 8;
        const num_points = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        const compressed_size = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        const uncompressed_size = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        const compression_raw = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        const page_offset = std.mem.readInt(u64, buf[off..][0..8], .little);

        return .{
            .series_id = series_id,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .num_points = num_points,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .compression = @enumFromInt(compression_raw),
            .page_offset = page_offset,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "chunk_storage: compression and stats" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_chunks_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    var points: std.ArrayList(store.Point) = .{};
    defer points.deinit(ally);

    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        try points.append(ally, .{
            .ts = 1000 + i * 1000,
            .value = 100 + @rem(i, 10),
        });
    }

    try storage.writePoints(42, points.items);

    const stats = storage.getCompressionStats();
    try std.testing.expect(stats.total_chunks == 1);
    try std.testing.expect(stats.ratio < 1.0);
    try std.testing.expect(stats.total_compressed < stats.total_uncompressed);
}

test "chunk_storage: retention" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_retention_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{ .retention_days = 1 });
    defer storage.deinit();

    const current_time: i64 = 1000000000;
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    try storage.writePoints(1, &[_]store.Point{
        .{ .ts = current_time - 2 * day_ms, .value = 1 },
    });

    try storage.writePoints(2, &[_]store.Point{
        .{ .ts = current_time - 1000, .value = 2 },
    });

    try std.testing.expect(storage.chunks.items.len == 2);

    try storage.runRetention(current_time);

    try std.testing.expect(storage.chunks.items.len == 1);
    try std.testing.expect(storage.chunks.items[0].series_id == 2);
}

test "gorilla: encode-decode round-trip" {
    const ally = std.testing.allocator;

    var encoder = try GorillaEncoder.init(ally);
    defer encoder.deinit();

    const input_points = [_]store.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
        .{ .ts = 3000, .value = 150 },
        .{ .ts = 4000, .value = 300 },
        .{ .ts = 5000, .value = -50 },
    };

    for (input_points[0..]) |p| {
        try encoder.encodePoint(p);
    }

    const compressed = try encoder.getCompressedData(ally);
    defer ally.free(compressed);

    var decoder = GorillaDecoder.init(compressed, @intCast(input_points.len));
    const decoded = try decoder.decodeAll(ally);
    defer ally.free(decoded);

    try std.testing.expect(decoded.len == input_points.len);
    for (0..input_points.len) |i| {
        try std.testing.expect(decoded[i].ts == input_points[i].ts);
        try std.testing.expect(decoded[i].value == input_points[i].value);
    }
}

test "gorilla: encode-decode epoch-zero timestamp" {
    const ally = std.testing.allocator;

    var encoder = try GorillaEncoder.init(ally);
    defer encoder.deinit();

    // First point has timestamp=0 (Unix epoch).
    const input_points = [_]store.Point{
        .{ .ts = 0, .value = 42 },
        .{ .ts = 1000, .value = 84 },
        .{ .ts = 2000, .value = 126 },
    };

    for (input_points[0..]) |p| {
        try encoder.encodePoint(p);
    }

    const compressed = try encoder.getCompressedData(ally);
    defer ally.free(compressed);

    var decoder = GorillaDecoder.init(compressed, @intCast(input_points.len));
    const decoded = try decoder.decodeAll(ally);
    defer ally.free(decoded);

    try std.testing.expect(decoded.len == input_points.len);
    for (0..input_points.len) |i| {
        try std.testing.expect(decoded[i].ts == input_points[i].ts);
        try std.testing.expect(decoded[i].value == input_points[i].value);
    }
}

test "chunk_storage: queryRange round-trip" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_query_rt_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // Write 100 points.
    var points: std.ArrayList(store.Point) = .{};
    defer points.deinit(ally);

    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        try points.append(ally, .{
            .ts = 1000 + i * 1000,
            .value = 100 + @rem(i, 10),
        });
    }

    try storage.writePoints(42, points.items);

    // Query for entire range.
    const result = try storage.queryRange(42, 1000, 100000, ally);
    defer ally.free(result);

    try std.testing.expect(result.len == 100);
    for (0..100) |j| {
        try std.testing.expect(result[j].ts == points.items[j].ts);
        try std.testing.expect(result[j].value == points.items[j].value);
    }
}

test "chunk_storage: queryRange partial range" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_query_pr_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    try storage.writePoints(1, &[_]store.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 4000, .value = 40 },
        .{ .ts = 5000, .value = 50 },
    });

    // Query only the middle range [2000, 4000].
    const result = try storage.queryRange(1, 2000, 4000, ally);
    defer ally.free(result);

    try std.testing.expect(result.len == 3);
    try std.testing.expect(result[0].ts == 2000);
    try std.testing.expect(result[1].ts == 3000);
    try std.testing.expect(result[2].ts == 4000);
}

test "chunk_storage: queryRange nonexistent series" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_query_ne_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    const result = try storage.queryRange(999, 0, 100000, ally);
    try std.testing.expect(result.len == 0);
}

test "gorilla: encode-decode large delta values" {
    const ally = std.testing.allocator;

    var encoder = try GorillaEncoder.init(ally);
    defer encoder.deinit();

    // Use varying deltas to exercise all delta-of-delta encoding paths.
    const input_points = [_]store.Point{
        .{ .ts = 0, .value = 0 },
        .{ .ts = 1000, .value = 100 }, // delta=1000, dod=1000 (32-bit path)
        .{ .ts = 2000, .value = 200 }, // delta=1000, dod=0 (zero path)
        .{ .ts = 2050, .value = 250 }, // delta=50, dod=-950 (32-bit path)
        .{ .ts = 2100, .value = 300 }, // delta=50, dod=0 (zero path)
        .{ .ts = 2200, .value = 350 }, // delta=100, dod=50 (7-bit path)
        .{ .ts = 2500, .value = 400 }, // delta=300, dod=200 (9-bit path)
        .{ .ts = 4500, .value = 450 }, // delta=2000, dod=1700 (12-bit path)
    };

    for (input_points[0..]) |p| {
        try encoder.encodePoint(p);
    }

    const compressed = try encoder.getCompressedData(ally);
    defer ally.free(compressed);

    var decoder = GorillaDecoder.init(compressed, @intCast(input_points.len));
    const decoded = try decoder.decodeAll(ally);
    defer ally.free(decoded);

    try std.testing.expect(decoded.len == input_points.len);
    for (0..input_points.len) |j| {
        try std.testing.expect(decoded[j].ts == input_points[j].ts);
        try std.testing.expect(decoded[j].value == input_points[j].value);
    }
}

test "gorilla: encode-decode single point" {
    const ally = std.testing.allocator;

    var encoder = try GorillaEncoder.init(ally);
    defer encoder.deinit();

    try encoder.encodePoint(.{ .ts = 42, .value = -1 });

    const compressed = try encoder.getCompressedData(ally);
    defer ally.free(compressed);

    var decoder = GorillaDecoder.init(compressed, 1);
    const decoded = try decoder.decodeAll(ally);
    defer ally.free(decoded);

    try std.testing.expect(decoded.len == 1);
    try std.testing.expect(decoded[0].ts == 42);
    try std.testing.expect(decoded[0].value == -1);
}

// ============================================================================
// Security: Path traversal rejection (S8/S9/S10)
// ============================================================================

test "chunk_storage: path traversal with .. rejected" {
    const ally = std.testing.allocator;

    const result = ChunkStorage.init(ally, "/tmp/../../../etc/evil", .{});
    try std.testing.expect(result == error.InvalidPath);
}

test "chunk_storage: path traversal with embedded .. rejected" {
    const ally = std.testing.allocator;

    const result = ChunkStorage.init(ally, "/tmp/safe/../../../etc/evil", .{});
    try std.testing.expect(result == error.InvalidPath);
}

test "chunk_storage: valid path accepted" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_valid_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // If we got here, the valid path was accepted.
    try std.testing.expect(storage.data_file != null);
}
