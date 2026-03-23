# GAP Analysis

Last updated: 2026-03-23

Repository status: C ABI surface (18 functions) operational, Geode store/chunk-storage ported with Zig 0.15 fixes, **224 tests passing** (202 unit + 12 integration + 10 fuzz/property). Build passes in Debug, ReleaseSafe, and ReleaseFast. **9 gaps closed** across cycles (GAP-0011, GAP-0012, GAP-0013, GAP-0014, GAP-0015, GAP-0018, GAP-0019, GAP-0020, GAP-0021), **2 won't-do** (GAP-0016, GAP-0017), **1 architectural won't-do** (G-02). **Quick fixes cycle** (2026-03-23) closed Q16 (hardcoded /tmp paths), Q8 (allocating preprocess variants), GAP-0019 (docs), GAP-0018 (e2e tests), S11+S12+S14 (CI hardening). **Idiomatic API cycle** (2026-03-23) closed Q4 (idiomatic Zig API), Q19 (consistent error signaling), S2 (bounded slices at ABI boundary) -- all 5 algorithm modules (dtw, distances, matrix_profile, features, pelt) refactored to use `[]const f64` slices, `!` error unions, and result structs.

## Goal

Extract Geode's reusable timeseries store and chunk-storage core into a standalone library, while leaving GQL-facing query integration in Geode. The Go reference implementation at `devnw.dev/ts` defines the full requirements for time-series pattern matching, event emission, and evaluation. This library must implement the Zig ABI functions that the Go module calls via CGO, plus the standalone store/chunk-storage layer from Geode.

## Reference Implementation

The Go module `devnw.dev/ts` (`~/src/gl/devnw/go/ts`) provides the authoritative requirements. It is organized into six packages:

| Go package | Responsibility |
|---|---|
| `devnw.dev/ts` (root) | Event emitter for DPI/telemetry pipelines |
| `devnw.dev/ts/series` | Core time-series types, preprocessing, invariants, and Zig ABI bindings |
| `devnw.dev/ts/match` | Pattern-matching pipeline orchestration |
| `devnw.dev/ts/stream` | Event windowing and streaming adapters |
| `devnw.dev/ts/cluster` | Record clustering algorithms |
| `devnw.dev/ts/eval` | Evaluation metrics and ground-truth generation |

## Intended Boundary

### Move into this library

#### From Geode

| Geode source | Why it belongs here |
|---|---|
| `src/timeseries/timeseries.zig:4`, `:13`, `:52`, `:56`, `:95`, `:134`, `:219` | Core point/series/store and aggregation logic |
| `src/timeseries/chunk_storage.zig:6`, `:167`, `:175`, `:214`, `:256`, `:282`, `:313` | Chunk compression, persistence, range query, retention, and stats |

#### From Go ABI contract (`series/abi.go`, build tag `zig`)

The Go module calls into a Zig-compiled `libai_ts` via CGO. This library must expose the following C ABI surface (declared in `ts_abi.h`):

| ABI function | Go caller | Purpose |
|---|---|---|
| `ts_version` | `ABIVersion()` | Library version string |
| `ts_dtw` | `ConstrainedDTW.Align()` | Constrained DTW (Sakoe-Chiba band) alignment |
| `ts_dtw_derivative` | `DerivativeDTW.Align()` | DTW on first-difference representation |
| `ts_dtw_open_end` | `OpenEndDTW.Align()` | Open-begin/end partial alignment |
| `ts_dtw_shape` | `ShapeDTW.Align()` | DTW with local shape descriptors |
| `ts_soft_dtw` | `SoftDTW.Distance()` | Differentiable soft-DTW distance |
| `ts_lb_keogh` | `LBKeogh()` | Lower-bound envelope pruning |
| `ts_cross_correlate` | `CrossCorrelate()` | Normalized cross-correlation with lag |
| `ts_sbd` | `SBD()` | Shape-based distance |
| `ts_pelt` | `PELTSegmenter.Segment()` | PELT change-point segmentation |
| `ts_lcss` | `LCSS()` | Longest Common Subsequence distance |
| `ts_edr` | `EDR()` | Edit Distance on Real sequences |
| `ts_erp` | `ERP()` | Edit distance with Real Penalty |
| `ts_twed` | `TWED()` | Time Warp Edit Distance |
| `ts_matrix_profile` | `MatrixProfile()` | Matrix profile computation |
| `ts_mp_dist` | `MPDist()` | Matrix-profile-based series distance |
| `ts_extract_features` | `ExtractFeatures()` | 22-element feature vector extraction |
| `ts_cosine_similarity` | `CosineSimilarity()` | Vector cosine similarity |

