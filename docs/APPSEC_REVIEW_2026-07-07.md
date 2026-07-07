# Application Security Code Review — `timeseries` (Zig library + C ABI)

_Scope: full repository at HEAD `0875199`, branch `main`. Generated 2026-07-07 by `/security:appsec-review`. Grounded in OWASP Top 10:2025 + CIS Controls v8.1.2._

## 1. Scope and Assumptions

**Reviewed** (repo at HEAD `0875199`, branch `main`, clean tree):

- C ABI surface: `src/abi.zig`, `src/ts_abi.h`
- Deserialization / persistence: `src/store.zig`, `src/chunk_storage.zig`
- Compute modules with allocation math: `src/dtw.zig`, `src/distances.zig`, `src/matrix_profile.zig`, `src/parallel.zig`
- Public API surface: `src/root.zig`
- Supply chain / CI: `.gitlab-ci.yml`, `build.zig.zon`, `.pre-commit-config.yaml`, `.gitleaks.toml`
- Prior record: `docs/SECURITY_GAP_ANALYSIS.md` (16 findings, all marked closed — sampled and cross-checked)

**Trust boundary.** The public Zig API and the C ABI. Untrusted inputs = caller buffers/lengths/configs through the C ABI, plus corrupted/adversarial on-disk data deserialized by `store.zig`/`chunk_storage.zig`.

## 2. Executive Summary

- The C ABI boundary is genuinely well-hardened (verified: negative-length guards, bounded slices, overflow-checked multiplications, 256 MB caps, output capacity params, NaN/Inf validation, MAX_SERIES_LEN). Confidence: High.
- The deserialization surface is the weakest area and is not hardened against adversarial data (F1–F3): reachable integer-underflow/invalid-shift panics in the Gorilla decoder, unvalidated `num_points`/`compressed_size`/`metric_len`, unchecked `@enumFromInt`. Panic/DoS in safe builds, UB in ReleaseFast.
- Three prior "closed" findings are inaccurate: S9 (O_NOFOLLOW) and S10 (0o600 file mode) are not implemented; S12 (SHA-pinned CI components) still uses mutable `@v1.43.0` tags.
- No injection, auth, crypto, or memory-corruption (heap overflow / OOB write) vulnerabilities confirmed in scope.

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP 2025 | Status |
|----|----------|-----------|-------|----------|-----------|--------|
| F1 | Medium | High | Gorilla decoder panics/UB on adversarial compressed bitstream | `src/chunk_storage.zig:370-383` | A10 / A08 | New |
| F2 | Medium | High | Unvalidated chunk metadata deserialization (invalid enum, unbounded `num_points`/`compressed_size`) | `src/chunk_storage.zig:698-715, 529, 391-394` | A08 | New |
| F3 | Medium | High | Unbounded `metric_len` allocation deserializing `series_meta.dat` | `src/store.zig:624-626, 675-677` | A08 | New |
| F4 | Low | High | Persisted files world-readable; no O_NOFOLLOW — S9/S10 marked closed but absent | `src/chunk_storage.zig:428-431, 630-633`; `src/store.zig:541-544` | A02 | Regression vs record |
| F5 | Low | High | CI catalog components pinned to mutable semver tags — S12 overstated as closed | `.gitlab-ci.yml:11-25` | A03 | Regression vs record |
| F6 | Low | Medium | ABI input data pointers (`a`, `b`, `a_times`, `b_times`) not null-checked | `src/abi.zig:69-96, 371-393` | A10 | New |
| F7 | Low | Medium | `sampleBy`/`timeBucketAvg` integer-overflow panic + large bucket allocation on adversarial i64 range | `src/store.zig:311, 404` | A10 | New |
| F8 | Info | High | `otel` dependency pinned by mutable tag (hash mitigates) vs commit SHA | `build.zig.zon:11-15` | A03 | New |
| F9 | Info | Medium | `parallel.zig` `std.debug.assert` on caller slice lengths (panic in safe, no-op in ReleaseFast) | `src/parallel.zig:127, 246, 324` | A10 | New |

## 4. Finding Details

### F1 — Gorilla decoder panics / UB on adversarial compressed bitstream (Medium, High)

`src/chunk_storage.zig` `GorillaDecoder.decodePoint`, XOR "new leading/trailing" branch (~:373-379): `leading` (5 bits) and `significant_bits` (6 bits) are read from the stream with no cross-constraint. `trailing = 64 - leading - significant_bits` underflows `u8` (e.g. 31+63); `xor << @intCast(trailing)` with `trailing=64` panics on the `u6` shift cast. Reachable via `Store.loadFromDisk` → `queryRange` → `decodeAll` → `decodePoint`. DoS (panic) in safe builds, UB in ReleaseFast.
**Fix:** `if (significant_bits == 0 or leading + significant_bits > 64) return error.CorruptChunk;` before computing `trailing`. Add decoder fuzz/negative tests. CWE-190, CWE-755.

### F2 — Unvalidated chunk metadata deserialization (Medium, High)

