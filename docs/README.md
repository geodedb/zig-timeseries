# timeseries Documentation

## Overview

A Zig library for time-series pattern matching, distance computation, segmentation,
and feature extraction. Exposes a C ABI (`libai_ts`) for consumption by Go (CGO),
Python (ctypes/cffi), or any C-compatible FFI.

## Modules

| Module | Description |
|--------|-------------|
| `dtw` | Dynamic Time Warping variants (constrained, derivative, open-end, shape, soft) + LB_Keogh |
| `distances` | Cross-correlation, SBD, LCSS, EDR, ERP, TWED |
| `matrix_profile` | Matrix profile and MPDist |
| `features` | 22-element feature extraction and cosine similarity |
| `pelt` | PELT change-point detection |
| `preprocess` | Resample, z-normalize, baseline correction, gap marking, derivative |
| `invariants` | Shape-invariant statistics (duration, min, max, mean, stddev, area, histogram) |
| `store` | Time-series store with batch insertion and aggregation sampling |
| `chunk_storage` | Chunk storage with Gorilla compression and retention policies |
| `types` | Core types: PathPoint, Alignment, InvariantSet, Gap, Segment, Evidence, MatchDecision |

## C ABI Surface

18 functions exported via `libai_ts.so` / `libai_ts.a` with header `ts_abi.h`.
See [GAP_ANALYSIS.md](GAP_ANALYSIS.md) for the full ABI table.

## Requirements and Gap Analysis

- [Requirements](REQUIREMENTS.md)
- [Gap Analysis](GAP_ANALYSIS.md)
- [Quality Gap Analysis](QUALITY_GAP_ANALYSIS.md)
- [Performance Gap Analysis](PERF_GAP_ANALYSIS.md)
- [Security Gap Analysis](SECURITY_GAP_ANALYSIS.md)

## Quick Links

- [Contributing](../CONTRIBUTING.md)
- [Security](../SECURITY.md)
- [Changelog](../CHANGELOG.md)
