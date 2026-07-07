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

/// Restrictive file permissions for persisted data (POSIX 0o600; default elsewhere).
pub fn securePermissions() std.Io.File.Permissions {
    return if (@import("builtin").os.tag == .windows) .default_file else @enumFromInt(0o600);
}

/// Open an existing persistence file for read-write without following a
/// symlink planted at `name`, creating it exclusively if it does not
/// already exist. `name` is opened RELATIVE to `dir` (a bare filename, no
/// directory separators expected) so that no directory-component symlink
/// can be smuggled in — see `openDataDirNoFollow` for why `dir` itself is
/// guaranteed symlink-free (NEW-4).
///
/// NEW-3: `std.Io.Dir.CreateFileOptions` has no `follow_symlinks` field, and
/// its `.resolve_beneath` option is a silent no-op on Linux (RESOLVE_BENEATH
/// only exists in Darwin/FreeBSD's `posix.O`; Linux's has no such field). A
/// bare `createFile` therefore happily follows a pre-planted symlink at
/// `name` and writes serialized data straight through to whatever file the
/// symlink targets.
///
/// Strategy: try to `openFile` the existing name with `.follow_symlinks =
/// false` first.
///   * If it succeeds, the path was a real (non-symlink) file — use that
///     handle. `openFile` never truncates, so append/no-truncate semantics
///     are preserved exactly as before.
///   * If it fails with `error.FileNotFound`, the name doesn't exist yet —
///     create it with `.exclusive = true` (`O_CREAT | O_EXCL`), which fails
///     loudly (`error.PathAlreadyExists`) if the name already exists as
///     anything, including a symlink, instead of following it.
///   * If the exclusive create loses a concurrent-create race (another process
///     created the file between our `openFile` and `createFile`), it returns
///     `error.PathAlreadyExists`; we retry the no-follow `openFile`, which
///     succeeds on a real file created by the winner, or fails closed
///     (`error.SymLinkLoop`) if the winner planted a symlink.
///   * Any other error (e.g. `error.SymLinkLoop` when the name *is* a
///     symlink) is propagated so the caller fails closed rather than
///     silently writing through an attacker-controlled redirect.
pub fn openOrCreateNoFollow(io: std.Io, dir: std.Io.Dir, name: []const u8) std.Io.File.OpenError!std.Io.File {
    const existing = dir.openFile(io, name, .{
        .mode = .read_write,
        .follow_symlinks = false,
    });
    if (existing) |file| {
        return file;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    return dir.createFile(io, name, .{
        .read = true,
        .exclusive = true,
        .permissions = securePermissions(),
    }) catch |err| switch (err) {
        // Lost a concurrent-create race between the openFile above and this
        // createFile. Reopen no-follow: succeeds on the real file the winner
        // created, or fails closed (SymLinkLoop) if the winner planted a symlink.
        error.PathAlreadyExists => dir.openFile(io, name, .{
            .mode = .read_write,
            .follow_symlinks = false,
        }),
        else => err,
    };
}

/// Resolve `data_dir` to an open, symlink-safe `Dir` handle by walking each
/// path component and opening it with `.follow_symlinks = false`, creating
/// any missing intermediate directories along the way.
///
/// NEW-4: `openOrCreateNoFollow`'s `follow_symlinks = false` (and plain
/// `O_NOFOLLOW` generally) only ever guards the FINAL component of a path
/// passed to `openat`. Every prior slash-separated directory component in a
/// concatenated path string like `"{data_dir}/chunks.dat"` is still
/// transparently dereferenced by the kernel during path resolution. That
/// means:
///   * a symlink planted AT `data_dir` itself (its own leaf component), or
///   * a symlink planted at any ANCESTOR directory of `data_dir`,
/// silently redirects every persistence file into an attacker-chosen
/// directory, even though the leaf filename (`chunks.dat`, etc.) is opened
/// with `follow_symlinks = false`.
///
/// There is no portable `openat2(RESOLVE_NO_SYMLINKS)` exposed by `std.Io`,
/// and `OpenFileOptions.resolve_beneath` is a documented no-op on Linux, so
/// the only way to close this gap is to resolve the directory ourselves,
/// one component at a time: each component is opened with
/// `.follow_symlinks = false` relative to the previous component's
/// already-open (and therefore already-verified-non-symlink) handle. Any
/// component that turns out to be a symlink makes that `openDir` call fail
/// (typically `error.SymLinkLoop`), which is propagated so the caller fails
/// closed instead of following it — this closes both the leaf case and the
/// ancestor case, since every component on the path is individually
/// verified.
///
/// Absolute paths are resolved from the filesystem root; relative paths
/// from the process's current working directory. Callers are expected to
/// have already rejected `..` components (see `ChunkStorage.init`).
fn openDataDirNoFollow(io: std.Io, data_dir: []const u8) !std.Io.Dir {
    const no_follow: std.Io.Dir.OpenOptions = .{ .follow_symlinks = false };
    const is_absolute = std.fs.path.isAbsolute(data_dir);

    var current: std.Io.Dir = if (is_absolute)
        try std.Io.Dir.cwd().openDir(io, "/", no_follow)
    else
        std.Io.Dir.cwd();
    var owns_current = is_absolute;
    errdefer if (owns_current) current.close(io);

    var it = std.mem.tokenizeScalar(u8, data_dir, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;

        const next_dir = current.openDir(io, component, no_follow) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            // Component doesn't exist yet: create it, then open it the same
            // NOFOLLOW way (guards a TOCTOU race where something other than
            // a plain directory appears between the two calls).
            current.createDir(io, component, .default_dir) catch |create_err| switch (create_err) {
                // Benign concurrent-create race (e.g. two processes/threads
                // standing up the same data_dir tree at once): someone else
                // won the create, fall through to the no-follow reopen
                // below. That reopen still fails closed (SymLinkLoop) if
                // what appeared is a planted symlink rather than a real dir.
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            break :blk try current.openDir(io, component, no_follow);
        };

        if (owns_current) current.close(io);
        current = next_dir;
        owns_current = true;
    }

    // Degenerate case (empty/"."-only data_dir): fall back to opening "."
    // explicitly so the returned handle is always a real, closeable fd —
    // never the bare `cwd()` sentinel (AT_FDCWD on POSIX), which must not
    // be passed to `Dir.close`.
    if (!owns_current) {
        current = try std.Io.Dir.cwd().openDir(io, ".", no_follow);
        owns_current = true;
    }

    return current;
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

/// Upper bounds for values read from on-disk metadata (corruption/DoS guard).
const MAX_CHUNK_POINTS: u32 = 1 << 26; // 67M points/chunk ceiling
const MAX_CHUNK_BYTES: u32 = 1 << 30; // 1 GiB compressed/uncompressed ceiling

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
                if (significant_bits == 0 or @as(u16, leading) + @as(u16, significant_bits) > 64) return error.CorruptChunk;
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
        var points: std.ArrayList(store.Point) = .empty;
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
    /// Held open across the storage's lifetime so appendChunkMeta doesn't
    /// have to open/write/close chunk_meta.dat on every writePoints call.
    meta_file: ?std.Io.File,
    /// Running append offset into chunk_meta.dat (avoids an fstat/seek per append).
    meta_offset: u64,
    data_dir: []const u8,
    /// Symlink-safe handle on `data_dir` itself, resolved component-by-
    /// component by `openDataDirNoFollow` (NEW-4). All persistence files
    /// are opened RELATIVE to this handle by bare filename, so no
    /// directory-component symlink (in `data_dir`'s leaf or any ancestor)
    /// can redirect them elsewhere. Held open and closed in `deinit`.
    dir: std.Io.Dir,

    pub const InitError = error{InvalidPath};

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: ChunkConfig) !ChunkStorage {
        // Reject path traversal attempts.
        if (std.mem.indexOf(u8, data_dir, "..") != null) return error.InvalidPath;

        const io = gio();

        var self: ChunkStorage = undefined;
        {
            // NEW-4: resolve data_dir into a symlink-safe Dir handle before
            // anything else. A single `createDirPath` + concatenated-path
            // open (the prior NEW-3 fix) only guards the leaf filename —
            // see `openDataDirNoFollow`'s doc comment for why a component-
            // wise walk is required to also close the directory-component
            // escape.
            var resolved_dir = try openDataDirNoFollow(io, data_dir);
            errdefer resolved_dir.close(io);

            // Own the data_dir string too: constructing `self` here (with
            // both file fields null) gives errdefer a single, always-safe
            // point to take ownership from — zero leak windows for the fds
            // below, and no double-close since deinit() is the only closer
            // on every error path from here on.
            const dir_str = try allocator.dupe(u8, data_dir);

            self = ChunkStorage{
                .allocator = allocator,
                .config = config,
                .chunks = .empty,
                .index = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator),
                .data_file = null,
                .data_offset = 0,
                .meta_file = null,
                .meta_offset = 0,
                .data_dir = dir_str,
                .dir = resolved_dir,
            };
        }
        errdefer self.deinit();

        self.data_file = try openOrCreateNoFollow(io, self.dir, "chunks.dat");

        // Determine current file length so new writes append after existing data.
        self.data_offset = (self.data_file.?).length(io) catch 0;

        self.meta_file = try openOrCreateNoFollow(io, self.dir, "chunk_meta.dat");

        self.meta_offset = (self.meta_file.?).length(io) catch 0;

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
        if (self.meta_file) |file| {
            file.close(gio());
        }
        self.dir.close(gio());
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

        var results: std.ArrayList(store.Point) = .empty;
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

        var new_chunks: std.ArrayList(ChunkMeta) = .empty;

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
                    gop.value_ptr.* = .empty;
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

    /// Append a single ChunkMeta record to the chunk_meta.dat file, via the
    /// handle held open for the lifetime of this ChunkStorage.
    fn appendChunkMeta(self: *ChunkStorage, meta: ChunkMeta) !void {
        const file = self.meta_file orelse return;

        var buf: [chunk_meta_size]u8 = undefined;
        serializeChunkMeta(&buf, meta);
        try file.writePositionalAll(gio(), &buf, self.meta_offset);
        self.meta_offset += chunk_meta_size;
    }

    /// Load all ChunkMeta records from chunk_meta.dat and rebuild the
    /// in-memory index, using the handle held open for this ChunkStorage.
    fn loadChunkMeta(self: *ChunkStorage) !void {
        const file = self.meta_file orelse return;

        var read_off: u64 = 0;
        while (true) {
            var buf: [chunk_meta_size]u8 = undefined;
            const n = file.readPositionalAll(gio(), &buf, read_off) catch break;
            if (n < chunk_meta_size) break;
            read_off += n;

            const meta = try deserializeChunkMeta(&buf);
            const chunk_idx = self.chunks.items.len;
            try self.chunks.append(self.allocator, meta);

            const gop = try self.index.getOrPut(meta.series_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
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

    fn deserializeChunkMeta(buf: *const [chunk_meta_size]u8) error{CorruptMeta}!ChunkMeta {
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

        if (compression_raw >= @typeInfo(CompressionAlgorithm).@"enum".fields.len) return error.CorruptMeta;
        const compression: CompressionAlgorithm = @enumFromInt(compression_raw);

        if (num_points > MAX_CHUNK_POINTS) return error.CorruptMeta;
        if (compressed_size > MAX_CHUNK_BYTES or uncompressed_size > MAX_CHUNK_BYTES) return error.CorruptMeta;

        return .{
            .series_id = series_id,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .num_points = num_points,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .compression = compression,
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
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    var points: std.ArrayList(store.Point) = .empty;
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
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

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
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // Write 100 points.
    var points: std.ArrayList(store.Point) = .empty;
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
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

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
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

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

test "gorilla: malformed new leading/trailing widths rejected" {
    const ally = std.testing.allocator;

    // Hand-crafted bitstream: point 1 is the raw 64+64 header (values
    // don't matter). Point 2 sets first_bit=0 (delta_of_delta=0),
    // xor_control=1, xor_type=1 (new leading/trailing), leading=0 (5 bits),
    // significant_bits=0 (6 bits) -- which would force trailing=64 and
    // panic on the subsequent shift if unguarded.
    var buf = [_]u8{0} ** 18;
    buf[16] = 0x60; // bits: 0 1 1 0 0 0 0 0
    buf[17] = 0x00; // bits: 0 0 0 0 0 0 0 0

    var decoder = GorillaDecoder.init(&buf, 2);
    const result = decoder.decodeAll(ally);
    try std.testing.expectError(error.CorruptChunk, result);
}

test "chunk_storage: deserializeChunkMeta rejects invalid compression tag" {
    var buf: [ChunkStorage.chunk_meta_size]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u64, buf[off..][0..8], 1, .little); // series_id
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
    std.mem.writeInt(u32, buf[off..][0..4], 99, .little); // compression (invalid)
    off += 4;
    std.mem.writeInt(u64, buf[off..][0..8], 0, .little); // page_offset

    const result = ChunkStorage.deserializeChunkMeta(&buf);
    try std.testing.expectError(error.CorruptMeta, result);
}

test "chunk_storage: deserializeChunkMeta rejects oversized num_points" {
    var buf: [ChunkStorage.chunk_meta_size]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u64, buf[off..][0..8], 1, .little); // series_id
    off += 8;
    std.mem.writeInt(i64, buf[off..][0..8], 0, .little); // start_ts
    off += 8;
    std.mem.writeInt(i64, buf[off..][0..8], 0, .little); // end_ts
    off += 8;
    std.mem.writeInt(u32, buf[off..][0..4], 0xFFFFFFFF, .little); // num_points (bogus)
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], 0, .little); // compressed_size
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], 0, .little); // uncompressed_size
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], @intFromEnum(CompressionAlgorithm.gorilla), .little); // compression (valid)
    off += 4;
    std.mem.writeInt(u64, buf[off..][0..8], 0, .little); // page_offset

    const result = ChunkStorage.deserializeChunkMeta(&buf);
    try std.testing.expectError(error.CorruptMeta, result);
}