`deserializeChunkMeta` (`src/chunk_storage.zig:690-718`): `@enumFromInt(compression_raw)` on unchecked u32 panics/UB when `>= 4`. `queryRange` (`:529`) allocs `compressed_size` (u32 from disk, ~4 GB); `decodeAll` (`:394`) reserves `num_points` (u32). Reachable at `ChunkStorage.init`/`loadFromDisk`.
**Fix (as shipped):** `std.meta.intToEnum` does not exist in Zig 0.16's stdlib, so the fix is a hand-rolled bounds check ahead of the cast: `if (compression_raw >= @typeInfo(CompressionAlgorithm).@"enum".fields.len) return error.CorruptMeta;` followed by `@enumFromInt(compression_raw)`; plus bounding `num_points`/`compressed_size` against `MAX_CHUNK_POINTS`/`MAX_CHUNK_BYTES`. CWE-502, CWE-789, CWE-755.

### F3 — Unbounded `metric_len` allocation deserializing `series_meta.dat` (Medium, High)

`src/store.zig:624-626` and `:675-677`: `metric_len` (u32 from disk) drives `allocator.alloc(u8, metric_len)` — up to ~4 GB from a 4-byte field, per record.
**Fix:** `if (metric_len > MAX_METRIC_LEN) return error.CorruptMeta;` (e.g. 4 KiB) and/or validate against remaining file length. CWE-789, CWE-502.

### F4 — Persisted files world-readable; no O_NOFOLLOW (Low, High) — S9/S10 marked closed but absent

All persistence `createFile` calls (`src/chunk_storage.zig:428,630`; `src/store.zig:541`) use `.{ .read = true, .truncate = false }` with no `.mode` and no no-follow. No `0o600`/`.mode`/`no_follow` anywhere in `src/`. Prior record marks S9/S10 Closed. Path-traversal `..` check (S8) IS present.
**Fix:** `.mode = 0o600` on all three; no-follow/real-path validation; correct S9/S10 status in the gap doc. CWE-732, CWE-59.

### F5 — CI catalog components pinned to mutable semver tags (Low, High) — S12 overstated

`.gitlab-ci.yml:11-25`: eight `gitlab.com/devnw/ci-catalog/<name>@v1.43.0` includes; semver tag refs are mutable. S12 marked Closed while note concedes "semver tags left in place."
**Fix:** Pin each include to an immutable commit SHA; re-classify S12. CWE-829, CWE-1357.

### F6 — ABI input data pointers not null-checked (Low, Medium)

`src/abi.zig`: `a: [*]const f64` (non-optional) sliced `a[0..n]` without null check; `ts_twed` `a_times`/`b_times` likewise (`:374,376`). NULL + positive length → segfault. Output pointers ARE null-checked.
**Fix:** document non-null precondition in `ts_abi.h` or add `if (@intFromPtr(a) == 0) return -1;` guards. CWE-476.

### F7 — `sampleBy`/`timeBucketAvg` overflow panic on adversarial i64 range (Low, Medium)

`src/store.zig:311` (and `:404`): `end_ts - start_ts` unchecked i64 subtraction overflows (maxInt − minInt) → panic in safe builds. Zig-API-only (not C ABI).
**Fix:** `std.math.sub(i64, end_ts, start_ts)` returning empty on overflow; cap `n_buckets`. CWE-190, CWE-755.

### F8 — `otel` pinned by mutable tag vs commit SHA (Info, High)

`build.zig.zon:11-15`: `otel` uses `#v0.1.17` tag fragment + content hash; `thread_pool` pins a full commit SHA. Hash verification preserves integrity (hence Info).
**Fix:** pin `otel` to a commit SHA for consistency. CWE-1357.

### F9 — `parallel.zig` asserts on caller slice lengths (Info, Medium)

`src/parallel.zig:127,246,324`: `std.debug.assert(out_results.len == candidates.len)` panics in safe builds, compiled out in ReleaseFast. Zig-API-only.
**Fix:** return `error.LengthMismatch` for public entry points. CWE-617.

## 5. Secure Design Notes (positive controls observed)

ABI boundary defensively coded (null-checks, length guards, bounded slices, finiteness validation, capacity checks — closes S1/S2/S5/S6/S7/S15). Overflow-safe capped allocation math (S3/S4/S16). SHA-256-verified Zig toolchain download in CI (S11). Debug/ReleaseSafe/ReleaseFast/ReleaseSmall + fuzz test matrix (S14). Content-hash-pinned deps. Path-traversal guard (S8). Gorilla decoder enforces EndOfStream (no OOB reads).

## 6. Coverage Gaps and Questions

- Dynamic verification not performed (F1–F3 code-evident; recommend extending `tests/fuzz.zig` to feed adversarial bytes into the decoder + metadata readers).
- Exact panic-vs-UB behavior is build-mode dependent; returning errors makes it mode-independent.
- `data_dir` trust boundary: does on-disk data ever originate from untrusted input in production? Sets real-world severity of F1–F4.
- Not reviewed in depth: `spectral.zig`, `anomaly.zig`, `features.zig`, `preprocess.zig`, `pelt.zig` bodies.

## 7. Prioritized Next Actions

1. Harden the Gorilla decoder (F1).
2. Validate chunk metadata on load (F2).
3. Bound `metric_len` before allocation (F3).
4. Restore and correct filesystem controls (F4); fix S9/S10 status.
5. Pin CI components to commit SHAs (F5); re-classify S12.
6. Lower-priority hardening: F6, F7, F8, F9.
7. Add negative/fuzz tests for all deserialization paths.
