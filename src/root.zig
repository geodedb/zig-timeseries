// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # timeseries
//!
//! A Zig library for time-series pattern matching, distance computation,
//! segmentation, and feature extraction. Exposes a C ABI for consumption
//! by Go (CGO), Python (ctypes/cffi), or any C-compatible FFI.
//!
//! ## Modules
//!
//! - `dtw` -- Dynamic Time Warping variants (constrained, derivative, open-end, shape, soft)
//! - `distances` -- Cross-correlation, SBD, LCSS, EDR, ERP, TWED
//! - `matrix_profile` -- Matrix profile and MPDist
//! - `features` -- 22-element feature extraction and cosine similarity
//! - `pelt` -- PELT change-point detection
//! - `spectral` -- FFT magnitude, STFT, Spectral Residual, Haar DWT
//! - `anomaly` -- CUSUM and EWMA anomaly/change-point detection
//! - `types` -- Core data types (PathPoint, Alignment, InvariantSet)
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version.
pub const version = "0.1.0";

// Re-export submodules.
pub const types = @import("types.zig");
pub const dtw = @import("dtw.zig");
pub const distances = @import("distances.zig");
pub const matrix_profile = @import("matrix_profile.zig");
pub const features = @import("features.zig");
pub const pelt = @import("pelt.zig");
pub const preprocess = @import("preprocess.zig");
pub const invariants = @import("invariants.zig");
pub const store = @import("store.zig");
pub const chunk_storage = @import("chunk_storage.zig");
pub const spectral = @import("spectral.zig");
pub const anomaly = @import("anomaly.zig");
/// Parallel batch entry points (requires `thread_pool`).
pub const parallel = @import("parallel.zig");

// Re-export core types at top level.
pub const Gap = types.Gap;
pub const Segment = types.Segment;
pub const Evidence = types.Evidence;
pub const MatchDecision = types.MatchDecision;
pub const PathPoint = types.PathPoint;
pub const Alignment = types.Alignment;
pub const InvariantSet = types.InvariantSet;
pub const DtwResult = types.DtwResult;
pub const CorrelationResult = types.CorrelationResult;
pub const MatrixProfileResult = types.MatrixProfileResult;
pub const TsError = types.TsError;

// Re-export key store types at top level.
pub const Point = store.Point;
pub const PointF64 = store.PointF64;
pub const SeriesKey = store.SeriesKey;
pub const Series = store.Series;
pub const Store = store.Store;
pub const StoreConfig = store.StoreConfig;
pub const ChunkConfig = chunk_storage.ChunkConfig;
pub const ChunkStorage = chunk_storage.ChunkStorage;

// Re-export key preprocessing functions at top level.
pub const zNormalizeAlloc = preprocess.zNormalizeAlloc;
pub const baselineCorrectAlloc = preprocess.baselineCorrectAlloc;

// Pull in the C ABI exports so they are compiled into the shared library.
pub const abi = @import("abi.zig");

// ============================================================================
// Unit Tests
// ============================================================================

test {
    // Ensure all declarations are referenced for test coverage.
    std.testing.refAllDecls(@This());

    // Pull in all test files.
    _ = @import("dtw_test.zig");
    _ = @import("distances_test.zig");
    _ = @import("matrix_profile_test.zig");
    _ = @import("features_test.zig");
    _ = @import("pelt_test.zig");
    _ = @import("preprocess_test.zig");
    _ = @import("invariants_test.zig");
    _ = @import("abi_test.zig");
    _ = @import("types_test.zig");
    _ = @import("spectral_test.zig");
    _ = @import("anomaly_test.zig");
    _ = @import("parallel_test.zig");
}