test "chunk_storage: init leak-free when loadChunkMeta returns error.CorruptMeta" {
    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_init_corrupt_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // Phase 1: write one valid chunk normally.
    {
        var storage = try ChunkStorage.init(ally, test_dir, .{});
        defer storage.deinit();
        try storage.writePoints(1, &[_]store.Point{.{ .ts = 1000, .value = 1 }});
    }

    // Phase 2: append a corrupt trailing record directly to chunk_meta.dat
    // (invalid compression tag), simulating on-disk corruption after the
    // valid record.
    {
        var meta_path_buf: [160]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/chunk_meta.dat", .{test_dir}) catch unreachable;
        const file = try std.Io.Dir.cwd().openFile(io, meta_path, .{ .mode = .read_write });
        defer file.close(io);
        const end_pos = file.length(io) catch 0;

        var buf: [ChunkStorage.chunk_meta_size]u8 = undefined;
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
    // ChunkStorage.init's internal chunks/index/data_dir must all be freed
    // on this error path. This also exercises fd-leak window (a) from the
    // fd-leak fix: by this point both data_file and meta_file are open and
    // errdefer self.deinit() is registered, so loadChunkMeta's failure must
    // close both fds via self.deinit() with no leaks (verified by
    // std.testing.allocator's leak detector) and without crashing on the
    // (fully populated) intermediate state.
    const result = ChunkStorage.init(ally, test_dir, .{});
    try std.testing.expectError(error.CorruptMeta, result);
}

test "chunk_storage: init leak-free when the data_dir allocation fails (fd-leak window b)" {
    // Regression test for the fd-leak fix: ChunkStorage.init now dupes
    // data_dir and constructs `self` (with data_file/meta_file both null)
    // *before* opening either file, so a failure at (or before) that first
    // allocation can never leak an fd — there simply isn't one open yet.
    // Failing allocation index 0 targets exactly that `allocator.dupe(u8,
    // data_dir)` call, the first allocation performed by init.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const ally = failing.allocator();

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_init_oom_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    const result = ChunkStorage.init(ally, test_dir, .{});
    try std.testing.expectError(error.OutOfMemory, result);

    // No file handles were ever opened on this path, so there is nothing
    // for the underlying (non-failing) allocator to have leaked either.
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
}

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
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // If we got here, the valid path was accepted.
    try std.testing.expect(storage.data_file != null);
}

