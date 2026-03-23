# Quality Gap Analysis -- timeseries (Zig)

Last updated: 2026-03-22

## Summary

**Total findings: 19** (grouped into 17 tracked issues)

**Cycle status (2026-03-22):** 9 findings closed, 1 won't-do, 7 open/deferred

| Severity | Count |
|----------|-------|
| Critical | 1     |
| High     | 5     |
| Medium   | 5     |
| Low      | 8     |

### Top 5 risks

1. **Q1 (Critical, Score 100)** -- `queryRange` returns empty results because decompression is a stub. The entire chunk-storage read path is non-functional.
2. **Q5 (High, Score 80)** -- 22 hardcoded `page_allocator` calls bypass testing allocator leak detection and impose page-granularity overhead on every algorithm call.
3. **Q2 (High, Score 64)** -- DTW backtrack logic duplicated 3x (~100 lines). Any backtrack bug must be fixed in 3 places.
4. **Q4 (High, Score 64)** -- All algorithm functions use C-style pointer+length signatures internally instead of idiomatic Zig slices and error unions.
5. **Q6+Q7 (High, Score 64)** -- Magic 8192-element stack buffer in 3 files; `baselineCorrect` silently drops correction for inputs >8192 points.

---

## Stack-ranked findings

| Rank | ID | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue | Fix Summary | Effort | Status |
|------|----|----------|---------------|----------|---------|-----------|----------|-------|-------------|--------|--------|
| 1 | Q1 | Critical | 100 | architecture | `queryRange` returns empty -- decompression stub | chunk_storage.zig:260-278 | Loop body empty after range filter | [#34](https://gitlab.com/devnw/zig/timeseries/-/issues/34) | Implement GorillaDecoder, wire into queryRange | M | **Closed** (2026-03-22). GorillaDecoder implemented (160 lines) in chunk_storage.zig. queryRange wired up. 7 unit + 2 integration tests. |
| 2 | Q5 | High | 80 | architecture | 22 hardcoded `page_allocator` alloc/free pairs | dtw.zig:8, distances.zig:8, pelt.zig:8 | `const page_alloc = std.heap.page_allocator;` in 3 files | [#41](https://gitlab.com/devnw/zig/timeseries/-/issues/41) | Accept `Allocator` param; ABI wrappers pass page_allocator | M | **Closed** (2026-03-22). All internal functions now accept `std.mem.Allocator` parameter. ABI wrappers pass `page_allocator`. |
| 3 | Q2 | High | 64 | maintainability | DTW backtrack duplicated 3x (~100 lines) | dtw.zig:67-101, :208-241, :312-345 | Identical while-loop structure in 3 functions | [#35](https://gitlab.com/devnw/zig/timeseries/-/issues/35) | Extract `backtrack()` helper | S | **Closed** (2026-03-22). Extracted `backtrack()` helper in dtw.zig. constrainedDTW, openEndDTW, and shapeDTW now delegate to the shared function. All 139 unit + 10 integration tests pass. |
| 4 | Q4 | High | 64 | api-contract | C-style signatures for internal functions | dtw.zig, distances.zig, matrix_profile.zig, features.zig, pelt.zig | `[*]const f64` + `i32` len + `*f64` out-params | [#40](https://gitlab.com/devnw/zig/timeseries/-/issues/40) | Create idiomatic Zig API; ABI layer delegates | L | triage |
| 5 | Q6+Q7 | High | 64 | architecture | Magic 8192 stack buffer; silent failure >8192 pts | preprocess.zig:96-97, features.zig:47, matrix_profile.zig:108 | `var baseline_buf: [8192]f64 = undefined;` / `else return;` | [#42](https://gitlab.com/devnw/zig/timeseries/-/issues/42) | Dynamic alloc fallback; return error instead of silent return | S | **Closed** (2026-03-22). All 3 stack buffers replaced with dynamic allocation via page_allocator. Boundary tests at 8193 points verify correct results. |
| 6 | Q3 | High | 48 | maintainability | Z-norm distance duplicated 2x in matrix_profile | matrix_profile.zig:30-73, :112-149 | Identical mean/std/z-norm loop in both functions | [#37](https://gitlab.com/devnw/zig/timeseries/-/issues/37) | Extract `zNormDist()` helper | S | **Closed** (2026-03-22). Extracted `zNormDist()` helper in matrix_profile.zig. matrixProfile and mpDist now delegate to the shared function. All 139 unit + 10 integration tests pass. |
| 7 | Q8 | Medium | 36 | api-contract | zNormalize/baselineCorrect mutate input in-place | preprocess.zig:63, :88 | `for (values) \|*v\| v.* = ...` | [#43](https://gitlab.com/devnw/zig/timeseries/-/issues/43) | Add allocating variants; rename in-place with `Mut` suffix | S | triage |
| 8 | Q10 | Medium | 36 | architecture | GorillaEncoder prev_ts==0 sentinel; epoch-zero bug | chunk_storage.zig:47-72 | `if (self.prev_ts == 0)` as first-point check | [#49](https://gitlab.com/devnw/zig/timeseries/-/issues/49) | Add `initialized: bool` field | S | **Closed** (2026-03-22). Added `point_count` field to GorillaEncoder; changed first-point detection from `prev_ts==0` to `point_count==0`. Test covers epoch-zero round-trip. |
| 9 | Q18 | Medium | 36 | docs | docs/README.md links to 5 non-existent pages | docs/README.md:9-13 | `getting-started.md`, `api-reference.md`, etc. missing | [#63](https://gitlab.com/devnw/zig/timeseries/-/issues/63) | Create stubs or remove broken links | S | triage |
| 10 | Q19 | Medium | 36 | api-contract | Inconsistent error signaling (i32 vs Zig errors vs silent) | dtw.zig, distances.zig, preprocess.zig, features.zig, pelt.zig | Mixed `i32` return codes and `!T` error unions | [#65](https://gitlab.com/devnw/zig/timeseries/-/issues/65) | Standardize on Zig error unions internally | L | **Won't Do** (deferred to v2). ABI-breaking change requiring Go CGO consumer coordination. See also S15/#71. |
| 11 | Q9 | Medium | 24 | architecture | Store.hashKey 64-bit entropy in 128-bit key | store.zig:88-96 | `(x << 64) \| (x ^ 0x9e3779b97f4a7c15)` | [#46](https://gitlab.com/devnw/zig/timeseries/-/issues/46) | Use 128-bit hash or change key to u64 | S | **Closed** (2026-03-22). Two independent Wyhash seeds (0 and 0x517cc1b727220a95) now produce full 128-bit entropy. Test verifies upper/lower halves are independently derived. |
| 12 | Q14 | Low | 16 | readability | Feature vector indices are magic numbers | features.zig:96-108 | `features_out[7] = skewness;` | [#55](https://gitlab.com/devnw/zig/timeseries/-/issues/55) | Define `FeatureIndex` enum | S | **Closed** (2026-03-22). Added `FeatureIndex` struct with named constants for all 22 feature positions. `extractFeatures` now uses named indices. 2 tests verify index positions and feature extraction via names. |
| 13 | Q16 | Low | 16 | tests | ChunkStorage tests use hardcoded /tmp paths | chunk_storage.zig:356, :384 | `"/tmp/ts_test_chunks"` | [#59](https://gitlab.com/devnw/zig/timeseries/-/issues/59) | Use `std.testing.tmpDir` or unique suffix | S | triage |
| 14 | Q17 | Low | 16 | docs | No algorithm reference documentation | dtw.zig, distances.zig, pelt.zig, matrix_profile.zig | No paper citations | [#60](https://gitlab.com/devnw/zig/timeseries/-/issues/60) | Add citations to doc comments | S | triage |
| 15 | Q11+Q12 | Low | 12 | cleanup | Unused imports in types.zig and distances_test.zig | types.zig:6, distances_test.zig:6 | `const std = @import("std");` unused | [#51](https://gitlab.com/devnw/zig/timeseries/-/issues/51) | Remove unused imports | S | **Closed** (2026-03-22). Removed unused `std` import in types.zig and unused `dtw` import in distances_test.zig. |
| 16 | Q13 | Low | 12 | readability | store_mod naming inconsistent | root.zig:37 | `pub const store_mod = @import("store.zig");` | [#52](https://gitlab.com/devnw/zig/timeseries/-/issues/52) | Rename to `store` | S | **Closed** (2026-03-22). Renamed `store_mod` to `store` in root.zig. |
| 17 | Q15 | Low | 8 | cleanup | Alignment.path_len duplicates path.len | types.zig:16-21 | `path_len: usize` alongside `path: []const PathPoint` | [#56](https://gitlab.com/devnw/zig/timeseries/-/issues/56) | Remove `path_len` from Zig struct | S | **Closed** (2026-03-22). Removed redundant `path_len` field from Alignment struct. |

---

## Findings by category

### Architecture (5 findings)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q1 | Critical | 100 | queryRange decompression stub | [#34](https://gitlab.com/devnw/zig/timeseries/-/issues/34) |
| Q5 | High | 80 | Hardcoded page_allocator | [#41](https://gitlab.com/devnw/zig/timeseries/-/issues/41) |
| Q6+Q7 | High | 64 | Magic 8192 buffer / silent failure | [#42](https://gitlab.com/devnw/zig/timeseries/-/issues/42) |
| Q10 | Medium | 36 | Epoch-zero sentinel bug | [#49](https://gitlab.com/devnw/zig/timeseries/-/issues/49) |
| Q9 | Medium | 24 | Weak hash key | [#46](https://gitlab.com/devnw/zig/timeseries/-/issues/46) |

### API contract (3 findings)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q4 | High | 64 | C-style internal signatures | [#40](https://gitlab.com/devnw/zig/timeseries/-/issues/40) |
| Q8 | Medium | 36 | In-place mutation | [#43](https://gitlab.com/devnw/zig/timeseries/-/issues/43) |
| Q19 | Medium | 36 | Inconsistent error signaling | [#65](https://gitlab.com/devnw/zig/timeseries/-/issues/65) |

### Maintainability (2 findings)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q2 | High | 64 | DTW backtrack duplicated 3x | [#35](https://gitlab.com/devnw/zig/timeseries/-/issues/35) |
| Q3 | High | 48 | Z-norm distance duplicated 2x | [#37](https://gitlab.com/devnw/zig/timeseries/-/issues/37) |

### Documentation (2 findings)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q18 | Medium | 36 | Broken docs links | [#63](https://gitlab.com/devnw/zig/timeseries/-/issues/63) |
| Q17 | Low | 16 | Missing paper citations | [#60](https://gitlab.com/devnw/zig/timeseries/-/issues/60) |

### Readability (2 findings)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q14 | Low | 16 | Magic feature indices | [#55](https://gitlab.com/devnw/zig/timeseries/-/issues/55) |
| Q13 | Low | 12 | store_mod naming | [#52](https://gitlab.com/devnw/zig/timeseries/-/issues/52) |

### Cleanup (2 findings)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q11+Q12 | Low | 12 | Unused imports | [#51](https://gitlab.com/devnw/zig/timeseries/-/issues/51) |
| Q15 | Low | 8 | Redundant path_len | [#56](https://gitlab.com/devnw/zig/timeseries/-/issues/56) |

### Tests (1 finding)

| ID | Severity | Score | Finding | Issue |
|----|----------|-------|---------|-------|
| Q16 | Low | 16 | Hardcoded /tmp test paths | [#59](https://gitlab.com/devnw/zig/timeseries/-/issues/59) |

---

## Roadmap

### Quick wins (< 1 day)

| ID | Score | Finding | Effort | Issue |
|----|-------|---------|--------|-------|
| Q6+Q7 | 64 | Magic 8192 buffer / silent failure | S | [#42](https://gitlab.com/devnw/zig/timeseries/-/issues/42) |
| Q2 | 64 | Extract DTW backtrack helper | S | [#35](https://gitlab.com/devnw/zig/timeseries/-/issues/35) |
| Q3 | 48 | Extract z-norm distance helper | S | [#37](https://gitlab.com/devnw/zig/timeseries/-/issues/37) |
| Q8 | 36 | Add allocating preprocess variants | S | [#43](https://gitlab.com/devnw/zig/timeseries/-/issues/43) |
| Q10 | 36 | Fix epoch-zero sentinel | S | [#49](https://gitlab.com/devnw/zig/timeseries/-/issues/49) |
| Q18 | 36 | Fix broken docs links | S | [#63](https://gitlab.com/devnw/zig/timeseries/-/issues/63) |
| Q9 | 24 | Fix hash key entropy | S | [#46](https://gitlab.com/devnw/zig/timeseries/-/issues/46) |
| Q14 | 16 | Named feature indices | S | [#55](https://gitlab.com/devnw/zig/timeseries/-/issues/55) |
| Q16 | 16 | Fix test tmp paths | S | [#59](https://gitlab.com/devnw/zig/timeseries/-/issues/59) |
| Q17 | 16 | Add paper citations | S | [#60](https://gitlab.com/devnw/zig/timeseries/-/issues/60) |
| Q11+Q12 | 12 | Remove unused imports | S | [#51](https://gitlab.com/devnw/zig/timeseries/-/issues/51) |
| Q13 | 12 | Rename store_mod | S | [#52](https://gitlab.com/devnw/zig/timeseries/-/issues/52) |
| Q15 | 8 | Remove redundant path_len | S | [#56](https://gitlab.com/devnw/zig/timeseries/-/issues/56) |

### Medium (1-5 days)

| ID | Score | Finding | Effort | Issue |
|----|-------|---------|--------|-------|
| Q1 | 100 | Implement GorillaDecoder for queryRange | M | [#34](https://gitlab.com/devnw/zig/timeseries/-/issues/34) |
| Q5 | 80 | Allocator injection for all algorithms | M | [#41](https://gitlab.com/devnw/zig/timeseries/-/issues/41) |

### Strategic (> 5 days)

| ID | Score | Finding | Effort | Issue |
|----|-------|---------|--------|-------|
| Q4 | 64 | Idiomatic Zig API (slices, error unions, structs) | L | [#40](https://gitlab.com/devnw/zig/timeseries/-/issues/40) |
| Q19 | 36 | Unified error signaling | L | [#65](https://gitlab.com/devnw/zig/timeseries/-/issues/65) |

**Note:** Q4, Q5, and Q19 are tightly coupled and should be tackled together as a single refactoring initiative. Combined effort estimate: ~5-7 days.

---

## Confidence notes

All findings are tagged `confidence::confirmed` (verified via direct code inspection) except:

- **Q9** (`confidence::suspected`): The hash collision risk is theoretical. To confirm, construct two `SeriesKey` values that produce the same 64-bit Wyhash output, which would create a confirmed collision in the 128-bit key space. At <1M series the practical risk is low, but the design is architecturally unsound.
