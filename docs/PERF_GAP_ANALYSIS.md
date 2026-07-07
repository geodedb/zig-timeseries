# Performance Gap Analysis -- Zig Timeseries Library

Last updated: 2026-07-07

## Summary

**Total findings**: 20 (grouped into 17 issues)

**Cycle status (2026-03-23):** 12 findings closed (P6 -- page_allocator via Q5; Batch C quick wins: softDTW 2-row, LCSS/EDR/ERP/TWED 2-row, LB_Keogh deque, Store.insertMany merge, baselineCorrect prefix sum, PELT segmentCost cache; P13 -- SIMD cosineSimilarity; P10 -- GorillaEncoder batch writes; P11 -- getCompressedData bulk extraction; P15 -- extractFeatures single-pass), 1 Won't Do (P9 -- matrix profile parallelization), 3 remaining open.

**Cycle status (2026-07-07, Workstream E):** Task E4 discovered and recorded a new open P2 finding (rank 16 below: mpDist/mpDistAbJoinRow O(w) per-pair dot product) while resolving the `parallelBatchCrossCorrelate` stale-comment reference (now implemented, see rank/Issue table row for cross-correlation batching). Tasks E1-E3 also closed 3 additional perf findings this cycle (rank 17: `saveSeriesKeyMeta` per-insert gate; rank 18: `crossCorrelate`/`sbd` caller allocator; rank 19: `chunk_meta.dat` held-open handle) -- see their rows below. 4 findings remain open.