test "chunk_storage: persisted chunks.dat has restrictive 0o600 permissions" {
    // POSIX-only: Windows does not have POSIX mode bits.
    if (@import("builtin").os.tag == .windows) return;

    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_perms_{d}", .{pid}) catch unreachable;
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    var chunks_path_buf: [160]u8 = undefined;
    const chunks_path = std.fmt.bufPrint(&chunks_path_buf, "{s}/chunks.dat", .{test_dir}) catch unreachable;

    const stat = try std.Io.Dir.cwd().statFile(io, chunks_path, .{});
    const mode: u32 = @intFromEnum(stat.permissions);

    // Group/other bits must be clear regardless of umask.
    try std.testing.expect(mode & 0o077 == 0);
    // Owner must retain read/write access.
    try std.testing.expect(mode & 0o600 == 0o600);
}

test "chunk_storage: init does not follow a symlinked chunks.dat (NEW-3)" {
    // POSIX-only: relies on O_NOFOLLOW / O_EXCL semantics for symlinks.
    if (@import("builtin").os.tag == .windows) return;

    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_symlink_chunks_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var victim_path_buf: [160]u8 = undefined;
    const victim_path = std.fmt.bufPrint(&victim_path_buf, "/tmp/ts_test_symlink_chunks_victim_{d}.dat", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteFile(io, victim_path) catch {};

    // Plant a victim file *outside* the data dir with a known marker, then
    // pre-plant a symlink at the would-be chunks.dat path pointing at it —
    // simulating an attacker who controls a low-entropy, /tmp-based
    // data_dir before ChunkStorage.init ever runs.
    {
        const victim = try std.Io.Dir.cwd().createFile(io, victim_path, .{ .read = true, .truncate = true });
        defer victim.close(io);
        try victim.writePositionalAll(io, "MARKER", 0);
    }

    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    var chunks_path_buf: [160]u8 = undefined;
    const chunks_path = std.fmt.bufPrint(&chunks_path_buf, "{s}/chunks.dat", .{test_dir}) catch unreachable;
    try std.Io.Dir.symLinkAbsolute(io, victim_path, chunks_path, .{});

    // init must fail closed (not silently follow the symlink and write
    // through to the victim file) — and must not leak the ChunkStorage's
    // internal allocations on this error path.
    const result = ChunkStorage.init(ally, test_dir, .{});
    try std.testing.expect(std.meta.isError(result));

    // The victim file's content must be completely unchanged.
    const victim = try std.Io.Dir.cwd().openFile(io, victim_path, .{});
    defer victim.close(io);
    var read_buf: [64]u8 = undefined;
    const n = try victim.readPositionalAll(io, &read_buf, 0);
    try std.testing.expectEqualStrings("MARKER", read_buf[0..n]);
}

test "chunk_storage: init does not follow a symlinked chunk_meta.dat (NEW-3)" {
    // POSIX-only: relies on O_NOFOLLOW / O_EXCL semantics for symlinks.
    if (@import("builtin").os.tag == .windows) return;

    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_symlink_meta_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var victim_path_buf: [160]u8 = undefined;
    const victim_path = std.fmt.bufPrint(&victim_path_buf, "/tmp/ts_test_symlink_meta_victim_{d}.dat", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteFile(io, victim_path) catch {};

    // Plant a victim file *outside* the data dir with a known marker, then
    // pre-plant a symlink at the would-be chunk_meta.dat path pointing at
    // it. chunks.dat itself is left untouched so it opens/creates normally,
    // isolating the regression to the chunk_meta.dat write path.
    {
        const victim = try std.Io.Dir.cwd().createFile(io, victim_path, .{ .read = true, .truncate = true });
        defer victim.close(io);
        try victim.writePositionalAll(io, "MARKER", 0);
    }

    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    var meta_path_buf: [160]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/chunk_meta.dat", .{test_dir}) catch unreachable;
    try std.Io.Dir.symLinkAbsolute(io, victim_path, meta_path, .{});

    // init must fail closed and must not leak the ChunkStorage's internal
    // allocations (including the already-opened chunks.dat fd) on this
    // error path.
    const result = ChunkStorage.init(ally, test_dir, .{});
    try std.testing.expect(std.meta.isError(result));

    // The victim file's content must be completely unchanged.
    const victim = try std.Io.Dir.cwd().openFile(io, victim_path, .{});
    defer victim.close(io);
    var read_buf: [64]u8 = undefined;
    const n = try victim.readPositionalAll(io, &read_buf, 0);
    try std.testing.expectEqualStrings("MARKER", read_buf[0..n]);
}

test "chunk_storage: init does not follow a symlinked data_dir leaf directory (NEW-4 PoC1)" {
    // POSIX-only: relies on O_NOFOLLOW semantics for symlinked directories.
    if (@import("builtin").os.tag == .windows) return;

    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var victim_buf: [128]u8 = undefined;
    const victim_dir = std.fmt.bufPrint(&victim_buf, "/tmp/ts_test_new4_poc1_victim_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, victim_dir) catch {};

    var data_dir_buf: [128]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&data_dir_buf, "/tmp/ts_test_new4_poc1_link_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteFile(io, data_dir) catch {};

    // Plant a real victim directory *outside* the would-be data_dir, with a
    // marker file inside it, then make `data_dir` itself a symlink pointing
    // at the victim — simulating an attacker who controls a low-entropy,
    // /tmp-based data_dir path (its own leaf component) before
    // ChunkStorage.init ever runs.
    try std.Io.Dir.cwd().createDirPath(io, victim_dir);
    var marker_path_buf: [160]u8 = undefined;
    const marker_path = std.fmt.bufPrint(&marker_path_buf, "{s}/marker.txt", .{victim_dir}) catch unreachable;
    {
        const marker = try std.Io.Dir.cwd().createFile(io, marker_path, .{ .read = true, .truncate = true });
        defer marker.close(io);
        try marker.writePositionalAll(io, "MARKER", 0);
    }

    try std.Io.Dir.symLinkAbsolute(io, victim_dir, data_dir, .{ .is_directory = true });

    // init must fail closed (not silently follow the symlinked data_dir and
    // write chunks.dat/chunk_meta.dat through to the victim directory) —
    // and must not leak the ChunkStorage's internal allocations on this
    // error path.
    const result = ChunkStorage.init(ally, data_dir, .{});
    try std.testing.expect(std.meta.isError(result));

    // The victim directory must not have gained either persistence file.
    var chunks_victim_buf: [192]u8 = undefined;
    const chunks_in_victim = std.fmt.bufPrint(&chunks_victim_buf, "{s}/chunks.dat", .{victim_dir}) catch unreachable;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, chunks_in_victim, .{}));

    var meta_victim_buf: [192]u8 = undefined;
    const meta_in_victim = std.fmt.bufPrint(&meta_victim_buf, "{s}/chunk_meta.dat", .{victim_dir}) catch unreachable;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, meta_in_victim, .{}));

    // The marker file's content must be completely unchanged.
    const marker = try std.Io.Dir.cwd().openFile(io, marker_path, .{});
    defer marker.close(io);
    var read_buf: [64]u8 = undefined;
    const n = try marker.readPositionalAll(io, &read_buf, 0);
    try std.testing.expectEqualStrings("MARKER", read_buf[0..n]);
}