### Keep in Geode

| Geode source | Why it stays |
|---|---|
| `src/timeseries/gql_functions.zig:76`, `:104`, `:129` | GQL-facing execution adapter over the timeseries store |

### Keep in Go

| Go package | Why it stays |
|---|---|
| `devnw.dev/ts` (root) | Go-specific event emitter, channels, goroutines |
| `devnw.dev/ts/match` | Go pipeline orchestration (calls ABI for alignment) |
| `devnw.dev/ts/stream` | Go streaming adapters (channels, windowing) |
| `devnw.dev/ts/cluster` | Go clustering (graph algorithms over Go structs) |
| `devnw.dev/ts/eval` | Go evaluation harness |

## Full Requirements from Go Reference

### R1: Core Types (`series` package)

| Type | Fields | Methods |
|---|---|---|
| `Series` | `Times []time.Time`, `Values []float64`, `Gaps []Gap`, `Meta map[string]any` | `Len()`, `Empty()`, `Slice(start, end)` |
| `Gap` | `Start int`, `End int` | `Contains(i)` |
| `Segment` | embeds `Series` + `SourceIndex int`, `Confidence float64` | |
| `Alignment` | `Distance float64`, `Path []PathPoint`, `Lag int`, `OverlapFrac float64`, `Method string` | |
| `PathPoint` | `I int`, `J int` | `String()` |
| `Evidence` | `Alignment`, `Invariants InvariantSet`, `EmbeddingSim float64`, `ShapeCorr float64` | |
| `InvariantSet` | `Duration`, `Min`, `Max`, `Mean`, `StdDev`, `Area`, `Histogram []float64` | |
| `Record` | `ID string`, `SourceID string`, `Segment`, `Evidence map[string]Evidence` | |
| `Cluster` | `ID string`, `Records []Record`, `Score float64` | |
| `MatchDecision` | enum: `Match=0`, `Review=1`, `Reject=2` | `String()` |
| `PipelineStats` | `InputCount`, `SegmentCount`, `CandidatePairs`, `ClusterCount`, `OrphanCount int`, `Duration` | |
| `MatchResult` | `Clusters []Cluster`, `Orphans []Record`, `Stats PipelineStats` | |

### R2: Interfaces (`series` package)

| Interface | Signature | Purpose |
|---|---|---|
| `Segmenter` | `Segment(ctx, Series) ([]Segment, error)` | Event window extraction |
| `CandidateGenerator` | `Candidates(ctx, target Segment, corpus []Record) ([]Record, error)` | Candidate pair pruning |
| `Aligner` | `Align(ctx, a, b Series) (Alignment, error)` | Pairwise alignment |
| `Embedder` | `Embed(ctx, Series) ([]float64, error)` | Fixed-length embedding |
| `Scorer` | `Score(ctx, Evidence) (float64, error)` | Match probability |
| `Grouper` | `Group(ctx, []Record) ([]Cluster, error)` | Record clustering |
| `Preprocessor` | `func(Series) (Series, error)` | Series transformation |

### R3: Preprocessing Functions

| Function | Parameters | Behavior |
|---|---|---|
| `Resample` | `rate time.Duration` | Linear interpolation to regular grid |
| `ZNormalize` | none | Mean=0, StdDev=1; constant series returns zeros |
| `BaselineCorrect` | `windowPct float64` | Moving-average baseline subtraction |
| `MarkGaps` | `maxInterp time.Duration` | Identify gaps exceeding threshold |
| `Derivative` | none | First differences (dv/dt); requires len >= 2 |

### R4: Invariant Computation

`ComputeInvariants(Series) -> InvariantSet` computes: duration, min, max, mean, stddev, area (trapezoidal), and a quantized histogram.

### R5: Distance / Alignment Algorithms (Zig ABI)

