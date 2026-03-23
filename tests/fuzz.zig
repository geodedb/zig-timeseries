// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Fuzz and property-based tests for the timeseries library.
//!
//! Uses std.testing.fuzz for coverage-guided fuzzing when built with
//! --fuzz, and falls back to corpus + empty-input smoke tests during
//! normal `zig build test` runs.
//!
//! Additionally includes deterministic property-based tests driven by
//! a seeded PRNG that verify mathematical invariants across random inputs.
//!
//! Run with: `zig build fuzz --summary all`

const std = @import("std");
const ts = @import("timeseries");

const allocator = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A pair of f64 slices produced from raw fuzz bytes.
const F64Pair = struct {
    a: []const f64,
    b: []const f64,

    fn deinit(self: F64Pair) void {
        allocator.free(self.a);
        allocator.free(self.b);
    }
};

/// Convert raw fuzz bytes into a pair of f64 slices.
/// Returns null if input is too short (need at least 16 bytes for one f64 pair).
fn bytesToF64Pair(input: []const u8) ?F64Pair {
    // Each f64 is 8 bytes. We split input in half to form two arrays.
    const f64_size = @sizeOf(f64);
    if (input.len < f64_size * 2) return null;

    // Ensure alignment by computing element counts per half.
    const half = input.len / 2;
    const n_a = half / f64_size;
    const n_b = (input.len - half) / f64_size;
    if (n_a == 0 or n_b == 0) return null;

    const a_bytes = input[0 .. n_a * f64_size];
    const b_bytes = input[half .. half + n_b * f64_size];

    // Make aligned copies from the raw byte input.
    const a_copy = allocator.alloc(f64, n_a) catch return null;
    const b_copy = allocator.alloc(f64, n_b) catch return null;

    for (0..n_a) |i| {
        a_copy[i] = @bitCast(a_bytes[i * f64_size ..][0..f64_size].*);
    }
    for (0..n_b) |i| {
        b_copy[i] = @bitCast(b_bytes[i * f64_size ..][0..f64_size].*);
    }

    return .{ .a = a_copy, .b = b_copy };
}

/// Check if a value is finite (not NaN or Inf).
fn isFinite(v: f64) bool {
    return !std.math.isNan(v) and !std.math.isInf(v);
}

/// Check if all values in a slice are finite.
fn allFinite(values: []const f64) bool {
    for (values) |v| {
        if (!isFinite(v)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Fuzz tests using std.testing.fuzz
// ---------------------------------------------------------------------------

test "fuzz: constrainedDTW" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            const pair = bytesToF64Pair(input) orelse return;
            defer pair.deinit();

            // Cap sizes to avoid excessive runtime in fuzz mode.
            const n: usize = @min(pair.a.len, 50);
            const m: usize = @min(pair.b.len, 50);
            if (n == 0 or m == 0) return;

            // Skip inputs containing NaN/Inf since the library rejects them.
            const a_slice = pair.a[0..n];
            const b_slice = pair.b[0..m];
            if (!allFinite(a_slice) or !allFinite(b_slice)) return;

            const result = ts.dtw.constrainedDTW(
                allocator,
                a_slice,
                b_slice,
                @max(n, m),
            ) catch return; // allocation failure is acceptable

            defer result.deinit(allocator);

            // Distance must be non-negative.
            try std.testing.expect(result.distance >= 0);
            // Path length must be positive.
            try std.testing.expect(result.path.len > 0);
        }
    }.testOne, .{});
}

test "fuzz: crossCorrelate" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            const pair = bytesToF64Pair(input) orelse return;
            defer pair.deinit();

            const n: usize = @min(pair.a.len, 50);
            const m: usize = @min(pair.b.len, 50);
            if (n == 0 or m == 0) return;

            const a_slice = pair.a[0..n];
            const b_slice = pair.b[0..m];
            if (!allFinite(a_slice) or !allFinite(b_slice)) return;

            const result = ts.distances.crossCorrelate(a_slice, b_slice) catch return;

            // Correlation should be a finite number.
            try std.testing.expect(isFinite(result.correlation));
        }
    }.testOne, .{});
}