test "chunk_storage: init does not follow a symlinked ancestor directory component (NEW-4 PoC2)" {
    // POSIX-only: relies on O_NOFOLLOW semantics for symlinked directories.
    if (@import("builtin").os.tag == .windows) return;

    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var victim_buf: [128]u8 = undefined;
    const victim_dir = std.fmt.bufPrint(&victim_buf, "/tmp/ts_test_new4_poc2_victim_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, victim_dir) catch {};

    var attacker_link_buf: [128]u8 = undefined;
    const attacker_link = std.fmt.bufPrint(&attacker_link_buf, "/tmp/ts_test_new4_poc2_attacker_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteFile(io, attacker_link) catch {};

    // Plant a real victim directory with a marker file inside it, then make
    // an ANCESTOR path component of `data_dir` (not the leaf) a symlink
    // pointing at the victim. `data_dir` = "<attacker_link>/sub" — the
    // ancestor "attacker_link" component is the symlink; "sub" itself never
    // exists anywhere real.
    try std.Io.Dir.cwd().createDirPath(io, victim_dir);
    var marker_path_buf: [160]u8 = undefined;
    const marker_path = std.fmt.bufPrint(&marker_path_buf, "{s}/marker.txt", .{victim_dir}) catch unreachable;
    {
        const marker = try std.Io.Dir.cwd().createFile(io, marker_path, .{ .read = true, .truncate = true });
        defer marker.close(io);
        try marker.writePositionalAll(io, "MARKER", 0);
    }

    try std.Io.Dir.symLinkAbsolute(io, victim_dir, attacker_link, .{ .is_directory = true });

    var data_dir_buf: [160]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&data_dir_buf, "{s}/sub", .{attacker_link}) catch unreachable;

    // init must fail closed — the component walk must reject the
    // symlinked ancestor before ever reaching "sub", so no persistence
    // files (nor a "sub" subdirectory) should appear anywhere under the
    // victim directory.
    const result = ChunkStorage.init(ally, data_dir, .{});
    try std.testing.expect(std.meta.isError(result));

    var sub_victim_buf: [192]u8 = undefined;
    const sub_in_victim = std.fmt.bufPrint(&sub_victim_buf, "{s}/sub", .{victim_dir}) catch unreachable;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, sub_in_victim, .{}));

    var chunks_victim_buf: [192]u8 = undefined;
    const chunks_in_victim = std.fmt.bufPrint(&chunks_victim_buf, "{s}/chunks.dat", .{victim_dir}) catch unreachable;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, chunks_in_victim, .{}));

    // The marker file's content must be completely unchanged.
    const marker = try std.Io.Dir.cwd().openFile(io, marker_path, .{});
    defer marker.close(io);
    var read_buf: [64]u8 = undefined;
    const n = try marker.readPositionalAll(io, &read_buf, 0);
    try std.testing.expectEqualStrings("MARKER", read_buf[0..n]);
}

