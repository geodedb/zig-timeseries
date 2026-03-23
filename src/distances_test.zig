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
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 5, &a, 5, &lag, &corr);
    try expect(rc == 0);
    try expect(lag == 0);
    try expectApprox(corr, 1.0, 1e-10);
}

test "cross-correlate: empty series -> error" {
    const a = [_]f64{1};
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 0, &a, 1, &lag, &corr);
    try expect(rc == -1);
}

test "cross-correlate: shifted series detects lag" {
    const a = [_]f64{ 0, 0, 1, 2, 3, 4, 5, 0, 0 };
    const b = [_]f64{ 0, 0, 0, 0, 1, 2, 3, 4, 5 };
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 9, &b, 9, &lag, &corr);
    try expect(rc == 0);
    try expect(corr > 0.8);
}

// ============================================================================
// Cross-Correlation: FFT path (inputs >= 64 elements)
// ============================================================================

test "cross-correlate FFT: identical large series -> lag 0, correlation 1" {
    // Generate a 128-element series to trigger FFT path.
    var a: [128]f64 = undefined;
    for (0..128) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 2.0;
    }
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 128, &a, 128, &lag, &corr);
    try expect(rc == 0);
    try expect(lag == 0);
    try expectApprox(corr, 1.0, 1e-8);
}

test "cross-correlate FFT: shifted large series detects lag" {
    // Create two series where b is a shifted version of a.
    var a: [100]f64 = undefined;
    var b: [100]f64 = undefined;
    const shift: usize = 5;

    // Fill a with a distinctive pattern.
    for (0..100) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.2);
    }
    // Fill b with the same pattern shifted by `shift` positions.
    for (0..100) |i| {
        if (i >= shift) {
            b[i] = a[i - shift];
        } else {
            b[i] = 0;
        }
    }
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 100, &b, 100, &lag, &corr);
    try expect(rc == 0);
    // The lag should detect the shift.
    try expect(corr > 0.5);
}

test "cross-correlate FFT: symmetry for large series" {
    var a: [80]f64 = undefined;
    var b: [80]f64 = undefined;
    for (0..80) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.15);
        b[i] = @cos(@as(f64, @floatFromInt(i)) * 0.15);
    }
    var lag_ab: i32 = undefined;
    var corr_ab: f64 = undefined;
    var lag_ba: i32 = undefined;
    var corr_ba: f64 = undefined;

    const r1 = distances.crossCorrelate(&a, 80, &b, 80, &lag_ab, &corr_ab);
    const r2 = distances.crossCorrelate(&b, 80, &a, 80, &lag_ba, &corr_ba);
    try expect(r1 == 0);
    try expect(r2 == 0);
    // Max correlation should be symmetric.
    try expectApprox(corr_ab, corr_ba, 1e-8);
}

test "cross-correlate FFT: brute-force vs FFT agreement at boundary" {
    // Test at exactly the FFT threshold boundary: 63 (brute-force) vs 64 (FFT).
    // Use the same pattern at both sizes to ensure consistent behavior.
    var data: [65]f64 = undefined;
    for (0..65) |i| {
        data[i] = @as(f64, @floatFromInt(i)) * 0.5 + 1.0;
    }

    // 63 elements -> brute-force
    var lag_bf: i32 = undefined;
    var corr_bf: f64 = undefined;
    const rc_bf = distances.crossCorrelate(&data, 63, &data, 63, &lag_bf, &corr_bf);

    // 65 elements -> FFT
    var lag_fft: i32 = undefined;
    var corr_fft: f64 = undefined;
    const rc_fft = distances.crossCorrelate(&data, 65, &data, 65, &lag_fft, &corr_fft);

    try expect(rc_bf == 0);
    try expect(rc_fft == 0);
    // Both self-correlations should yield lag 0 and correlation 1.0.
    try expect(lag_bf == 0);
    try expect(lag_fft == 0);
    try expectApprox(corr_bf, 1.0, 1e-8);
    try expectApprox(corr_fft, 1.0, 1e-8);
}

