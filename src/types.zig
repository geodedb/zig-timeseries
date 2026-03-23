// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Core time-series types used throughout the library and exposed via the C ABI.

/// A single point in a warp path (i, j coordinates in the alignment matrix).
pub const PathPoint = struct {
    i: i32,
    j: i32,
};

/// Result of aligning two series.
pub const Alignment = struct {
    distance: f64,
    path: []const PathPoint,
    lag: i32,
    overlap_frac: f64,
};

/// Shape-invariant statistics for a series.
pub const InvariantSet = struct {
    duration: f64,
    min: f64,
    max: f64,
    mean: f64,
    std_dev: f64,
    area: f64,
    histogram: [10]f64,
};

/// A gap (missing data region) in a series, defined by index range [start, end).
pub const Gap = struct {
    start: usize,
    end: usize,

    /// Returns true if index i falls within this gap.
    pub fn contains(self: Gap, i: usize) bool {
        return i >= self.start and i < self.end;
    }
};

/// A segment extracted from a series (e.g., by PELT or windowing).
pub const Segment = struct {
    start: usize,
    end: usize,
    source_index: usize = 0,
    confidence: f64 = 0.0,
};

/// Evidence supporting a match between two series segments.
pub const Evidence = struct {
    alignment: Alignment,
    invariants: InvariantSet,
    embedding_sim: f64 = 0.0,
    shape_corr: f64 = 0.0,
};

/// Match decision outcome.
pub const MatchDecision = enum(u2) {
    match_yes = 0,
    review = 1,
    reject = 2,
};

// ============================================================================
// Idiomatic Zig API result types
// ============================================================================

const std = @import("std");

/// Result of a DTW computation: the distance and the warp path.
/// The caller owns the `path` allocation and must free it via the same allocator.
pub const DtwResult = struct {
    distance: f64,
    path: []PathPoint,

    /// Free the path memory using the allocator that created it.
    pub fn deinit(self: DtwResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Result of normalized cross-correlation.
pub const CorrelationResult = struct {
    lag: i32,
    correlation: f64,
};

/// Result of matrix profile computation.
/// The caller owns both `profile` and `indices` and must free them via the same allocator.
pub const MatrixProfileResult = struct {
    profile: []f64,
    indices: []usize,

    /// Free both allocations using the allocator that created them.
    pub fn deinit(self: MatrixProfileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.profile);
        allocator.free(self.indices);
    }
};

/// Errors that can occur in time-series computations.
pub const TsError = error{
    /// Input slices are empty or have invalid lengths for the operation.
    InvalidInput,
    /// The requested allocation would exceed the safety cap.
    AllocationTooLarge,
    /// Series exceeds maximum allowed length (CPU DoS protection).
    SeriesTooLong,
    /// Standard out-of-memory from the allocator.
    OutOfMemory,
};