test "chunk_storage: init creates nested missing directory components and round-trips across restart (NEW-4 regression)" {
    // Exercises the multi-component walk in openDataDirNoFollow (nested
    // makeDir) end-to-end, with NO symlinks involved: `data_dir` has two
    // levels that do not exist yet ("<root>/nested/sub"), matching how
    // Store.initWithConfig always appends "/timeseries" onto the caller's
    // data_dir. Also verifies that a second `init` against the
    // already-created directory (the process-restart case) still succeeds
    // and finds the previously written data.
    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var root_buf: [96]u8 = undefined;
    const root_dir = std.fmt.bufPrint(&root_buf, "/tmp/ts_test_new4_nested_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, root_dir) catch {};

    var data_dir_buf: [128]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&data_dir_buf, "{s}/nested/sub", .{root_dir}) catch unreachable;

    var points: std.ArrayList(store.Point) = .empty;
    defer points.deinit(ally);
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try points.append(ally, .{ .ts = 1000 + i * 1000, .value = 10 + i });
    }

    {
        var storage = try ChunkStorage.init(ally, data_dir, .{});
        defer storage.deinit();

        try std.testing.expect(storage.data_file != null);
        try std.testing.expect(storage.meta_file != null);

        try storage.writePoints(7, points.items);
    }

    // Re-init against the now-existing (real, non-symlinked) nested
    // directory must succeed and must still see the persisted data.
    {
        var storage = try ChunkStorage.init(ally, data_dir, .{});
        defer storage.deinit();

        const result = try storage.queryRange(7, 1000, 100000, ally);
        defer ally.free(result);

        try std.testing.expectEqual(@as(usize, 10), result.len);
        for (0..10) |j| {
            try std.testing.expectEqual(points.items[j].ts, result[j].ts);
            try std.testing.expectEqual(points.items[j].value, result[j].value);
        }
    }
}