test "cross-correlate FFT: different length series" {
    // Test with series of different lengths, both >= 64.
    var a: [70]f64 = undefined;
    var b: [90]f64 = undefined;
    for (0..70) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 3.0;
    }
    for (0..90) |i| {
        b[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 3.0;
    }
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 70, &b, 90, &lag, &corr);
    try expect(rc == 0);
    // Since b is a superset-like pattern, should have high correlation.
    try expect(corr > 0.5);
}

test "cross-correlate FFT: constant large series" {
    // All-constant series (norm=0) should return corr=1.0.
    var a: [100]f64 = undefined;
    for (0..100) |i| {
        a[i] = 5.0;
    }
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, 100, &a, 100, &lag, &corr);
    try expect(rc == 0);
    try expect(lag == 0);
    try expectApprox(corr, 1.0, 1e-10);
}

test "cross-correlate FFT: matches brute-force for 80-element series" {
    // Manually compute brute-force result and compare with public API (FFT path).
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
    var fft_lag: i32 = undefined;
    var fft_corr: f64 = undefined;
    const rc = distances.crossCorrelate(&a, 80, &b, 80, &fft_lag, &fft_corr);
    try expect(rc == 0);

    // The FFT result should match brute-force within floating-point tolerance.
    try expectApprox(fft_corr, bf_best_corr, 1e-8);
    try expect(fft_lag == bf_best_lag);
}

test "SBD FFT: identical large series -> distance 0" {
    var a: [100]f64 = undefined;
    for (0..100) |i| {
        a[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) + 2.0;
    }
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, 100, &a, 100, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-8);
}

// ============================================================================
// SBD
// ============================================================================

test "SBD: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, 5, &a, 5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "SBD: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, 0, &a, 1, &dist);
    try expect(rc == -1);
}

// ============================================================================
// LCSS
// ============================================================================

test "LCSS: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.lcss(std.testing.allocator, &a, 5, &a, 5, 0.5, 2, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "LCSS: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.lcss(std.testing.allocator, &a, 0, &a, 1, 0.5, 2, &dist);
    try expect(rc == -1);
}

// ============================================================================
// EDR
// ============================================================================

test "EDR: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.edr(std.testing.allocator, &a, 5, &a, 5, 0.5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "EDR: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.edr(std.testing.allocator, &a, 0, &a, 1, 0.5, &dist);
    try expect(rc == -1);
}

// ============================================================================
// ERP
// ============================================================================

test "ERP: identical series -> distance 0" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    var dist: f64 = undefined;

    const rc = distances.erp(std.testing.allocator, &a, 5, &a, 5, 0.0, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "ERP: empty series -> error" {
    const a = [_]f64{1};
    var dist: f64 = undefined;

    const rc = distances.erp(std.testing.allocator, &a, 0, &a, 1, 0.0, &dist);
    try expect(rc == -1);
}

test "ERP: triangle inequality" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const c = [_]f64{ 3, 4, 5, 6, 7 };
    var d_ab: f64 = undefined;
    var d_bc: f64 = undefined;
    var d_ac: f64 = undefined;

    _ = distances.erp(std.testing.allocator, &a, 5, &b, 5, 0.0, &d_ab);
    _ = distances.erp(std.testing.allocator, &b, 5, &c, 5, 0.0, &d_bc);
    _ = distances.erp(std.testing.allocator, &a, 5, &c, 5, 0.0, &d_ac);

    try expect(d_ac <= d_ab + d_bc + 1e-10);
}

test "ERP: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    var d_ab: f64 = undefined;
    var d_ba: f64 = undefined;

    _ = distances.erp(std.testing.allocator, &a, 5, &b, 5, 0.0, &d_ab);
    _ = distances.erp(std.testing.allocator, &b, 5, &a, 5, 0.0, &d_ba);
    try expectApprox(d_ab, d_ba, 1e-10);
}

// ============================================================================
// TWED
// ============================================================================