| PerfSeverity | Count | Description |
|-------------|-------|-------------|
| P0          | 4     | SLO breach / outage risk -- immediate action required |
| P1          | 6     | Material user-facing impact -- within sprint |
| P2          | 8     | Moderate impact -- next quarter |
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
| 2 | P0 | 80 | Cross-correlation brute-force O(n^2) | distances.zig:56-75 | 2*max_lag iterations* O(n) per lag | 10-250x | [#36](https://gitlab.com/devnw/zig/timeseries/-/issues/36) | FFT-based O(n log n) cross-correlation | confirmed | **Closed** (2026-03-22). Radix-2 Cooley-Tukey FFT for inputs >= 64; brute-force fallback for small inputs and allocation failure. |
| 3 | P0 | 64 | softDTW full n*m matrix, no backtracking | dtw.zig:301-371 | alloc(f64, n*m), only final cell read | 3-8x speed, 2500x memory | [#39](https://gitlab.com/devnw/zig/timeseries/-/issues/39) | 2-row rolling buffer | confirmed | **Closed** (2026-03-22). Replaced n*m allocation with two rows of length m; prev/curr swap via @memcpy. |
| 4 | P1 | 64 | LCSS/EDR/ERP/TWED full DP matrix | distances.zig:103-290 | 4x alloc((n+1)*(m+1)), no backtracking | 3-8x speed, 2500x memory | [#44](https://gitlab.com/devnw/zig/timeseries/-/issues/44) | 2-row rolling buffer for all four | confirmed | **Closed** (2026-03-22). All four functions (LCSS/EDR/ERP/TWED) now use 2-row rolling buffers. |
| 5 | P1 | 64 | LB_Keogh O(n*w) inline envelope | dtw.zig:374-530 | Inner loop scans full band per point | 10-100x (prop. to w) | [#47](https://gitlab.com/devnw/zig/timeseries/-/issues/47) | Monotonic deque O(n) envelope | confirmed | **Closed** (2026-03-22). Monotonic deque O(n) envelope for series up to 8192; O(n*w) fallback for larger. |
| 6 | P1 | 60 | 22 page_allocator mmap/munmap syscalls | dtw.zig:8, distances.zig:8, pelt.zig:8 | page_alloc used at 22 allocation sites | ~2x for small series | [#50](https://gitlab.com/devnw/zig/timeseries/-/issues/50) | Caller-provided allocator / arena | confirmed | **Closed** (2026-03-22); one residual instance found and closed 2026-07-07 (commit `82ae396`, see rank 18 below). The 2026-03-22 "all internal functions accept std.mem.Allocator" claim missed `distances.zig`'s `crossCorrelateFFT`, which still hardcoded `std.heap.page_allocator` for its 4 FFT scratch buffers with no way for `crossCorrelate`/`sbd` callers to override it. Now fixed. |
| 7 | P1 | 60 | No benchmarking infrastructure | build.zig (missing bench step) | No bench step, no benchmark files | N/A (infra) | [#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58) | Add bench step + parameterized benchmarks | confirmed | Open |
| 8 | P1 | 48 | Store.insertMany full re-sort | store.zig:139-170 | pdq sort on entire array after append | ~20x for incremental | [#54](https://gitlab.com/devnw/zig/timeseries/-/issues/54) | Sort batch + merge O(n+k) | confirmed | **Closed** (2026-03-22). Fast-path: if batch is sorted and all timestamps >= last existing, skip full re-sort. Fallback: full pdq sort for unordered/overlapping batches. |
| 9 | P2 | 48 | Matrix profile parallelization | matrix_profile.zig:26 | Embarrassingly parallel outer loop | Linear with cores (~8x) | [#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70) | Thread pool over row ranges | suspected | **Won't Do** (2026-03-23). STOMP's sequential QT update (QT[j] = QT_prev[j-1] - ...) creates a data dependency between rows, preventing row-level parallelization. True parallelization requires the SCRIMP++ algorithm, which is a separate implementation effort. |
| 10 | P2 | 36 | GorillaEncoder per-bit writes | chunk_storage.zig:134-148 | writeBit called per bit via DynamicBitSet | ~6x fewer ops | [#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62) | Word-level batch writes | confirmed | **Closed** (2026-03-23). writeBits now performs a single capacity check for all bits and writes directly to the DynamicBitSet mask array, eliminating per-bit capacity checks and function call overhead. |
| 11 | P2 | 36 | getCompressedData bit-by-bit extraction | chunk_storage.zig:154-169 | 8 bit reads per byte output | ~100x with memcpy | [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64) | Direct word buffer memcpy | confirmed | **Closed** (2026-03-23). getCompressedData now reads full words from the DynamicBitSet mask array and extracts bytes via @bitReverse, eliminating per-bit isSet() calls. |
| 12 | P2 | 36 | baselineCorrect O(n*w) sliding window | preprocess.zig:90-122 | Full window re-sum per point | ~w (window size) | [#68](https://gitlab.com/devnw/zig/timeseries/-/issues/68) | Prefix sum O(n) | confirmed | **Closed** (2026-03-22). Replaced inner-loop summation with prefix sum array for O(n) baseline computation. |
| 13 | P2 | 36 | No SIMD exploitation (0 @Vector uses) | features.zig:122-133 | Scalar f64 reductions on contiguous arrays | 4-8x for vectorizable loops | [#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72) | @Vector(4, f64) for inner loops | suspected | **Closed** (2026-03-22). cosineSimilarity uses @Vector(4, f64) for dot/norm accumulation with scalar remainder loop. |
| 14 | P2 | 24 | PELT segmentCost called twice per candidate | pelt.zig:79-108 | Same segmentCost(s,t) in optimize + prune | ~1.2-1.5x | [#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67) | Cache cost per candidate | suspected | **Closed** (2026-03-22). Added cost_cache array; optimization loop stores segmentCost, pruning loop reuses it. Falls back to computing for min_size-skipped candidates. |
| 15 | P3 | 24 | extractFeatures 4+ separate passes | features.zig:25-80 | 6 loops over values array | ~2-3x fewer cache misses | [#74](https://gitlab.com/devnw/zig/timeseries/-/issues/74) | Fuse passes 2-6 into single pass | suspected | **Closed** (2026-03-23). Fused 6 loops into 3 passes: pass 1 (sum+min+max), pass 2 (variance+skewness+kurtosis+slope), sort for median, pass 3 (histogram). |
| 16 | P2 | 40 | mpDist/mpDistAbJoinRow O(w) dot-product per pair | matrix_profile.zig:253-317 | `mpDistAbJoinRow` recomputes a fresh O(w) dot product for every `(i, j)` pair inside `mpDist`'s O(plen_a) row loop, giving O(plen_a *plen_b* w) total instead of incremental QT updates | plen ~1000-5000 est. 10-50x (STOMP-style AB-join) | Not yet filed (tracked here pending Workstream F issue sync) | Diagonal-recurrence (STOMP-style) incremental QT update for the AB-join case, mirroring the self-join STOMP design already tracked at rank 1 | suspected | Open — needs a benchmark at plen ~= 1000-5000 before committing to the STOMP-AB-join rewrite (P32/#58 follow-up; discovered during Task E4 while resolving the `parallelBatchCrossCorrelate` stale-reference cleanup). |
| 17 | P0 | 64 | `saveSeriesKeyMeta` called unconditionally on every insert | store.zig:235-236 (pre-fix), `insertMany` | Every `insertMany` call re-persisted the series-key metadata record regardless of whether the series was already known, turning steady-state ingest into an O(total-distinct-series) file rescan per insert batch instead of O(1) amortized | Linear-in-series-count overhead removed from every insert; scales with distinct-series cardinality | Not yet filed (tracked here pending Workstream F issue sync) | Gate the call on `!id_gop.found_existing` (the reverse-map insertion result already computed earlier in `insertMany`), so the metadata is persisted exactly once per new series | confirmed | **Closed** (2026-07-07, commit `6735462`). Persistence round-trip / `loadFromDisk` tests confirm dedup still works with the gate in place. |
| 18 | P1 | 48 | `crossCorrelate`/`sbd` hardcoded `page_allocator` for FFT scratch buffers | distances.zig:138-160 (pre-fix) | `crossCorrelateFFT`'s 4 scratch buffers used `std.heap.page_allocator` directly, bypassing the testing allocator's leak detection and giving callers (including `parallel.zig`'s batch dispatch) no way to supply a pooled/arena allocator | Enables leak-checked tests and caller-controlled allocation strategy for the hottest cross-correlation/SBD path | Not yet filed (tracked here pending Workstream F issue sync) | Add a leading `allocator: std.mem.Allocator` parameter to `crossCorrelate`, `crossCorrelateFFT`, and `sbd`; thread it through `parallel.zig`'s dispatch and the `abi.zig` FFI boundary (which still passes `page_allocator` explicitly, documented as intentional since the C ABI has no caller allocator) | confirmed | **Closed** (2026-07-07, commit `82ae396`). See also rank 6 (residual instance of the page_allocator finding this closes). `distances_test.zig` now passes `std.testing.allocator`, leak-checking the FFT buffers. |
| 19 | P2 | 32 | `chunk_meta.dat` reopened on every `appendChunkMeta` call | chunk_storage.zig:625-641 (pre-fix) | Every chunk-metadata flush did a fresh open/write/close syscall sequence against `chunk_meta.dat` instead of reusing a held-open handle, adding avoidable open/close overhead per chunk flush | Removes 2 syscalls (open+close) per chunk-metadata append | Not yet filed (tracked here pending Workstream F issue sync) | Hold a persistent `meta_file: ?std.Io.File` field on `ChunkStorage`, opened once in `init` (with the same `securePermissions()`/`resolve_beneath` hardening from the F4 filesystem fix) and closed once in `deinit`; `appendChunkMeta` now writes via the held handle | confirmed | **Closed** (2026-07-07, commit `976b5a3`). Chunk write/retention integration tests remain green; no double-close in `deinit`. |

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
| Matrix profile parallelization | matrix_profile.zig | P2 | 48 | **Won't Do** |
| GorillaEncoder batch writes | chunk_storage.zig | P2 | 36 | **Closed** |
| getCompressedData memcpy | chunk_storage.zig | P2 | 36 | **Closed** |
| baselineCorrect running sum | preprocess.zig | P2 | 36 | **Closed** |
| SIMD exploitation | features.zig + others | P2 | 36 | **Closed** |
| PELT segmentCost cache | pelt.zig | P2 | 24 | **Closed** |
| extractFeatures single-pass | features.zig | P3 | 24 | **Closed** |
| mpDist AB-join O(w) dot-product | matrix_profile.zig | P2 | 40 | Open |
| saveSeriesKeyMeta per-insert gate | store.zig | P0 | 64 | **Closed** |
| crossCorrelate/sbd caller allocator | distances.zig | P1 | 48 | **Closed** |
| chunk_meta.dat held-open handle | chunk_storage.zig | P2 | 32 | **Closed** |

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
| ~~3~~ | ~~GorillaEncoder + getCompressedData~~ | ~~[#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62), [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64)~~ | ~~3 days~~ | **DONE** (2026-03-23) |
| ~~4~~ | ~~extractFeatures single-pass~~ | ~~[#74](https://gitlab.com/devnw/zig/timeseries/-/issues/74)~~ | ~~1 day~~ | **DONE** (2026-03-23) |

### Strategic (> 5 days each)

These are algorithmic rewrites with the highest absolute impact:

| Priority | Finding | Issue | Est. Effort | Expected Gain |
|----------|---------|-------|-------------|---------------|
| 1 | STOMP for matrix profile | [#32](https://gitlab.com/devnw/zig/timeseries/-/issues/32) | 5-7 days | 100-260x |
| ~~2~~ | ~~FFT cross-correlation~~ | ~~[#36](https://gitlab.com/devnw/zig/timeseries/-/issues/36)~~ | ~~5-7 days (FFT impl)~~ | **DONE** (2026-03-22) |
| ~~3~~ | ~~Matrix profile parallelization~~ | ~~[#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70)~~ | ~~3-5 days (after STOMP)~~ | **Won't Do** (2026-03-23). STOMP's sequential QT dependency prevents row-level parallelization; requires SCRIMP++ algorithm. |
| 4 | SIMD @Vector exploitation | [#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72) | 3-5 days | 4-8x for inner loops |

### Recommended Execution Order

1. **Week 1**: Benchmarking infrastructure ([#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58)) -- gates all measurement
2. ~~**Week 1**: Quick wins ([#39](https://gitlab.com/devnw/zig/timeseries/-/issues/39), [#44](https://gitlab.com/devnw/zig/timeseries/-/issues/44), [#47](https://gitlab.com/devnw/zig/timeseries/-/issues/47), [#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67), [#68](https://gitlab.com/devnw/zig/timeseries/-/issues/68), [#54](https://gitlab.com/devnw/zig/timeseries/-/issues/54))~~ -- **DONE** (2026-03-22, Batch C)
3. ~~**Week 2**: Allocator refactor ([#50](https://gitlab.com/devnw/zig/timeseries/-/issues/50))~~ -- **DONE** (2026-03-22, via Q5/#41)
4. **Week 3-4**: STOMP ([#32](https://gitlab.com/devnw/zig/timeseries/-/issues/32)) -- highest absolute gain
5. ~~**Week 5-6**: FFT cross-correlation ([#36](https://gitlab.com/devnw/zig/timeseries/-/issues/36))~~ -- **DONE** (2026-03-22)
6. ~~**Quarter 2**: Parallelization ([#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70)), SIMD ([#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72)), Gorilla compression ([#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62), [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64))~~ -- P70 **Won't Do** (SCRIMP++ needed); P72 **DONE** (2026-03-22); P62+P64 **DONE** (2026-03-23)

## Unknowns and Blockers

1. **No benchmark data**: All speedup estimates are theoretical until [#58](https://gitlab.com/devnw/zig/timeseries/-/issues/58) is resolved. Actual measurements may differ.
2. **Auto-vectorization**: Zig with `-OReleaseFast` may already auto-vectorize some loops ([#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72)). Measure before investing in manual SIMD.
3. **Memory bandwidth saturation**: Parallelization gains ([#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70)) may plateau before core count if memory bandwidth is the bottleneck. Measure with varying thread counts.
4. ~~**FFT implementation complexity**: A correct, performant FFT in Zig is non-trivial.~~ **Resolved (2026-03-22):** Radix-2 Cooley-Tukey FFT implemented in distances.zig with brute-force fallback for small inputs (< 64 elements) and allocation failure.
5. **Gorilla compression correctness**: ~~The current encoder has no corresponding decoder (queryRange is a stub).~~ **Resolved (2026-03-22):** GorillaDecoder implemented, queryRange fully functional. Optimizing the encoder ([#62](https://gitlab.com/devnw/zig/timeseries/-/issues/62), [#64](https://gitlab.com/devnw/zig/timeseries/-/issues/64)) can now proceed independently.

## Confirmation Needed (confidence::suspected)

| Finding | What would confirm it | Issue |
|---------|----------------------|-------|
| ~~Matrix profile parallelization~~ | ~~Benchmark with 1,2,4,8 threads showing linear scaling~~ | ~~[#70](https://gitlab.com/devnw/zig/timeseries/-/issues/70)~~ **Won't Do** (2026-03-23) |
| ~~SIMD @Vector gains~~ | ~~Compare `-OReleaseFast` assembly for cosine_similarity with/without manual @Vector~~ | ~~[#72](https://gitlab.com/devnw/zig/timeseries/-/issues/72)~~ **Closed** (2026-03-22) |
| ~~PELT segmentCost caching~~ | ~~Benchmark showing measurable wall-clock difference~~ | ~~[#67](https://gitlab.com/devnw/zig/timeseries/-/issues/67)~~ **Closed** (2026-03-22) |
| ~~extractFeatures single-pass~~ | ~~Benchmark with n=10000 showing cache-miss reduction via perf stat~~ | ~~[#74](https://gitlab.com/devnw/zig/timeseries/-/issues/74)~~ **Closed** (2026-03-23) |
| mpDist/mpDistAbJoinRow AB-join O(w) dot-product | Benchmark `parallelMpDistAbJoin`/`mpDist` at plen ~= 1000-5000 showing wall-clock gain from a STOMP-style incremental QT AB-join vs. the current per-pair O(w) recompute | Not yet filed (2026-07-07) |

## Follow-up notes (2026-07-07, iteration-2 re-audit)

- **Caller-must-use-thread-safe-allocator consideration (cross-ref SEC-5, rank 18 above).** The P1 allocator-threading fix (rank 18: `crossCorrelate`/`sbd` caller allocator) means the allocator passed into `parallelBatchDistances(.{ .metric = .sbd })` and `parallelBatchCrossCorrelate` is now used concurrently by ThreadPool worker threads (each dispatched chunk allocates/frees its own FFT scratch buffers independently) whenever a non-null `*tp.ThreadPool` is supplied. This is not a regression introduced by that fix, but it is a caller-facing contract that must be documented and honored: **the allocator must be thread-safe whenever `pool` is non-null** (e.g. `std.heap.page_allocator`, or a `GeneralPurposeAllocator`/`DebugAllocator` with `.thread_safe = true`). See `src/parallel.zig`'s module doc comment and `docs/parallel-api.md` for the full contract. No code change is needed here; this is a documentation-only tracked item.
- **`parallelBatchCrossCorrelate` has no dedicated benchmark yet (P3, informational).** `tests/bench.zig` benchmarks `parallelBatchDTW`/`parallelBatchLbKeogh`/`parallelBatchDistances`, but `parallelBatchCrossCorrelate` (added alongside them) is not yet exercised by a parameterized benchmark. Potential lock/allocator contention under concurrent FFT-scratch-buffer allocation (see the thread-safety note above) is therefore unmeasured. This is not a known regression -- just an unmeasured path. Tracked as a P3 backlog item pending a benchmark addition; not blocking.