test "chunk_storage: init succeeds when the entire data_dir tree already exists (concurrent-createDir robustness)" {
    // Every component of data_dir is created ahead of time (simulating the
    // "someone else already created it" outcome of a concurrent-create
    // race), so openDataDirNoFollow's walk finds every component via a
    // plain openDir and never needs to create anything. Proves the
    // already-exists path works end to end through ChunkStorage.init.
    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var root_buf: [96]u8 = undefined;
    const root_dir = std.fmt.bufPrint(&root_buf, "/tmp/ts_test_concurrent_predug_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, root_dir) catch {};

    var data_dir_buf: [128]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&data_dir_buf, "{s}/nested/sub", .{root_dir}) catch unreachable;

    // Pre-create every path component before init ever runs.
    try std.Io.Dir.cwd().createDirPath(io, data_dir);

    var storage = try ChunkStorage.init(ally, data_dir, .{});
    defer storage.deinit();

    try std.testing.expect(storage.data_file != null);
    try std.testing.expect(storage.meta_file != null);
}

test "chunk_storage: openOrCreateNoFollow reopens an existing real file instead of failing (concurrent file-create robustness)" {
    // openOrCreateNoFollow's exclusive-create can lose a race to a concurrent
    // creator and return error.PathAlreadyExists; the fix reopens the file
    // no-follow. This test exercises that reopen path directly: a first call
    // creates the file, and a second call for the same name must reopen the
    // real file (not fail, and not follow a symlink). Data written through the
    // first handle must be visible through the second.
    if (@import("builtin").os.tag == .windows) return;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var root_buf: [96]u8 = undefined;
    const root_dir = std.fmt.bufPrint(&root_buf, "/tmp/ts_test_reopen_race_{d}", .{pid}) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(io, root_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root_dir) catch {};

    var dir = try std.Io.Dir.cwd().openDir(io, root_dir, .{ .follow_symlinks = false });
    defer dir.close(io);

    // First call creates the file exclusively.
    var f1 = try openOrCreateNoFollow(io, dir, "race.dat");
    const payload = "concurrent-reopen-marker";
    try f1.writePositionalAll(io, payload, 0);
    f1.close(io);

    // Second call must reopen the same real file (the exact path the
    // PathAlreadyExists branch takes after losing the create race).
    var f2 = try openOrCreateNoFollow(io, dir, "race.dat");
    defer f2.close(io);
    var read_buf: [64]u8 = undefined;
    const n = try f2.readPositionalAll(io, read_buf[0..payload.len], 0);
    try std.testing.expectEqual(payload.len, n);
    try std.testing.expectEqualStrings(payload, read_buf[0..payload.len]);
}

