// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Spectral analysis functions: FFT magnitude, Short-Time FFT, Spectral
//! Residual anomaly detection, and Haar wavelet decomposition.
//!
//! All public functions use idiomatic Zig signatures:
//! - Bounded slices (`[]const f64`) instead of raw pointers + length pairs
//! - Error unions (`!`) instead of integer return codes
//! - Returned owned slices; caller must free via `allocator.free(result)`
//!
//! References:
//! - Hou & Zhang, "Saliency Detection: A Spectral Residual Approach", CVPR, 2007 (SR).
//! - Ren et al., "Time-Series Anomaly Detection Service at Microsoft", KDD, 2019 (SR for time series).

const std = @import("std");
const math = std.math;
const distances = @import("distances.zig");
const types = @import("types.zig");
const TsError = types.TsError;

/// Compute FFT and return magnitude spectrum (|X[k]| for k = 0..N-1).
///
/// Input is zero-padded to the next power of 2. The returned slice has
/// length equal to the padded size. Caller owns the returned slice.
pub fn fftMagnitude(allocator: std.mem.Allocator, values: []const f64) ![]f64 {
    if (values.len == 0) return TsError.InvalidInput;

    const n = distances.nextPowerOf2(values.len);

    const real = try allocator.alloc(f64, n);
    errdefer allocator.free(real);
    const imag = try allocator.alloc(f64, n);
    defer allocator.free(imag);

    for (0..n) |i| {
        real[i] = if (i < values.len) values[i] else 0.0;
        imag[i] = 0.0;
    }

    distances.fft(real, imag, n, false);

    // Overwrite real[] with magnitudes.
    for (0..n) |i| {
        real[i] = @sqrt(real[i] * real[i] + imag[i] * imag[i]);
    }

    return real;
}

/// Short-Time Fourier Transform.
///
/// Splits `values` into overlapping windows of `window_size` with stride
/// `hop_size`, computes the FFT magnitude of each window, and returns an
/// array of magnitude spectra (one per window). Caller owns all returned
/// slices and must free each inner slice as well as the outer slice.
pub fn stft(
    allocator: std.mem.Allocator,
    values: []const f64,
    window_size: usize,
    hop_size: usize,
) ![][]f64 {
    if (values.len == 0 or window_size == 0 or hop_size == 0) return TsError.InvalidInput;
    if (window_size > values.len) return TsError.InvalidInput;

    // Count number of windows.
    var num_windows: usize = 0;
    {
        var start: usize = 0;
        while (start + window_size <= values.len) : (start += hop_size) {
            num_windows += 1;
        }
    }
    if (num_windows == 0) return TsError.InvalidInput;

    const result = try allocator.alloc([]f64, num_windows);
    errdefer {
        for (0..num_windows) |i| {
            if (i < result.len) {
                // Only free slices that were successfully allocated.
                // On error, we may have partially filled the array.
                allocator.free(result[i]);
            }
        }
        allocator.free(result);
    }

    var start: usize = 0;
    for (0..num_windows) |w| {
        result[w] = try fftMagnitude(allocator, values[start .. start + window_size]);
        start += hop_size;
    }

    return result;
}

/// Spectral Residual anomaly detection.
///
/// Algorithm (Hou & Zhang 2007, adapted for 1-D time series):
/// 1. Compute FFT of input
/// 2. Log amplitude spectrum: L(f) = log(|X(f)|)
/// 3. Average-filtered log spectrum: A(f) = avg_filter(L(f), q=3)
/// 4. Spectral residual: R(f) = L(f) - A(f)
/// 5. Reconstruct: x'(t) = IFFT(exp(R(f) + i * phase(f)))
/// 6. Saliency map: S(t) = |x'(t)|^2
///
/// Returns a saliency score per input sample (higher = more anomalous).
/// Caller owns the returned slice.
pub fn spectralResidual(allocator: std.mem.Allocator, values: []const f64) ![]f64 {
    if (values.len == 0) return TsError.InvalidInput;

    const n = distances.nextPowerOf2(values.len);

    const real = try allocator.alloc(f64, n);
    defer allocator.free(real);
    const imag = try allocator.alloc(f64, n);
    defer allocator.free(imag);

    // Step 1: FFT.
    for (0..n) |i| {
        real[i] = if (i < values.len) values[i] else 0.0;
        imag[i] = 0.0;
    }
    distances.fft(real, imag, n, false);

    // Step 2: Log amplitude and phase.
    const log_amp = try allocator.alloc(f64, n);
    defer allocator.free(log_amp);
    const phase = try allocator.alloc(f64, n);
    defer allocator.free(phase);

    for (0..n) |i| {
        const mag = @sqrt(real[i] * real[i] + imag[i] * imag[i]);
        log_amp[i] = @log(@max(mag, 1e-10));
        phase[i] = math.atan2(imag[i], real[i]);
    }

    // Step 3: Average filter (window q=3).
    const avg_log = try allocator.alloc(f64, n);
    defer allocator.free(avg_log);
    const q: usize = 3;
    const half_q: usize = q / 2;
    for (0..n) |i| {
        var sum: f64 = 0.0;
        var count: f64 = 0.0;
        const lo = if (i >= half_q) i - half_q else 0;
        const hi = @min(i + half_q + 1, n);
        for (lo..hi) |j| {
            sum += log_amp[j];
            count += 1.0;
        }
        avg_log[i] = sum / count;
    }

    // Step 4: Spectral residual.
    // Step 5: Reconstruct via IFFT with exp(R + i*phase).
    for (0..n) |i| {
        const residual = log_amp[i] - avg_log[i];
        const amp = @exp(residual);
        real[i] = amp * @cos(phase[i]);
        imag[i] = amp * @sin(phase[i]);
    }
    distances.fft(real, imag, n, true);

    // Step 6: Saliency = |x'(t)|^2, trimmed to original length.
    const saliency = try allocator.alloc(f64, values.len);
    for (0..values.len) |i| {
        saliency[i] = real[i] * real[i] + imag[i] * imag[i];
    }

    return saliency;
}

/// Haar wavelet decomposition result.
pub const HaarResult = struct {
    /// Approximation coefficients (low-pass).
    approx: []f64,
    /// Detail coefficients (high-pass).
    detail: []f64,
};

/// Basic Haar wavelet decomposition (one level).
///
/// For input of length N (padded to even length if necessary):
///   approx[i] = (x[2i] + x[2i+1]) / sqrt(2)
///   detail[i] = (x[2i] - x[2i+1]) / sqrt(2)
///
/// Caller owns both returned slices.
pub fn dwtHaar(allocator: std.mem.Allocator, values: []const f64) !HaarResult {
    if (values.len == 0) return TsError.InvalidInput;

    // Pad to even length if needed.
    const padded_len = if (values.len % 2 == 0) values.len else values.len + 1;
    const half = padded_len / 2;
    const inv_sqrt2 = 1.0 / @sqrt(2.0);

    const approx = try allocator.alloc(f64, half);
    errdefer allocator.free(approx);
    const detail = try allocator.alloc(f64, half);

    for (0..half) |i| {
        const x0 = if (2 * i < values.len) values[2 * i] else 0.0;
        const x1 = if (2 * i + 1 < values.len) values[2 * i + 1] else 0.0;
        approx[i] = (x0 + x1) * inv_sqrt2;
        detail[i] = (x0 - x1) * inv_sqrt2;
    }

    return .{ .approx = approx, .detail = detail };
}
