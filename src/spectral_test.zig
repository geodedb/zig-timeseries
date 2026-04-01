// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const spectral = @import("spectral.zig");
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

// ============================================================================
// FFT Magnitude
// ============================================================================

test "fftMagnitude: pure DC signal has peak at index 0" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 5.0, 5.0, 5.0, 5.0 };

    const mag = try spectral.fftMagnitude(allocator, &values);
    defer allocator.free(mag);

    // DC component = N * amplitude = 4 * 5 = 20.
    try expectApprox(mag[0], 20.0, 1e-10);
    // All other bins should be ~0.
    for (1..mag.len) |i| {
        try expectApprox(mag[i], 0.0, 1e-10);
    }
}

test "fftMagnitude: sinusoidal input produces frequency peak" {
    const allocator = std.testing.allocator;
    // 8-point signal with frequency at bin 1 (1 cycle over 8 samples).
    var values: [8]f64 = undefined;
    for (0..8) |i| {
        values[i] = @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / 8.0);
    }

    const mag = try spectral.fftMagnitude(allocator, &values);
    defer allocator.free(mag);

    // Bin 1 and bin 7 (N-1) should have the peaks for a cosine at frequency 1.
    // Magnitude should be N/2 = 4.
    try expectApprox(mag[1], 4.0, 1e-10);
    try expectApprox(mag[7], 4.0, 1e-10);
    // DC should be ~0.
    try expectApprox(mag[0], 0.0, 1e-10);
}

test "fftMagnitude: empty input -> error" {
    const allocator = std.testing.allocator;
    const empty: []const f64 = &.{};

    const result = spectral.fftMagnitude(allocator, empty);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// Short-Time FFT
// ============================================================================

test "stft: output dimensions match expected windows" {
    const allocator = std.testing.allocator;
    // 16 samples, window=8, hop=4 -> windows at [0..8], [4..12], [8..16] = 3 windows.
    var values: [16]f64 = undefined;
    for (0..16) |i| {
        values[i] = @sin(@as(f64, @floatFromInt(i)) * 0.5);
    }

    const result = try spectral.stft(allocator, &values, 8, 4);
    defer {
        for (result) |row| allocator.free(row);
        allocator.free(result);
    }

    try expect(result.len == 3);
    // Each window is padded to next power of 2 (8 is already pow2).
    for (result) |row| {
        try expect(row.len == 8);
    }
}

test "stft: window larger than input -> error" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 1.0, 2.0 };

    const result = spectral.stft(allocator, &values, 4, 2);
    try expect(result == error.InvalidInput);
}

test "stft: zero window size -> error" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0 };

    const result = spectral.stft(allocator, &values, 0, 1);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// Spectral Residual
// ============================================================================

test "spectralResidual: anomaly at injected spike is scored highest" {
    const allocator = std.testing.allocator;
    // Flat signal with a large spike at index 8.
    var values: [32]f64 = undefined;
    for (0..32) |i| {
        values[i] = 1.0;
    }
    values[8] = 100.0; // Inject anomaly.

    const saliency = try spectral.spectralResidual(allocator, &values);
    defer allocator.free(saliency);

    try expect(saliency.len == 32);

    // The saliency at the spike should be among the highest.
    // Find max saliency index.
    var max_val: f64 = 0.0;
    var max_idx: usize = 0;
    for (saliency, 0..) |s, i| {
        if (s > max_val) {
            max_val = s;
            max_idx = i;
        }
    }

    // Due to FFT spreading, the max may not be exactly at 8, but should
    // be near it. The spike should produce noticeably higher saliency
    // than the average of the flat region.
    var flat_sum: f64 = 0.0;
    var flat_count: f64 = 0.0;
    for (saliency, 0..) |s, i| {
        // Exclude the neighborhood around the spike.
        if (i < 5 or i > 11) {
            flat_sum += s;
            flat_count += 1.0;
        }
    }
    const flat_avg = flat_sum / flat_count;
    // The spike region should have higher saliency than the flat average.
    try expect(saliency[8] > flat_avg);
    // The max saliency should be near the spike location.
    try expect(max_idx >= 5 and max_idx <= 15);
}

test "spectralResidual: empty input -> error" {
    const allocator = std.testing.allocator;
    const empty: []const f64 = &.{};

    const result = spectral.spectralResidual(allocator, empty);
    try expect(result == error.InvalidInput);
}

// ============================================================================
// Haar DWT
// ============================================================================

test "dwtHaar: known decomposition of [1, 3, 5, 7]" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 1.0, 3.0, 5.0, 7.0 };

    const result = try spectral.dwtHaar(allocator, &values);
    defer {
        allocator.free(result.approx);
        allocator.free(result.detail);
    }

    const inv_sqrt2 = 1.0 / @sqrt(2.0);

    // approx[0] = (1 + 3) / sqrt(2) = 4 / sqrt(2)
    try expectApprox(result.approx[0], 4.0 * inv_sqrt2, 1e-10);
    // approx[1] = (5 + 7) / sqrt(2) = 12 / sqrt(2)
    try expectApprox(result.approx[1], 12.0 * inv_sqrt2, 1e-10);
    // detail[0] = (1 - 3) / sqrt(2) = -2 / sqrt(2)
    try expectApprox(result.detail[0], -2.0 * inv_sqrt2, 1e-10);
    // detail[1] = (5 - 7) / sqrt(2) = -2 / sqrt(2)
    try expectApprox(result.detail[1], -2.0 * inv_sqrt2, 1e-10);
}

test "dwtHaar: odd-length input pads correctly" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 1.0, 3.0, 5.0 };

    const result = try spectral.dwtHaar(allocator, &values);
    defer {
        allocator.free(result.approx);
        allocator.free(result.detail);
    }

    // Padded to [1, 3, 5, 0] -> 2 coefficients each.
    try expect(result.approx.len == 2);
    try expect(result.detail.len == 2);

    const inv_sqrt2 = 1.0 / @sqrt(2.0);
    // approx[1] = (5 + 0) / sqrt(2)
    try expectApprox(result.approx[1], 5.0 * inv_sqrt2, 1e-10);
    // detail[1] = (5 - 0) / sqrt(2)
    try expectApprox(result.detail[1], 5.0 * inv_sqrt2, 1e-10);
}

test "dwtHaar: empty input -> error" {
    const allocator = std.testing.allocator;
    const empty: []const f64 = &.{};

    const result = spectral.dwtHaar(allocator, empty);
    try expect(result == error.InvalidInput);
}

test "dwtHaar: energy preservation" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ 2.0, 4.0, 6.0, 8.0 };

    const result = try spectral.dwtHaar(allocator, &values);
    defer {
        allocator.free(result.approx);
        allocator.free(result.detail);
    }

    // Energy of original.
    var orig_energy: f64 = 0.0;
    for (values) |v| orig_energy += v * v;

    // Energy of coefficients (Parseval's theorem for orthogonal transforms).
    var coeff_energy: f64 = 0.0;
    for (result.approx) |v| coeff_energy += v * v;
    for (result.detail) |v| coeff_energy += v * v;

    try expectApprox(orig_energy, coeff_energy, 1e-10);
}
