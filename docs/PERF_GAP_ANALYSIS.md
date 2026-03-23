# Performance Gap Analysis -- Zig Timeseries Library

Last updated: 2026-03-22

## Summary

**Total findings**: 16 (grouped into 13 issues)

**Cycle status (2026-03-22):** 9 findings closed (P6 -- page_allocator via Q5; Batch C quick wins: softDTW 2-row, LCSS/EDR/ERP/TWED 2-row, LB_Keogh deque, Store.insertMany merge, baselineCorrect prefix sum, PELT segmentCost cache; P13 -- SIMD cosineSimilarity), 6 deferred to performance optimization cycle.

| PerfSeverity | Count | Description |
|-------------|-------|-------------|
| P0          | 3     | SLO breach / outage risk -- immediate action required |
| P1          | 5     | Material user-facing impact -- within sprint |
| P2          | 6     | Moderate impact -- next quarter |
| P3          | 1     | Minor optimization -- backlog |

**Top 5 risks by expected impact:**

1. **Matrix profile STOMP** (P1+P2): 100-260x speedup, PerfScore 100 -- brute-force O(plen^2*w) is unusable for n>1000
2. **FFT cross-correlation** (P3): 10-250x speedup, PerfScore 80 -- blocks SBD clustering at scale
3. **softDTW memory blow-up** (P4): 2500x memory reduction, PerfScore 64 -- 200MB for 5000-point series
4. **DP 2-row optimization** (P5): 2500x memory reduction across 4 algorithms, PerfScore 64
5. **LB_Keogh deque** (P6): 10-100x speedup proportional to band width, PerfScore 64

## Stack-Ranked Findings