test "fuzz: pelt" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            const f64_size = @sizeOf(f64);
            const n = @min(input.len / f64_size, 100);
            if (n == 0) return;

            const data = allocator.alloc(f64, n) catch return;
            defer allocator.free(data);
            for (0..n) |i| {
                data[i] = @bitCast(input[i * f64_size ..][0..f64_size].*);
            }

            if (!allFinite(data)) return;

            const cps = ts.pelt.pelt(allocator, data, 5.0, 2) catch return;
            defer allocator.free(cps);

            // Change points should have valid indices (< n).
            for (cps) |cp| {
                try std.testing.expect(cp < n);
            }
        }
    }.testOne, .{});
}

// ---------------------------------------------------------------------------
// Deterministic property-based tests with seeded PRNG
// ---------------------------------------------------------------------------

/// Generate a random f64 array with values in [-10, 10].
fn randomF64Array(rand: std.Random, n: usize) []f64 {
    const data = allocator.alloc(f64, n) catch @panic("alloc failed");
    for (data) |*v| {
        v.* = rand.float(f64) * 20.0 - 10.0;
    }
    return data;
}

test "property: DTW symmetry" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 50);
        const m = rand.intRangeAtMost(usize, 2, 50);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);
        const b = randomF64Array(rand, m);
        defer allocator.free(b);

        const band: usize = @max(n, m);

        const result_ab = ts.dtw.constrainedDTW(allocator, a, b, band) catch continue;
        defer result_ab.deinit(allocator);
        const result_ba = ts.dtw.constrainedDTW(allocator, b, a, band) catch continue;
        defer result_ba.deinit(allocator);

        try std.testing.expectApproxEqAbs(result_ab.distance, result_ba.distance, 1e-10);
    }
}

test "property: DTW non-negativity" {
    var prng = std.Random.DefaultPrng.init(123);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 50);
        const m = rand.intRangeAtMost(usize, 2, 50);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);
        const b = randomF64Array(rand, m);
        defer allocator.free(b);

        const result = ts.dtw.constrainedDTW(allocator, a, b, @max(n, m)) catch continue;
        defer result.deinit(allocator);

        try std.testing.expect(result.distance >= 0);
    }
}

test "property: DTW identity" {
    var prng = std.Random.DefaultPrng.init(456);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 50);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);

        const result = ts.dtw.constrainedDTW(allocator, a, a, n) catch continue;
        defer result.deinit(allocator);

        try std.testing.expectApproxEqAbs(result.distance, 0.0, 1e-10);
    }
}

test "property: LB_Keogh <= DTW" {
    var prng = std.Random.DefaultPrng.init(789);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 30);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);
        const b = randomF64Array(rand, n);
        defer allocator.free(b);

        const band: usize = @max(1, n / 3);

        const lb = ts.dtw.lbKeogh(a, b, band);

        const result = ts.dtw.constrainedDTW(allocator, a, b, band) catch continue;
        defer result.deinit(allocator);

        // LB_Keogh must be a lower bound on DTW.
        try std.testing.expect(lb <= result.distance + 1e-10);
    }
}

test "property: ERP triangle inequality" {
    var prng = std.Random.DefaultPrng.init(1001);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 30);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);
        const b = randomF64Array(rand, n);
        defer allocator.free(b);
        const c = randomF64Array(rand, n);
        defer allocator.free(c);

        const dist_ab = ts.distances.erp(allocator, a, b, 0.0) catch continue;
        const dist_bc = ts.distances.erp(allocator, b, c, 0.0) catch continue;
        const dist_ac = ts.distances.erp(allocator, a, c, 0.0) catch continue;

        // Triangle inequality: d(a,c) <= d(a,b) + d(b,c)
        try std.testing.expect(dist_ac <= dist_ab + dist_bc + 1e-10);
    }
}

test "property: distance symmetry (crossCorrelate)" {
    var prng = std.Random.DefaultPrng.init(2002);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 30);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);
        const b = randomF64Array(rand, n);
        defer allocator.free(b);

        const r_ab = ts.distances.crossCorrelate(a, b) catch continue;
        const r_ba = ts.distances.crossCorrelate(b, a) catch continue;

        // Cross-correlation value should be the same (but lag may be negated).
        try std.testing.expectApproxEqAbs(r_ab.correlation, r_ba.correlation, 1e-10);
    }
}

test "property: PELT no crash on random data" {
    var prng = std.Random.DefaultPrng.init(3003);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 1, 100);
        const data = randomF64Array(rand, n);
        defer allocator.free(data);

        const cps = ts.pelt.pelt(allocator, data, 5.0, 2) catch continue;
        defer allocator.free(cps);

        // All change points must be valid indices (< n).
        for (cps) |cp| {
            try std.testing.expect(cp < n);
        }
    }
}