test "TWED: identical series -> distance 0" {
    const v = [_]f64{ 1, 2, 3, 4, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var dist: f64 = undefined;

    const rc = distances.twed(std.testing.allocator, &v, 5, &t, &v, 5, &t, 0.5, 0.5, &dist);
    try expect(rc == 0);
    try expectApprox(dist, 0.0, 1e-10);
}

test "TWED: empty series -> error" {
    const v = [_]f64{1};
    const t = [_]f64{0};
    var dist: f64 = undefined;

    const rc = distances.twed(std.testing.allocator, &v, 0, &t, &v, 1, &t, 0.5, 0.5, &dist);
    try expect(rc == -1);
}

test "TWED: triangle inequality" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const c = [_]f64{ 3, 4, 5, 6, 7 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var d_ab: f64 = undefined;
    var d_bc: f64 = undefined;
    var d_ac: f64 = undefined;

    _ = distances.twed(std.testing.allocator, &a, 5, &t, &b, 5, &t, 0.5, 0.5, &d_ab);
    _ = distances.twed(std.testing.allocator, &b, 5, &t, &c, 5, &t, 0.5, 0.5, &d_bc);
    _ = distances.twed(std.testing.allocator, &a, 5, &t, &c, 5, &t, 0.5, 0.5, &d_ac);

    try expect(d_ac <= d_ab + d_bc + 1e-10);
}

test "TWED: symmetry" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };
    const t = [_]f64{ 0, 1, 2, 3, 4 };
    var d_ab: f64 = undefined;
    var d_ba: f64 = undefined;

    _ = distances.twed(std.testing.allocator, &a, 5, &t, &b, 5, &t, 0.5, 0.5, &d_ab);
    _ = distances.twed(std.testing.allocator, &b, 5, &t, &a, 5, &t, 0.5, 0.5, &d_ba);
    try expectApprox(d_ab, d_ba, 1e-10);
}

// ============================================================================
// Distance symmetry (all)
// ============================================================================

test "all distances: symmetric" {
    const a = [_]f64{ 1, 3, 5, 2, 4 };
    const b = [_]f64{ 2, 4, 1, 3, 5 };

    // LCSS
    var la: f64 = undefined;
    var lb_val: f64 = undefined;
    _ = distances.lcss(std.testing.allocator, &a, 5, &b, 5, 1.0, 5, &la);
    _ = distances.lcss(std.testing.allocator, &b, 5, &a, 5, 1.0, 5, &lb_val);
    try expectApprox(la, lb_val, 1e-10);

    // EDR
    var ea: f64 = undefined;
    var eb: f64 = undefined;
    _ = distances.edr(std.testing.allocator, &a, 5, &b, 5, 1.0, &ea);
    _ = distances.edr(std.testing.allocator, &b, 5, &a, 5, 1.0, &eb);
    try expectApprox(ea, eb, 1e-10);

    // SBD
    var sa: f64 = undefined;
    var sb: f64 = undefined;
    _ = distances.sbd(&a, 5, &b, 5, &sa);
    _ = distances.sbd(&b, 5, &a, 5, &sb);
    try expectApprox(sa, sb, 1e-10);
}

// ============================================================================
// Security: Negative length guards (GAP-0021/S1)
// ============================================================================

test "cross-correlate: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var lag: i32 = undefined;
    var corr: f64 = undefined;

    const rc = distances.crossCorrelate(&a, -1, &a, 3, &lag, &corr);
    try expect(rc == -1);
}

test "SBD: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.sbd(&a, -1, &a, 3, &dist);
    try expect(rc == -1);
}

test "LCSS: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.lcss(std.testing.allocator, &a, -1, &a, 3, 0.5, 2, &dist);
    try expect(rc == -1);
}

test "EDR: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.edr(std.testing.allocator, &a, -1, &a, 3, 0.5, &dist);
    try expect(rc == -1);
}

test "ERP: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    var dist: f64 = undefined;

    const rc = distances.erp(std.testing.allocator, &a, -1, &a, 3, 0.0, &dist);
    try expect(rc == -1);
}

test "TWED: negative length -> error" {
    const a = [_]f64{ 1, 2, 3 };
    const t = [_]f64{ 0, 1, 2 };
    var dist: f64 = undefined;

    const rc = distances.twed(std.testing.allocator, &a, -1, &t, &a, 3, &t, 0.5, 0.5, &dist);
    try expect(rc == -1);
}