| Algorithm | Key Parameters | Properties |
|---|---|---|
| Constrained DTW | `Band int` | Returns `Alignment`; Sakoe-Chiba corridor |
| Derivative DTW | `Band int` | DTW on derivative representation; offset-invariant |
| Open-End DTW | `Band int` | Partial alignment for truncated series |
| Shape DTW | `Band int`, `DescriptorLen int` | Local shape descriptor matching |
| Soft DTW | `Gamma float64` | Differentiable; returns scalar distance only |
| LB_Keogh | `Band int` | Lower bound on DTW (for pruning); must satisfy `LB <= DTW` |
| Cross-Correlation | none | Returns `(lag int, correlation float64)` |
| SBD | none | Shape-based distance; shift-invariant |
| LCSS | `Epsilon float64`, `Delta int` | Gap-tolerant; for missing data |
| EDR | `Epsilon float64` | Edit Distance on Real sequences |
| ERP | `GapValue float64` | Edit distance with Real Penalty; metric |
| TWED | `Lambda float64`, `Nu float64` | Time Warp Edit Distance; requires timestamps; metric |
| Matrix Profile | `WindowLen int` | All-subsequence nearest-neighbor profile + indices |
| MPDist | `WindowLen int` | Robust series distance via matrix profile |

Required mathematical properties (verified by property tests):
- DTW: symmetric, non-negative, identity of indiscernibles
- LB_Keogh: always <= DTW distance for same band
- ERP: triangle inequality
- TWED: triangle inequality
- All distances: symmetric

### R6: Feature Extraction

`ExtractFeatures(Series) -> [22]float64` produces a fixed-length feature vector.
`CosineSimilarity(a, b []float64) -> float64` for comparing feature vectors.

### R7: PELT Segmentation

`PELTSegmenter` with `Penalty float64` and `MinSize int`. Implements `Segmenter` interface. Produces change-point segments with confidence scores.

### R8: Candidate Generation (`match` package -- Go-side)

`HybridCandidateGenerator` with duration-ratio gating, range-ratio gating, top-K selection, and optional embedding similarity ranking.

### R9: Scoring (`match` package -- Go-side)

`FellegiSunter` logistic-regression scorer:
- Configurable match/reject thresholds
- Default weights `[-1.0, 0.5, 0.5]`
- `Train(positives, negatives []Evidence)` for weight fitting
- `Decide(score) -> MatchDecision`

### R10: Pipeline Orchestration (`match` package -- Go-side)

4-stage pipeline: Preprocess -> Segment -> Score Pairs -> Group. Functional options pattern. Aligner is required; all others optional.

### R11: Event Emission (`ts` root -- Go-side)

Go-specific `TS` emitter with:
- Per-emit timeout (default 50ms)
- Buffered/unbuffered channels
- Metadata extraction via `Data` interface
- Statistics tracking (emitted/sent/dropped/filtered)
- Event filtering
- `BatchEmitter` with size-based and timer-based flush

### R12: Stream Windowing (`stream` package -- Go-side)

| Windower | Strategy |
|---|---|
| `Tumbling` | Non-overlapping fixed-duration windows |
| `Session` | Inactivity-gap-based windows |
| `Watermark` | Event-time windows with allowed lateness |

`Adapter` bridges emitter -> windower -> pipeline -> results channel.

### R13: Clustering (`cluster` package -- Go-side)

| Grouper | Algorithm |
|---|---|
| `ComponentsGrouper` | BFS connected components with threshold; same-source records never cluster |
| `CorrelationClusterer` | Pivot-based (Ailon-Charikar-Newman 2008) with must-link/cannot-link constraints |

### R14: Evaluation (`eval` package -- Go-side)

| Metric | What it measures |
|---|---|
| `PairwiseMetrics` | Precision, recall, F1 on pairwise match decisions |
| `ClusterMetrics` | ARI, B-cubed (precision/recall/F1), purity, fragmentation |
| `CalibrationMetrics` | Expected Calibration Error (ECE) with reliability bins |
| `RetrievalMetrics` | Recall@K, MRR |
| Perturbation types | ClockDrift, MissingInterval, AmplitudeScale, BaselineOffset, GaussianNoise, Truncation, Resample |
| `DegradationCurve` | Score vs perturbation magnitude |
| `RunAblation` | Compare pipeline variants with cluster metrics |
| `GenerateSynthetic` | Deterministic synthetic ground-truth data generation |

## Concrete Gaps

### Open

| ID | Gap | Evidence | Impact | Required fix |
|---|---|---|---|---|
| G-02 | GQL integration mixed in subsystem tree | `src/timeseries/gql_functions.zig:76` | Risks over-extraction | Keep query-language bindings in Geode |