test "chunk_storage: init succeeds when an intermediate component is created out-of-band (concurrent-createDir robustness)" {
    // Only the FIRST intermediate component ("nested") is pre-created by a
    // separate actor before init runs; the second ("sub") still needs to be
    // created by openDataDirNoFollow's own walk. Proves partial concurrent
    // creation (a plausible real-world interleaving) doesn't trip up the
    // walk either.
    const ally = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const pid = std.os.linux.getpid();
    var root_buf: [96]u8 = undefined;
    const root_dir = std.fmt.bufPrint(&root_buf, "/tmp/ts_test_concurrent_partial_{d}", .{pid}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, root_dir) catch {};

    var nested_buf: [128]u8 = undefined;
    const nested_dir = std.fmt.bufPrint(&nested_buf, "{s}/nested", .{root_dir}) catch unreachable;
    // Create the intermediate component "out-of-band", as a real directory,
    // before init ever sees the path.
    try std.Io.Dir.cwd().createDirPath(io, nested_dir);

    var data_dir_buf: [128]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&data_dir_buf, "{s}/sub", .{nested_dir}) catch unreachable;

    var storage = try ChunkStorage.init(ally, data_dir, .{});
    defer storage.deinit();

    try std.testing.expect(storage.data_file != null);
    try std.testing.expect(storage.meta_file != null);
}

