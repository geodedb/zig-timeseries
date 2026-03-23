// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const distances = @import("distances.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

// ============================================================================
// Cross-Correlation
// ============================================================================

test "cross-correlate: identical series -> lag 0, correlation 1" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const result = try distances.crossCorrelate(&a, &a);
    try expect(result.lag == 0);
    try expectApprox(result.correlation, 1.0, 1e-10);
}

test "cross-correlate: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = distances.crossCorrelate(empty, &a);
    try expect(result == error.InvalidInput);
}

test "cross-correlate: shifted series detects lag" {
    const a = [_]f64{ 0, 0, 1, 2, 3, 4, 5, 0, 0 };
    const b = [_]f64{ 0, 0, 0, 0, 1, 2, 3, 4, 5 };

    const result = try distances.crossCorrelate(&a, &b);
    try expect(result.correlation > 0.8);
}

// ============================================================================
// Cross-Correlation: FFT path (inputs >= 64 elements)
// ============================================================================

test "cross-correlate FFT: identical large series -> lag 0, correlation 1" {
    var a: [128]f64 = undefined;
    for (0..128) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 2.0;
    }

    const result = try distances.crossCorrelate(&a, &a);
    try expect(result.lag == 0);
    try expectApprox(result.correlation, 1.0, 1e-8);
}

test "cross-correlate FFT: shifted large series detects lag" {
    var a: [100]f64 = undefined;
    var b: [100]f64 = undefined;
    const shift: usize = 5;

    for (0..100) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.2);
    }
    for (0..100) |i| {
        if (i >= shift) {
            b[i] = a[i - shift];
        } else {
            b[i] = 0;
        }
    }

    const result = try distances.crossCorrelate(&a, &b);
    try expect(result.correlation > 0.5);
}

test "cross-correlate FFT: symmetry for large series" {
    var a: [80]f64 = undefined;
    var b: [80]f64 = undefined;
    for (0..80) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.15);
        b[i] = @cos(@as(f64, @floatFromInt(i)) * 0.15);
    }

    const r_ab = try distances.crossCorrelate(&a, &b);
    const r_ba = try distances.crossCorrelate(&b, &a);
    try expectApprox(r_ab.correlation, r_ba.correlation, 1e-8);
}

test "cross-correlate FFT: brute-force vs FFT agreement at boundary" {
    var data: [65]f64 = undefined;
    for (0..65) |i| {
        data[i] = @as(f64, @floatFromInt(i)) * 0.5 + 1.0;
    }

    const bf_slice: []const f64 = data[0..63];
    const fft_slice: []const f64 = &data;

    const r_bf = try distances.crossCorrelate(bf_slice, bf_slice);
    const r_fft = try distances.crossCorrelate(fft_slice, fft_slice);

    try expect(r_bf.lag == 0);
    try expect(r_fft.lag == 0);
    try expectApprox(r_bf.correlation, 1.0, 1e-8);
    try expectApprox(r_fft.correlation, 1.0, 1e-8);
}

test "cross-correlate FFT: different length series" {
    var a: [70]f64 = undefined;
    var b: [90]f64 = undefined;
    for (0..70) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 3.0;
    }
    for (0..90) |i| {
        b[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 3.0;
    }

    const result = try distances.crossCorrelate(&a, &b);
    try expect(result.correlation > 0.5);
}

test "cross-correlate FFT: constant large series" {
    var a: [100]f64 = undefined;
    for (0..100) |i| {
        a[i] = 5.0;
    }

    const result = try distances.crossCorrelate(&a, &a);
    try expect(result.lag == 0);
    try expectApprox(result.correlation, 1.0, 1e-10);
}

test "cross-correlate FFT: matches brute-force for 80-element series" {
    var a: [80]f64 = undefined;
    var b: [80]f64 = undefined;
    for (0..80) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.2) + 1.5;
        b[i] = @cos(@as(f64, @floatFromInt(i)) * 0.2) + 1.5;
    }
    const n: usize = 80;
    const m: usize = 80;

    // Compute means.
    var sum_a: f64 = 0;
    var sum_b: f64 = 0;
    for (0..n) |i| sum_a += a[i];
    for (0..m) |i| sum_b += b[i];
    const mean_a = sum_a / @as(f64, @floatFromInt(n));
    const mean_b = sum_b / @as(f64, @floatFromInt(m));

    // Compute norms.
    var norm_sq_a: f64 = 0;
    var norm_sq_b: f64 = 0;
    for (0..n) |i| {
        const d = a[i] - mean_a;
        norm_sq_a += d * d;
    }
    for (0..m) |i| {
        const d = b[i] - mean_b;
        norm_sq_b += d * d;
    }
    const norm_a = @sqrt(norm_sq_a);
    const norm_b = @sqrt(norm_sq_b);
    const norm_product = norm_a * norm_b;

    // Brute-force: find best lag and correlation.
    const max_lag: i32 = @intCast(@max(n, m) - 1);
    var bf_best_corr: f64 = -std.math.inf(f64);
    var bf_best_lag: i32 = 0;

    var lag: i32 = -max_lag;
    while (lag <= max_lag) : (lag += 1) {
        var cc: f64 = 0;
        const start_a: usize = if (lag >= 0) @intCast(lag) else 0;
        const start_b: usize = if (lag < 0) @intCast(-lag) else 0;
        var ia = start_a;
        var ib = start_b;
        while (ia < n and ib < m) {
            cc += (a[ia] - mean_a) * (b[ib] - mean_b);
            ia += 1;
            ib += 1;
        }
        const ncc = cc / norm_product;
        if (ncc > bf_best_corr) {
            bf_best_corr = ncc;
            bf_best_lag = lag;
        }
    }

    // FFT result from public API.
    const result = try distances.crossCorrelate(&a, &b);

    try expectApprox(result.correlation, bf_best_corr, 1e-8);
    try expect(result.lag == bf_best_lag);
}