G-02 is an architectural boundary decision, not a code gap. GQL bindings stay in Geode by design. **Status: Won't Do** -- this is the intended architecture.

---

### GAP-0011: queryRange decompression stubbed
- **Status: Closed** (2026-03-22)
- **Issue:** [#3](https://gitlab.com/devnw/zig/timeseries/-/issues/3)
- **Category:** Feature/Partial
- **Severity:** Critical
- **Resolution:** Implemented `GorillaDecoder` struct in `src/chunk_storage.zig` that reverses the Gorilla encoding (delta-of-delta timestamps, XOR value compression). Wired decoder into `queryRange` to read compressed chunks from disk, decompress, and filter to requested time range. Added 7 unit tests (encode-decode round-trip, epoch-zero, large deltas, single point, queryRange round-trip, partial range, nonexistent series) and 2 integration tests (write-query round-trip, retention pipeline).

### GAP-0012: 8 Go reference types missing
- **Status: Closed** (2026-03-22)
- **Issue:** [#5](https://gitlab.com/devnw/zig/timeseries/-/issues/5)
- **Category:** Requirement
- **Severity:** High
- **Resolution:** Added `Gap`, `Segment`, `Evidence`, and `MatchDecision` types to `src/types.zig`. The `Series` type with `len()`, `empty()`, `slice()` methods was added to `src/store.zig`. Go-pipeline-only types (`Record`, `Cluster`, `PipelineStats`, `MatchResult`) are deferred by design -- they are used exclusively in the Go-side `match`, `cluster`, and `eval` packages, not in the Zig ABI layer. The 7 Zig-relevant types from R1 are now implemented.

### GAP-0013: Series Len/Empty/Slice methods missing
- **Status: Closed** (2026-03-22)
- **Issue:** [#5](https://gitlab.com/devnw/zig/timeseries/-/issues/5)
- **Category:** Requirement
- **Severity:** Medium
- **Resolution:** Added `Series` struct to `src/store.zig` with `len()`, `empty()`, and `slice(start, end)` methods. `len()` returns the number of values, `empty()` returns true when `values.len == 0`, and `slice()` returns a new Series with sub-slices of both `times` and `values`. Tests verify all three methods including boundary conditions.

### GAP-0014: No fuzz tests
- **Status: Closed** (2026-03-22)
- **Issue:** [#21](https://gitlab.com/devnw/zig/timeseries/-/issues/21)
- **Category:** Test
- **Severity:** High
- **Resolution:** Implemented `tests/fuzz.zig` with 3 `std.testing.fuzz` targets (`constrainedDTW`, `crossCorrelate`, `pelt`) that convert raw fuzz bytes into f64 array pairs and verify no crash, non-negative distances, and valid return codes. Added 7 deterministic property-based tests with seeded PRNG covering DTW symmetry, DTW non-negativity, DTW identity, LB_Keogh <= DTW bound, ERP triangle inequality, cross-correlation symmetry, and PELT no-crash. Added `fuzz` build step to `build.zig`. All 10 tests pass in normal mode; corpus + empty-input smoke tests run automatically.

### GAP-0015: No benchmarks
- **Status: Closed** (2026-03-22)
- **Issue:** [#25](https://gitlab.com/devnw/zig/timeseries/-/issues/25)
- **Category:** Test
- **Severity:** High
- **Resolution:** Implemented `tests/bench.zig` with 9 benchmarks: DTW at 100/500/1000 points, CrossCorrelate, PELT, ExtractFeatures, InvariantCompute, ZNormalize, and ERP (all at 500 points). Each benchmark uses deterministic test data (sine, ramp, step functions), runs warmup + timed iterations, and reports min/mean/max ns/op. Uses volatile sink to prevent dead code elimination. Compiled with `ReleaseFast` for accurate timing via `zig build bench`. Added `bench` build step to `build.zig`. All internal functions called with `page_allocator` as required.

### GAP-0016: TestTWEDNoTimestamps not covered
- **Status: Won't Do**
- **Issue:** [#19](https://gitlab.com/devnw/zig/timeseries/-/issues/19)
- **Category:** Test/Design
- **Severity:** Low
- **Reason:** Design decision -- the Zig ABI requires timestamp arrays for TWED (`ts_twed` signature includes `a_times` and `b_times` parameters). This is an intentional divergence from the Go reference which allowed nil timestamps. Go callers must provide valid timestamps. The ABI boundary validation (GAP-0021/S7) now rejects NaN/Inf inputs, ensuring timestamp validity.

### GAP-0017: TestCosineSimilarityMismatch not covered
- **Status: Won't Do**
- **Issue:** [#19](https://gitlab.com/devnw/zig/timeseries/-/issues/19)
- **Category:** Test/Design
- **Severity:** Low
- **Reason:** Design decision -- the Zig ABI uses a single `len` parameter for both vectors in `ts_cosine_similarity`, making length mismatch structurally impossible at the C ABI level. Go-side validation handles the mismatch check before calling into the ABI. This is a deliberate API simplification that eliminates a class of errors by construction.

### GAP-0018: Missing e2e round-trip store/chunk tests
- **Status: Closed** (2026-03-23)
- **Issue:** [#17](https://gitlab.com/devnw/zig/timeseries/-/issues/17)
- **Category:** Test
- **Severity:** Medium
- **Resolution:** Added 4 integration tests total (2 in previous cycle, 2 in this cycle). `tests/integration.zig` now has 12 tests (up from 8). New tests:
  - **Store aggregation e2e:** Create store, insert 100 points across 2 series, sampleBy with avg, verify aggregated bucket values.
  - **Full pipeline e2e:** Insert data -> zNormalizeAlloc (non-mutating) -> extractFeatures -> verify feature vector properties (length, mean~0, stddev~1, positive slope, histogram sums to 1).

### GAP-0019: Documentation stubs and broken links
- **Status: Closed** (2026-03-23)
- **Issue:** [#27](https://gitlab.com/devnw/zig/timeseries/-/issues/27)
- **Category:** Docs
- **Severity:** Medium
- **Resolution:** Verified all links in `docs/README.md` point to existing files (GAP_ANALYSIS.md, REQUIREMENTS.md, QUALITY_GAP_ANALYSIS.md, PERF_GAP_ANALYSIS.md, SECURITY_GAP_ANALYSIS.md, CONTRIBUTING.md, SECURITY.md, CHANGELOG.md). No broken links remain. Updated `examples/basic.zig` from a non-functional placeholder to a comprehensive overview of library capabilities (Store, preprocessing, feature extraction, distance algorithms, PELT segmentation, chunk storage, C ABI).

### GAP-0020: 8192-point silent limit undocumented
- **Status: Closed** (2026-03-22)
- **Issue:** [#31](https://gitlab.com/devnw/zig/timeseries/-/issues/31)
- **Category:** Bug
- **Severity:** High
- **Resolution:** Replaced all three `[8192]f64` stack buffers with `page_allocator`-backed dynamic allocations in `baselineCorrect` (preprocess.zig), `extractFeatures` (features.zig), and `mpDist` (matrix_profile.zig). All allocations are freed via `defer`. Added boundary tests at 8193 points for each function, verifying correct results instead of silent failure.

### GAP-0021: No ABI input validation for negative/null
- **Status: Closed** (2026-03-22)
- **Issue:** [#33](https://gitlab.com/devnw/zig/timeseries/-/issues/33)
- **Category:** Security
- **Severity:** Critical
- **Resolution:** Implemented Batch 1 Critical Security hardening across the entire ABI surface:
  - **S1: Negative length guards** -- Added `if (a_len <= 0 or b_len <= 0) return -1` (or `return 0` for f64-returning functions) BEFORE any `@intCast` in all 17 internal functions across `dtw.zig`, `distances.zig`, `matrix_profile.zig`, `features.zig`, `pelt.zig`. This prevents negative i32 values from being cast to huge usize values.
  - **S4+S13: Integer overflow checked multiplication** -- Replaced all `n * m` in allocation calls with `std.math.mul(usize, n, m) catch return -1` in `dtw.zig` (4 sites) and `distances.zig` (4 sites).
  - **S3: Quadratic memory exhaustion cap** -- Added `MAX_ALLOC_ELEMENTS` (256 MB / 8 = ~33.5M f64 elements) constant in `dtw.zig` and `MAX_ALLOC_F64`/`MAX_ALLOC_I32` in `distances.zig`. All allocations check against the cap before proceeding.
  - **S7: NaN/Inf input validation** -- Added `validateFinite()` helper in `abi.zig` that scans input arrays for NaN/Inf values. Called at the ABI boundary in all 17 data-processing functions before delegating to internal implementations.
  - **S8+S9+S10: Filesystem hardening** -- Added `InvalidPath` error and path traversal rejection (`".."` substring check) in `ChunkStorage.init`. Added explicit `mode = 0o600` to `createFile`.
  - **S16: CPU DoS length cap** -- Added `MAX_SERIES_LEN = 100_000` in `matrix_profile.zig`. Both `matrixProfile` and `mpDist` reject inputs exceeding this limit.
  - **Tests:** Added 47 new security tests across all test files covering negative lengths, NaN/Inf inputs, path traversal rejection, and series length caps.

### Closed (2026-03-22)

| ID | Gap | Resolution |
|---|---|---|
| G-01 | Standalone build fails on Zig API drift | Ported Geode's `timeseries.zig` into `src/store.zig`. Fixed all `ArrayList.init(allocator)` to Zig 0.15 unmanaged API (default init `{}`, pass allocator per call). Fixed anonymous struct return types to named types (`SampleRow`, `BucketAvgRow`). All 4 original Geode tests pass. |
| G-03 | Chunk storage is filesystem-backed | Ported Geode's `chunk_storage.zig` into `src/chunk_storage.zig`. Fixed `ArrayList` and `DynamicBitSet` to 0.15 APIs. Fixed `@bitCast` size mismatches for Gorilla delta-of-delta encoding. Used `getOrPut` for index map updates. FS dependencies kept explicit (`data_dir` parameter, `chunks.dat` file). Both compression and retention tests pass. |
| G-04 | No C ABI header (`ts_abi.h`) | Created `src/ts_abi.h` with 18 function declarations and `src/abi.zig` C ABI export layer. Build produces `libai_ts.so` and `libai_ts.a` in `zig-out/lib/`, header in `zig-out/include/`. |
| G-05 | No distance/alignment algorithms | Implemented all 14 algorithms in `src/dtw.zig` (constrained DTW, derivative DTW, open-end DTW, shape DTW, soft DTW, LB_Keogh), `src/distances.zig` (cross-correlation, SBD, LCSS, EDR, ERP, TWED), `src/matrix_profile.zig` (matrix profile, MPDist). 18 ABI functions exported. |
| G-06 | No preprocessing functions | Implemented resample, zNormalize, baselineCorrect, markGaps, derivative in `src/preprocess.zig`. |
| G-07 | No invariant computation | Implemented computeInvariants (duration, min, max, mean, stddev, area, histogram) in `src/invariants.zig`. |
| G-08 | No feature extraction | Implemented 22-element extractFeatures and cosineSimilarity in `src/features.zig`. |
| G-09 | No PELT segmentation | Implemented PELT change-point detection with penalty and min_size in `src/pelt.zig`. |
| G-10 | No property tests for distance functions | 93 tests implemented: DTW symmetry/non-negativity/identity, LB_Keogh <= DTW bound, ERP triangle inequality, TWED triangle inequality/symmetry, all-distance symmetry, plus unit tests for all ABI functions, preprocessing, invariants, features, PELT, store (4 tests), chunk_storage (2 tests), and 8 integration tests. |
| Q10 | GorillaEncoder epoch-zero sentinel bug | Added `point_count` field to `GorillaEncoder`. Changed first-point detection from `if (self.prev_ts == 0)` to `if (self.point_count == 0)`, fixing silent data corruption for timestamp=0. Test `gorilla: encode-decode epoch-zero timestamp` verifies round-trip with ts=0. |

## Tests to Implement (from Go reference)

### Zig ABI Tests (port from `series/abi_test.go` -- 42 tests)

| Test | Behavior verified |
|---|---|
| `TestABIVersion` | Library version string |
| `TestConstrainedDTWIdentical` | Zero distance for identical series |
| `TestConstrainedDTWDifferent` | Positive distance for different series |
| `TestConstrainedDTWEmpty` | Graceful empty-series handling |
| `TestConstrainedDTWImplementsAligner` | Interface conformance |
| `TestDerivativeDTWIdentical` | Zero distance on derivatives |
| `TestDerivativeDTWImplementsAligner` | Interface conformance |
| `TestOpenEndDTWIdentical` | Partial alignment identity |
| `TestOpenEndDTWImplementsAligner` | Interface conformance |
| `TestShapeDTWIdentical` | Shape descriptor identity |
| `TestShapeDTWImplementsAligner` | Interface conformance |
| `TestSoftDTWIdentical` | Zero soft-DTW distance |
| `TestSoftDTWEmpty` | Empty-series handling |
| `TestLBKeogh` | Lower bound computation |
| `TestLBKeoghLowerBound` | `LB <= DTW` property |
| `TestLBKeoghEmpty` | Empty-series handling |
| `TestCrossCorrelateIdentical` | Lag=0, correlation=1 for identical |
| `TestCrossCorrelateEmpty` | Empty-series handling |
| `TestSBDIdentical` | Zero distance for identical |
| `TestSBDEmpty` | Empty-series handling |
| `TestPELTSegmenter` | Change-point detection |
| `TestPELTSegmenterEmpty` | Empty-series handling |
| `TestPELTSegmenterImplementsSegmenter` | Interface conformance |
| `TestLCSS` | LCSS distance computation |
| `TestLCSSEmpty` | Empty-series handling |
| `TestEDR` | EDR distance computation |
| `TestEDREmpty` | Empty-series handling |
| `TestERP` | ERP distance computation |
| `TestERPEmpty` | Empty-series handling |
| `TestTWED` | TWED distance with timestamps |
| `TestTWEDNoTimestamps` | Behavior without timestamps |
| `TestTWEDEmpty` | Empty-series handling |
| `TestMatrixProfile` | Profile and index computation |
| `TestMatrixProfileEmpty` | Empty-series handling |
| `TestMatrixProfileWindowTooLarge` | Validation error |
| `TestMPDist` | Matrix-profile distance |
| `TestMPDistEmpty` | Empty-series handling |
| `TestExtractFeatures` | 22-element feature vector |
| `TestExtractFeaturesEmpty` | Empty-series handling |
| `TestCosineSimilarityIdentical` | Similarity = 1.0 |
| `TestCosineSimilarityOrthogonal` | Similarity = 0.0 |
| `TestCosineSimilarityEmpty` | Empty-vector handling |
| `TestCosineSimilarityMismatch` | Mismatched length error |
| `TestExtractFeaturesAndCosineSimilarity` | End-to-end feature+similarity |

### Property Tests (port from `series/property_test.go` -- 7 tests)

| Test | Property verified |
|---|---|
| `TestDTWSymmetry` | `DTW(a,b) == DTW(b,a)` |
| `TestDTWNonNegativity` | `DTW(a,b) >= 0` |
| `TestDTWIdentity` | `DTW(a,a) == 0` |
| `TestLBKeoghBound` | `LBKeogh(a,b) <= DTW(a,b)` |
| `TestERPTriangleInequality` | `ERP(a,c) <= ERP(a,b) + ERP(b,c)` |
| `TestTWEDTriangleInequality` | `TWED(a,c) <= TWED(a,b) + TWED(b,c)` |
| `TestDistanceSymmetry` | All distances symmetric |

### Fuzz Tests (port from `series/fuzz_test.go` -- 3 tests)

| Test | What it fuzzes |
|---|---|
| `FuzzDTW` | Random series pairs through DTW |
| `FuzzCrossCorrelate` | Random series pairs through cross-correlation |
| `FuzzPELT` | Random series through PELT segmentation |

### Preprocessing Tests (port from `series/preprocess_test.go` -- 7 tests)

| Test | Behavior verified |
|---|---|
| `TestResample` | Linear interpolation to regular grid |
| `TestZNormalize` | Mean=0, StdDev=1 output |
| `TestZNormalizeConstant` | Constant series -> zeros |
| `TestBaselineCorrect` | Baseline subtraction accuracy |
| `TestMarkGaps` | Gap identification at threshold |
| `TestDerivative` | First-difference calculation |
| `TestDerivativeTooShort` | Error for series < 2 points |

### Invariant Tests (port from `series/invariants_test.go` -- 5 tests)

| Test | Behavior verified |
|---|---|
| `TestComputeInvariants` | Full invariant set computation |
| `TestComputeInvariantsEmpty` | Empty series handling |
| `TestComputeInvariantsSinglePoint` | Single-point edge case |
| `TestComputeInvariantsConstant` | Constant series (stddev=0) |
| `TestComputeInvariantsHistogram` | Histogram bin distribution |

### Type Tests (port from `series/types_test.go` -- 7 tests)

| Test | Behavior verified |
|---|---|
| `TestSeriesLen` | Length computation |
| `TestSeriesEmpty` | Empty detection |
| `TestSeriesNonEmpty` | Non-empty detection |
| `TestSeriesSlice` | Sub-series extraction |
| `TestGapContains` | Gap range check |
| `TestPathPointString` | String formatting |
| `TestMatchDecisionString` | Enum string conversion |

### Benchmarks to Port (from `series/bench_test.go` -- 9 benchmarks)

| Benchmark | What it measures |
|---|---|
| `BenchmarkDTW100` | DTW on 100-point series |
| `BenchmarkDTW500` | DTW on 500-point series |
| `BenchmarkDTW1000` | DTW on 1000-point series |
| `BenchmarkCrossCorrelate` | Cross-correlation throughput |
| `BenchmarkPELT` | PELT segmentation throughput |
| `BenchmarkExtractFeatures` | Feature extraction throughput |
| `BenchmarkInvariantCompute` | Invariant computation throughput |
| `BenchmarkZNormalize` | Z-normalization throughput |
| `BenchmarkERP` | ERP distance throughput |

### Geode Tests to Carry Over

| Geode test / benchmark | Coverage provided |
|---|---|
| `src/timeseries/timeseries.zig:255`, `:267`, `:279`, `:319` | Core store and aggregation unit tests |
| `src/timeseries/chunk_storage.zig:348`, `:380` | Chunk compression and retention tests |
| `tests/e2e_timeseries.zig:6`, `:80`, `:139`, `:188` | End-to-end store, chunk storage, retention, and GQL integration flows |
| `tests/e2e_timeseries.zig:335` | Performance benchmark reference |
| `src/timeseries/gql_functions.zig:339`, `:370` | Keep in Geode or port later if optional query adapter added |

## Proposed Public API

### Zig Library API

Core types:
- `Point`, `SeriesKey`, `Series`, `Gap`, `Segment`, `Alignment`, `PathPoint`
- `InvariantSet`, `Evidence`, `Record`, `Cluster`, `MatchDecision`

Store (from Geode):
- `Store`, `insertMany`, `sampleBy`, `timeBucketAvg`

Chunk storage (from Geode):
- `ChunkConfig`, `ChunkStorage`, `writePoints`, `queryRange`, `runRetention`

Preprocessing:
- `resample`, `zNormalize`, `baselineCorrect`, `markGaps`, `derivative`

Invariants:
- `computeInvariants`

Distance/alignment:
- `constrainedDTW`, `derivativeDTW`, `openEndDTW`, `shapeDTW`, `softDTW`
- `lbKeogh`, `crossCorrelate`, `sbd`
- `lcss`, `edr`, `erp`, `twed`
- `matrixProfile`, `mpDist`

Features:
- `extractFeatures`, `cosineSimilarity`

Segmentation:
- `peltSegment`

### C ABI Surface

All 18 functions listed in the ABI table above, compiled into `libai_ts` for CGO consumption.

## Extraction Plan

1. Fix the standalone Zig drift in `timeseries.zig` (G-01).
2. Move the store and chunk-storage modules into this repo from Geode (G-03).
3. Implement core types matching Go `series` package (R1, R2).
4. Implement preprocessing functions (R3, G-06).
5. Implement invariant computation (R4, G-07).
6. Implement distance/alignment algorithms (R5, G-05).
7. Implement feature extraction (R6, G-08).
8. Implement PELT segmentation (R7, G-09).
9. Expose C ABI header and `libai_ts` shared library (G-04).
10. Port all Zig-side tests from Go reference (G-10).
11. Port Geode unit tests and e2e storage tests.
12. Keep GQL function bindings in Geode.
13. Rewire Geode's GQL integration to import this repo.

## Acceptance Criteria

- This repo builds and tests standalone with `zig build test`.
- All 18 C ABI functions pass Go-side integration tests (`go test -tags zig ./...`).
- Property tests verify mathematical invariants (symmetry, triangle inequality, LB bounds).
- Fuzz tests run without crashes.
- Benchmarks establish baseline performance for DTW at 100/500/1000 points.
- Geode keeps only the GQL-facing adapter locally.
- The performance reference in `tests/e2e_timeseries.zig:335` remains within acceptable delta.