test "chunk_storage: openDataDirNoFollow tolerates concurrent creation of the same directory component (concurrent-createDir robustness)" {
    // Directly races two real OS threads against openDataDirNoFollow (the
    // function actually fixed) on a freshly-created path, isolated from
    // ChunkStorage.init's separate chunks.dat/chunk_meta.dat creation (a
    // different code path with its own, out-of-scope race handling). Both
    // threads target the exact same not-yet-existing nested component, so
    // one of them is expected to observe the other's createDir having won
    // (error.PathAlreadyExists) and must recover by reopening no-follow
    // instead of failing init spuriously. Repeated over several trials
    // against fresh directories to make the race window likely to be hit.
    const io = std.Io.Threaded.global_single_threaded.io();
    const pid = std.os.linux.getpid();

    // A tiny spin-barrier so both threads enter openDataDirNoFollow as close
    // to simultaneously as possible, maximizing the odds of both observing
    // the final ("sub") component as FileNotFound before either wins the
    // create -- the exact TOCTOU window the fix targets.
    const Ctx = struct {
        io: std.Io,
        data_dir: []const u8,
        ready: *std.atomic.Value(u32),
        go: *std.atomic.Value(bool),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) {
                std.atomic.spinLoopHint();
            }
            var dir = openDataDirNoFollow(self.io, self.data_dir) catch |e| {
                self.err = e;
                return;
            };
            dir.close(self.io);
        }
    };

    var trial: usize = 0;
    while (trial < 20) : (trial += 1) {
        var root_buf: [96]u8 = undefined;
        const root_dir = std.fmt.bufPrint(&root_buf, "/tmp/ts_test_concurrent_race_{d}_{d}", .{ pid, trial }) catch unreachable;
        defer std.Io.Dir.cwd().deleteTree(io, root_dir) catch {};

        var nested_buf: [128]u8 = undefined;
        const nested_dir = std.fmt.bufPrint(&nested_buf, "{s}/nested", .{root_dir}) catch unreachable;
        // Pre-create every component except the final one, so both threads
        // race on creating exactly the same (final) missing component
        // rather than potentially desyncing across multiple levels.
        try std.Io.Dir.cwd().createDirPath(io, nested_dir);

        var data_dir_buf: [128]u8 = undefined;
        const data_dir = std.fmt.bufPrint(&data_dir_buf, "{s}/sub", .{nested_dir}) catch unreachable;

        var ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        var go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        var ctx_a: Ctx = .{ .io = io, .data_dir = data_dir, .ready = &ready, .go = &go };
        var ctx_b: Ctx = .{ .io = io, .data_dir = data_dir, .ready = &ready, .go = &go };

        const t_a = try std.Thread.spawn(.{}, Ctx.run, .{&ctx_a});
        const t_b = try std.Thread.spawn(.{}, Ctx.run, .{&ctx_b});

        while (ready.load(.acquire) < 2) {
            std.atomic.spinLoopHint();
        }
        go.store(true, .release);

        t_a.join();
        t_b.join();

        if (ctx_a.err) |e| {
            std.debug.print("trial {d}: thread A failed: {s}\n", .{ trial, @errorName(e) });
            return e;
        }
        if (ctx_b.err) |e| {
            std.debug.print("trial {d}: thread B failed: {s}\n", .{ trial, @errorName(e) });
            return e;
        }
    }
}