test "SBD FFT: identical large series -> distance 0" {
    var a: [100]f64 = undefined;
    for (0..100) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 2.0;
    }

    const dist = try distances.sbd(&a, &a);
    try expectApprox(dist, 0.0, 1e-8);
}

// ============================================================================
// SBD
// ============================================================================

test "SBD: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const dist = try distances.sbd(&a, &a);
    try expectApprox(dist, 0.0, 1e-10);
}

test "SBD: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = distances.sbd(empty, &a);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// LCSS
// ============================================================================

test "LCSS: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const dist = try distances.lcss(std.testing.allocator, &a, &a, 0.5, 2);
    try expectApprox(dist, 0.0, 1e-10);
}

test "LCSS: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = distances.lcss(std.testing.allocator, empty, &a, 0.5, 2);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// EDR
// ============================================================================

test "EDR: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const dist = try distances.edr(std.testing.allocator, &a, &a, 0.5);
    try expectApprox(dist, 0.0, 1e-10);
}

test "EDR: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = distances.edr(std.testing.allocator, empty, &a, 0.5);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// ERP
// ============================================================================

test "ERP: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };

    const dist = try distances.erp(std.testing.allocator, &a, &a, 0.0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ERP: empty series -> error" {
    const a = [_]f64{1};
    const empty: []const f64 = &.{};

    const result = distances.erp(std.testing.allocator, empty, &a, 0.0);
    try expect(result == error.InvalidInput);
}

test "ERP: triangle inequality" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const c = [_]f64{ 3, 4, 5, 6, 7 };

    const d_ab = try distances.erp(std.testing.allocator, &a, &b, 0.0);
    const d_bc = try distances.erp(std.testing.allocator, &b, &c, 0.0);
    const d_ac = try distances.erp(std.testing.allocator, &a, &c, 0.0);

    try expect(d_ac <= d_ab + d_bc + 1e-10);
}

test "ERP: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    const d_ab = try distances.erp(std.testing.allocator, &a, &b, 0.0);
    const d_ba = try distances.erp(std.testing.allocator, &b, &a, 0.0);
    try expectApprox(d_ab, d_ba, 1e-10);
}

// ============================================================================
// TWED
// ============================================================================

test "TWED: identical series -> distance 0" {
    const v = [_]f64{ 1, 2, 3, 4, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };

    const dist = try distances.twed(std.testing.allocator, &v, &t, &v, &t, 0.5, 0.5);
    try expectApprox(dist, 0.0, 1e-10);
}

test "TWED: empty series -> error" {
    const v = [_]f64{1};
    const t = [_]f64{0};
    const empty: []const f64 = &.{};

    const result = distances.twed(std.testing.allocator, empty, &t, &v, &t, 0.5, 0.5);
    try expect(result == error.InvalidInput);
}

test "TWED: triangle inequality" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const c = [_]f64{ 3, 4, 5, 6, 7 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };

    const d_ab = try distances.twed(std.testing.allocator, &a, &t, &b, &t, 0.5, 0.5);
    const d_bc = try distances.twed(std.testing.allocator, &b, &t, &c, &t, 0.5, 0.5);
    const d_ac = try distances.twed(std.testing.allocator, &a, &t, &c, &t, 0.5, 0.5);

    try expect(d_ac <= d_ab + d_bc + 1e-10);
}

test "TWED: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };

    const d_ab = try distances.twed(std.testing.allocator, &a, &t, &b, &t, 0.5, 0.5);
    const d_ba = try distances.twed(std.testing.allocator, &b, &t, &a, &t, 0.5, 0.5);
    try expectApprox(d_ab, d_ba, 1e-10);
}

// ============================================================================
// Distance symmetry (all)
// ============================================================================

test "all distances: symmetric" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    // LCSS
    const la = try distances.lcss(std.testing.allocator, &a, &b, 1.0, 5);
    const lb_val = try distances.lcss(std.testing.allocator, &b, &a, 1.0, 5);
    try expectApprox(la, lb_val, 1e-10);

    // EDR
    const ea = try distances.edr(std.testing.allocator, &a, &b, 1.0);
    const eb = try distances.edr(std.testing.allocator, &b, &a, 1.0);
    try expectApprox(ea, eb, 1e-10);

    // SBD
    const sa = try distances.sbd(&a, &b);
    const sb = try distances.sbd(&b, &a);
    try expectApprox(sa, sb, 1e-10);
}

// ============================================================================
// Security: Empty input guards (idiomatic Zig error unions)
// ============================================================================

test "cross-correlate: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = distances.crossCorrelate(&a, empty);
    try expect(result == error.InvalidInput);
}

test "SBD: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = distances.sbd(&a, empty);
    try expect(result == error.InvalidInput);
}

test "LCSS: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = distances.lcss(std.testing.allocator, &a, empty, 0.5, 2);
    try expect(result == error.InvalidInput);
}

test "EDR: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = distances.edr(std.testing.allocator, &a, empty, 0.5);
    try expect(result == error.InvalidInput);
}

test "ERP: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const empty: []const f64 = &.{};

    const result = distances.erp(std.testing.allocator, &a, empty, 0.0);
    try expect(result == error.InvalidInput);
}

test "TWED: second slice empty -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    const empty: []const f64 = &.{};

    const result = distances.twed(std.testing.allocator, &a, &t, empty, &t, 0.5, 0.5);
    try expect(result == error.InvalidInput);
}