| Rank | Severity | PerfScore | Finding | Component | Evidence | Est. Speedup | Issue | Fix Summary | Confidence | Status |
|------|----------|-----------|---------|-----------|----------|-------------|-------|-------------|------------|--------|
| 1 | P0 | 100 | Matrix profile brute-force + mpDist hard limit | matrix_profile.zig | O(plen^2*w) loops, lines 26-83, 111-153 | 100-260x | [#32](https://gitlab.com/devnw/zig/timeseries/-/issues/32) | Implement STOMP with incremental QT updates | confirmed | Open |
| 2 | P0 | 80 | Cross-correlation brute-force O(n^2) | distances.zig:56-75 | 2*max_lag iterations * O(n) per lag | 10-250x | [#36](https://gitlab.com/devnw/zig/timeseries/-/issues/36) | FFT-based O(n log n) cross-correlation | confirmed | **Closed** (2026-03-22). Radix-2 Cooley-Tukey FFT for inputs >= 64; brute-force fallback for small inputs and allocation failure. |
| 3 | P0 | 64 | softDTW full n*m matrix, no backtracking | dtw.zig:301-371 | alloc(f64, n*m), only final cell read | 3-8x speed, 2500x memory | [#39](https://gitlab.com/devnw/zig/timeseries/-/issues/39) | 2-row rolling buffer | confirmed | **Closed** (2026-03-22). Replaced n*m allocation with two rows of length m; prev/curr swap via @memcpy. |
| 4 | P1 | 64 | LCSS/EDR/ERP/TWED full DP matrix | distances.zig:103-290 | 4x alloc((n+1)*(m+1)), no backtracking | 3-8x speed, 2500x memory | [#44](https://gitlab.com/devnw/zig/timeseries/-/issues/44) | 2-row rolling buffer for all four | confirmed | **Closed** (2026-03-22). All four functions (LCSS/EDR/ERP/TWED) now use 2-row rolling buffers. |
| 5 | P1 | 64 | LB_Keogh O(n*w) inline envelope | dtw.zig:374-530 | Inner loop scans full band per point | 10-100x (prop. to w) | [#47](https://gitlab.com/devnw/zig/timeseries/-/issues/47) | Monotonic deque O(n) envelope | confirmed | **Closed** (2026-03-22). Monotonic deque O(n) envelope for series up to 8192; O(n*w) fallback for larger. |
| 6 | P1 | 60 | 22 page_allocator mmap/munmap syscalls | dtw.zig:8, distances.zig:8, pelt.zig:8 | page_alloc used at 22 allocation sites | ~2x for small series | [#50](https://gitlab.com/devnw/zig/timeseries/-/issues/50) | Caller-provided allocator / arena | confirmed | **Closed** (2026-03-22). All internal functions accept std.mem.Allocator param (via Q5/#41). ABI wrappers pass page_allocator. |
| 7 | P1 | 60 | No benchmarking infrastructure | build.zig (missing bench step) | No bench step, no benchmark files | N/A (infra) | [#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58) | Add bench step + parameterized benchmarks | confirmed | Open |
| 8 | P1 | 48 | Store.insertMany full re-sort | store.zig:139-170 | pdq sort on entire array after append | ~20x for incremental | [#54](https://gitlab.com/devnw/zig/timeseries/-/issues/54) | Sort batch + merge O(n+k) | confirmed | **Closed** (2026-03-22). Fast-path: if batch is sorted and all timestamps >= last existing, skip full re-sort. Fallback: full pdq sort for unordered/overlapping batches. |
| 9 | P2 | 48 | Matrix profile parallelization | matrix_profile.zig:26 | Embarrassingly parallel outer loop | Linear with cores (~8x) | [#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70) | Thread pool over row ranges | suspected | Open |
| 10 | P2 | 36 | GorillaEncoder per-bit writes | chunk_storage.zig:134-148 | writeBit called per bit via DynamicBitSet | ~6x fewer ops | [#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62) | Word-level batch writes | confirmed | Open |
| 11 | P2 | 36 | getCompressedData bit-by-bit extraction | chunk_storage.zig:154-169 | 8 bit reads per byte output | ~100x with memcpy | [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64) | Direct word buffer memcpy | confirmed | Open |
| 12 | P2 | 36 | baselineCorrect O(n*w) sliding window | preprocess.zig:90-122 | Full window re-sum per point | ~w (window size) | [#68](https://gitlab.com/devnw/zig/timeseries/-/issues/68) | Prefix sum O(n) | confirmed | **Closed** (2026-03-22). Replaced inner-loop summation with prefix sum array for O(n) baseline computation. |
| 13 | P2 | 36 | No SIMD exploitation (0 @Vector uses) | features.zig:122-133 | Scalar f64 reductions on contiguous arrays | 4-8x for vectorizable loops | [#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72) | @Vector(4, f64) for inner loops | suspected | **Closed** (2026-03-22). cosineSimilarity uses @Vector(4, f64) for dot/norm accumulation with scalar remainder loop. |
| 14 | P2 | 24 | PELT segmentCost called twice per candidate | pelt.zig:79-108 | Same segmentCost(s,t) in optimize + prune | ~1.2-1.5x | [#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67) | Cache cost per candidate | suspected | **Closed** (2026-03-22). Added cost_cache array; optimization loop stores segmentCost, pruning loop reuses it. Falls back to computing for min_size-skipped candidates. |
| 15 | P3 | 24 | extractFeatures 4+ separate passes | features.zig:25-80 | 6 loops over values array | ~2-3x fewer cache misses | [#74](https://gitlab.com/devnw/zig/timeseries/-/issues/74) | Fuse passes 2-6 into single pass | suspected | Open |

## Findings by Area

### Application (src/)

| Finding | File | Severity | PerfScore | Status |
|---------|------|----------|-----------|--------|
| Matrix profile STOMP | matrix_profile.zig | P0 | 100 | Open |
| FFT cross-correlation | distances.zig | P0 | 80 | **Closed** |
| softDTW 2-row | dtw.zig | P0 | 64 | **Closed** |
| LCSS/EDR/ERP/TWED 2-row | distances.zig | P1 | 64 | **Closed** |
| LB_Keogh deque | dtw.zig | P1 | 64 | **Closed** |
| Store.insertMany merge | store.zig | P1 | 48 | **Closed** |
| Matrix profile parallelization | matrix_profile.zig | P2 | 48 | Open |
| GorillaEncoder batch writes | chunk_storage.zig | P2 | 36 | Open |
| getCompressedData memcpy | chunk_storage.zig | P2 | 36 | Open |
| baselineCorrect running sum | preprocess.zig | P2 | 36 | **Closed** |
| SIMD exploitation | features.zig + others | P2 | 36 | **Closed** |
| PELT segmentCost cache | pelt.zig | P2 | 24 | **Closed** |
| extractFeatures single-pass | features.zig | P3 | 24 | Open |

### Infrastructure (build/CI)

| Finding | File | Severity | PerfScore |
|---------|------|----------|-----------|
| page_allocator syscalls | dtw.zig, distances.zig, pelt.zig | P1 | 60 |
| No benchmarking infrastructure | build.zig | P1 | 60 |

## Optimization Roadmap

### Quick Wins (< 1 day each)

These are mechanical refactors with high confidence and low risk:

| Priority | Finding | Issue | Est. Effort | Expected Gain | Status |
|----------|---------|-------|-------------|---------------|--------|
| 1 | softDTW 2-row optimization | [#39](https://gitlab.com/devnw/zig/timeseries/-/issues/39) | 2 hours | 3-8x speed, 2500x memory | **DONE** (2026-03-22) |
| 2 | LCSS/EDR/ERP/TWED 2-row | [#44](https://gitlab.com/devnw/zig/timeseries/-/issues/44) | 4 hours (4 functions) | 3-8x speed, 2500x memory each | **DONE** (2026-03-22) |
| 3 | LB_Keogh deque envelope | [#47](https://gitlab.com/devnw/zig/timeseries/-/issues/47) | 2 hours | 10-100x proportional to w | **DONE** (2026-03-22) |
| 4 | PELT segmentCost caching | [#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67) | 30 min | ~1.2-1.5x | **DONE** (2026-03-22) |
| 5 | baselineCorrect running sum | [#68](https://gitlab.com/devnw/zig/timeseries/-/issues/68) | 1 hour | ~w (window size) | **DONE** (2026-03-22) |
| 6 | Store.insertMany merge | [#54](https://gitlab.com/devnw/zig/timeseries/-/issues/54) | 2 hours | ~20x for incremental | **DONE** (2026-03-22) |

### Medium (1-5 days each)

These require more design but have confirmed high impact:

| Priority | Finding | Issue | Est. Effort | Expected Gain |
|----------|---------|-------|-------------|---------------|
| 1 | Benchmarking infrastructure | [#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58) | 2 days | Enables all measurement |
| ~~2~~ | ~~Replace page_allocator~~ | ~~[#50](https://gitlab.com/devnw/zig/timeseries/-/issues/50)~~ | ~~2 days~~ | **DONE** (2026-03-22, via Q5/#41) |
| 3 | GorillaEncoder + getCompressedData | [#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62), [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64) | 3 days | 6-100x for compression |
| 4 | extractFeatures single-pass | [#74](https://gitlab.com/devnw/zig/timeseries/-/issues/74) | 1 day | ~2-3x |

### Strategic (> 5 days each)

These are algorithmic rewrites with the highest absolute impact:

| Priority | Finding | Issue | Est. Effort | Expected Gain |
|----------|---------|-------|-------------|---------------|
| 1 | STOMP for matrix profile | [#32](https://gitlab.com/devnw/zig/timeseries/-/issues/32) | 5-7 days | 100-260x |
| ~~2~~ | ~~FFT cross-correlation~~ | ~~[#36](https://gitlab.com/devnw/zig/timeseries/-/issues/36)~~ | ~~5-7 days (FFT impl)~~ | **DONE** (2026-03-22) |
| 3 | Matrix profile parallelization | [#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70) | 3-5 days (after STOMP) | Linear with cores |
| 4 | SIMD @Vector exploitation | [#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72) | 3-5 days | 4-8x for inner loops |

### Recommended Execution Order

1. **Week 1**: Benchmarking infrastructure ([#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58)) -- gates all measurement
2. ~~**Week 1**: Quick wins ([#39](https://gitlab.com/devnw/zig/timeseries/-/issues/39), [#44](https://gitlab.com/devnw/zig/timeseries/-/issues/44), [#47](https://gitlab.com/devnw/zig/timeseries/-/issues/47), [#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67), [#68](https://gitlab.com/devnw/zig/timeseries/-/issues/68), [#54](https://gitlab.com/devnw/zig/timeseries/-/issues/54))~~ -- **DONE** (2026-03-22, Batch C)
3. ~~**Week 2**: Allocator refactor ([#50](https://gitlab.com/devnw/zig/timeseries/-/issues/50))~~ -- **DONE** (2026-03-22, via Q5/#41)
4. **Week 3-4**: STOMP ([#32](https://gitlab.com/devnw/zig/timeseries/-/issues/32)) -- highest absolute gain
5. ~~**Week 5-6**: FFT cross-correlation ([#36](https://gitlab.com/devnw/zig/timeseries/-/issues/36))~~ -- **DONE** (2026-03-22)
6. **Quarter 2**: Parallelization ([#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70)), SIMD ([#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72)), Gorilla compression ([#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62), [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64))

## Unknowns and Blockers

1. **No benchmark data**: All speedup estimates are theoretical until [#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58) is resolved. Actual measurements may differ.
2. **Auto-vectorization**: Zig with `-OReleaseFast` may already auto-vectorize some loops ([#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72)). Measure before investing in manual SIMD.
3. **Memory bandwidth saturation**: Parallelization gains ([#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70)) may plateau before core count if memory bandwidth is the bottleneck. Measure with varying thread counts.
4. ~~**FFT implementation complexity**: A correct, performant FFT in Zig is non-trivial.~~ **Resolved (2026-03-22):** Radix-2 Cooley-Tukey FFT implemented in distances.zig with brute-force fallback for small inputs (< 64 elements) and allocation failure.
5. **Gorilla compression correctness**: ~~The current encoder has no corresponding decoder (queryRange is a stub).~~ **Resolved (2026-03-22):** GorillaDecoder implemented, queryRange fully functional. Optimizing the encoder ([#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62), [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64)) can now proceed independently.

## Confirmation Needed (confidence::suspected)

| Finding | What would confirm it | Issue |
|---------|----------------------|-------|
| Matrix profile parallelization | Benchmark with 1,2,4,8 threads showing linear scaling | [#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70) |
| ~~SIMD @Vector gains~~ | ~~Compare `-OReleaseFast` assembly for cosine_similarity with/without manual @Vector~~ | ~~[#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72)~~ **Closed** (2026-03-22) |
| ~~PELT segmentCost caching~~ | ~~Benchmark showing measurable wall-clock difference~~ | ~~[#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67)~~ **Closed** (2026-03-22) |
| extractFeatures single-pass | Benchmark with n=10000 showing cache-miss reduction via perf stat | [#74](https://gitlab.com/devnw/zig/timeseries/-/issues/74) |
