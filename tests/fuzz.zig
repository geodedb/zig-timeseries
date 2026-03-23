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
            if (!allFinite(pair.a[0..n]) or !allFinite(pair.b[0..m])) return;

            var dist: f64 = undefined;
            const path_len = n + m;
            const pi = allocator.alloc(i32, path_len) catch return;
            defer allocator.free(pi);
            const pj = allocator.alloc(i32, path_len) catch return;
            defer allocator.free(pj);
            var plen: i32 = undefined;

            const rc = ts.dtw.constrainedDTW(
                allocator,
                pair.a.ptr,
                @intCast(n),
                pair.b.ptr,
                @intCast(m),
                @intCast(@max(n, m)),
                &dist,
                pi.ptr,
                pj.ptr,
                &plen,
            );

            // Must either succeed or return -1 (allocation failure).
            try std.testing.expect(rc == 0 or rc == -1);

            if (rc == 0) {
                // Distance must be non-negative.
                try std.testing.expect(dist >= 0);
                // Path length must be positive.
                try std.testing.expect(plen > 0);
            }
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

            if (!allFinite(pair.a[0..n]) or !allFinite(pair.b[0..m])) return;

            var lag: i32 = undefined;
            var corr: f64 = undefined;

            const rc = ts.distances.crossCorrelate(
                pair.a.ptr,
                @intCast(n),
                pair.b.ptr,
                @intCast(m),
                &lag,
                &corr,
            );

            try std.testing.expect(rc == 0 or rc == -1);

            if (rc == 0) {
                // Correlation should be a finite number.
                try std.testing.expect(isFinite(corr));
            }
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

            const cps = allocator.alloc(i32, n) catch return;
            defer allocator.free(cps);
            var cps_len: i32 = undefined;

            const rc = ts.pelt.pelt(
                allocator,
                data.ptr,
                @intCast(n),
                5.0,
                2,
                cps.ptr,
                &cps_len,
            );

            try std.testing.expect(rc == 0 or rc == -1);

            if (rc == 0) {
                // Change point count must be non-negative.
                try std.testing.expect(cps_len >= 0);
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

        const path_cap = n + m;
        const pi = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pi);
        const pj = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pj);
        const pi2 = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pi2);
        const pj2 = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pj2);

        var dist_ab: f64 = undefined;
        var plen_ab: i32 = undefined;
        var dist_ba: f64 = undefined;
        var plen_ba: i32 = undefined;

        const band: i32 = @intCast(@max(n, m));

        const rc1 = ts.dtw.constrainedDTW(
            allocator,
            a.ptr,
            @intCast(n),
            b.ptr,
            @intCast(m),
            band,
            &dist_ab,
            pi.ptr,
            pj.ptr,
            &plen_ab,
        );
        const rc2 = ts.dtw.constrainedDTW(
            allocator,
            b.ptr,
            @intCast(m),
            a.ptr,
            @intCast(n),
            band,
            &dist_ba,
            pi2.ptr,
            pj2.ptr,
            &plen_ba,
        );

        if (rc1 == 0 and rc2 == 0) {
            try std.testing.expectApproxEqAbs(dist_ab, dist_ba, 1e-10);
        }
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

        const path_cap = n + m;
        const pi = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pi);
        const pj = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pj);

        var dist: f64 = undefined;
        var plen: i32 = undefined;

        const rc = ts.dtw.constrainedDTW(
            allocator,
            a.ptr,
            @intCast(n),
            b.ptr,
            @intCast(m),
            @intCast(@max(n, m)),
            &dist,
            pi.ptr,
            pj.ptr,
            &plen,
        );

        if (rc == 0) {
            try std.testing.expect(dist >= 0);
        }
    }
}

test "property: DTW identity" {
    var prng = std.Random.DefaultPrng.init(456);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 2, 50);
        const a = randomF64Array(rand, n);
        defer allocator.free(a);

        const path_cap = n * 2;
        const pi = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pi);
        const pj = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pj);

        var dist: f64 = undefined;
        var plen: i32 = undefined;

        const rc = ts.dtw.constrainedDTW(
            allocator,
            a.ptr,
            @intCast(n),
            a.ptr,
            @intCast(n),
            @intCast(n),
            &dist,
            pi.ptr,
            pj.ptr,
            &plen,
        );

        if (rc == 0) {
            try std.testing.expectApproxEqAbs(dist, 0.0, 1e-10);
        }
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

        const band: i32 = @intCast(@max(1, n / 3));

        const lb = ts.dtw.lbKeogh(a.ptr, @intCast(n), b.ptr, @intCast(n), band);

        const path_cap = n * 2;
        const pi = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pi);
        const pj = allocator.alloc(i32, path_cap) catch continue;
        defer allocator.free(pj);

        var dtw_dist: f64 = undefined;
        var plen: i32 = undefined;

        const rc = ts.dtw.constrainedDTW(
            allocator,
            a.ptr,
            @intCast(n),
            b.ptr,
            @intCast(n),
            band,
            &dtw_dist,
            pi.ptr,
            pj.ptr,
            &plen,
        );

        if (rc == 0) {
            // LB_Keogh must be a lower bound on DTW.
            try std.testing.expect(lb <= dtw_dist + 1e-10);
        }
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

        var dist_ab: f64 = undefined;
        var dist_bc: f64 = undefined;
        var dist_ac: f64 = undefined;

        const r1 = ts.distances.erp(allocator, a.ptr, @intCast(n), b.ptr, @intCast(n), 0.0, &dist_ab);
        const r2 = ts.distances.erp(allocator, b.ptr, @intCast(n), c.ptr, @intCast(n), 0.0, &dist_bc);
        const r3 = ts.distances.erp(allocator, a.ptr, @intCast(n), c.ptr, @intCast(n), 0.0, &dist_ac);

        if (r1 == 0 and r2 == 0 and r3 == 0) {
            // Triangle inequality: d(a,c) <= d(a,b) + d(b,c)
            try std.testing.expect(dist_ac <= dist_ab + dist_bc + 1e-10);
        }
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

        var lag_ab: i32 = undefined;
        var corr_ab: f64 = undefined;
        var lag_ba: i32 = undefined;
        var corr_ba: f64 = undefined;

        const r1 = ts.distances.crossCorrelate(a.ptr, @intCast(n), b.ptr, @intCast(n), &lag_ab, &corr_ab);
        const r2 = ts.distances.crossCorrelate(b.ptr, @intCast(n), a.ptr, @intCast(n), &lag_ba, &corr_ba);

        if (r1 == 0 and r2 == 0) {
            // Cross-correlation value should be the same (but lag may be negated).
            try std.testing.expectApproxEqAbs(corr_ab, corr_ba, 1e-10);
        }
    }
}

test "property: PELT no crash on random data" {
    var prng = std.Random.DefaultPrng.init(3003);
    const rand = prng.random();

    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 1, 100);
        const data = randomF64Array(rand, n);
        defer allocator.free(data);

        const cps = allocator.alloc(i32, n) catch continue;
        defer allocator.free(cps);
        var cps_len: i32 = undefined;

        const rc = ts.pelt.pelt(
            allocator,
            data.ptr,
            @intCast(n),
            5.0,
            2,
            cps.ptr,
            &cps_len,
        );

        // Must succeed (0) or cleanly fail (-1); never crash.
        try std.testing.expect(rc == 0 or rc == -1);

        if (rc == 0) {
            try std.testing.expect(cps_len >= 0);
        }
    }
}
