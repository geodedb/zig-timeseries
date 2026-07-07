# Audit Findings Closure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every actionable finding from the 2026-07-07 appsec review (F1–F9) and the `/codepros:audit` scan (gap/quality/perf/security) so a re-run of `/security:appsec-review` and `/codepros:audit` surfaces no new issues.

**Architecture:** The repo is a pure-Zig timeseries library exposing a C ABI. Fixes are grouped into six independent workstreams: (A) deserialization hardening, (B) filesystem/supply-chain hardening, (C) ABI/API robustness, (D) build/gap compile fixes, (E) performance, (F) CI + docs reconciliation. Each workstream is independently testable and committable.

**Tech Stack:** Zig 0.16.0 (via `mise exec zig@0.16.0`), GitLab CI (devnw/ci-catalog), Gorilla compression, thread_pool + otel git deps.

## Global Constraints

- **Toolchain:** The `zig` on PATH is 0.15.2 and CANNOT build this repo. ALWAYS build/test with `mise exec zig@0.16.0 -- zig …`.
- **Canonical checks (must pass after every task):** `mise exec zig@0.16.0 -- zig build check`, `… zig build test --summary all` (baseline 240/241 pass, 1 skip), `… zig build test-integration --summary all` (13/13), `mise exec zig@0.16.0 -- zig fmt --check src/ tests/ build.zig examples/`.
- **Error handling:** Convert adversarial-input faults into returned Zig errors (`error.CorruptChunk`, `error.CorruptMeta`), never panic/UB. Add the new error tags to the relevant inferred/declared error sets.
- **No behavior regressions:** All existing tests must stay green; every new guard needs a negative test proving it returns an error instead of panicking.
- **Commits:** One focused commit per task, conventional-commit style, ending with the Co-Authored-By trailer.
- **Minimum Zig version floor is 0.16.0** (see Task D3).

---

## Workstream A — Deserialization Hardening (appsec F1, F2, F3; security-scanner corroborated)

### Task A1: Gorilla decoder rejects malformed leading/trailing widths (F1)

**Files:**
- Modify: `src/chunk_storage.zig` (`GorillaDecoder.decodePoint`, ~:373-382)
- Test: `src/chunk_storage.zig` (inline `test` block near line 723)

**Interfaces:**
- Produces: `decodePoint` may now return `error.CorruptChunk`. `decodePoint`/`decodeAll` already return inferred error unions, so callers need no signature change.

- [ ] **Step 1: Write the failing test.** In the tests section of `src/chunk_storage.zig`, add a test that constructs a `GorillaDecoder` over a hand-crafted byte buffer whose value block encodes `xor_control=1, xor_type=1, leading=0, significant_bits=0` (which forces `trailing=64`), and asserts `decodeAll` returns `error.CorruptChunk`. Model the decoder setup on the existing decoder tests (search for `GorillaDecoder.init` usages in the test section). If constructing a raw bitstream is impractical, instead unit-test a small extracted helper `fn validateWidths(leading: u8, significant_bits: u8) error{CorruptChunk}!u8` that returns `trailing`, asserting it errors for `(0,0)`, `(31,63)`, and returns `0` for `(0,64)`, `1` for `(0,63)`.
- [ ] **Step 2: Run it, verify it fails.** `mise exec zig@0.16.0 -- zig build test --summary all` → new test FAILS (panic or wrong result).
- [ ] **Step 3: Implement the guard.** In the `else` (new leading/trailing) branch of `decodePoint`, after reading `leading` and `significant_bits`, insert before computing `trailing`:
  ```zig
  if (significant_bits == 0 or @as(u16, leading) + @as(u16, significant_bits) > 64) return error.CorruptChunk;
  ```
  This guarantees `trailing = 64 - leading - significant_bits` stays in `0..63`, so the subsequent `@intCast(trailing)` shift cannot panic and `prev_trailing`/`prev_leading` remain valid for the reuse branch.
- [ ] **Step 4: Run tests, verify pass.** `… zig build test` → new test PASSES, existing decoder round-trip tests still PASS.
- [ ] **Step 5: `zig fmt` + commit.** `mise exec zig@0.16.0 -- zig fmt src/chunk_storage.zig`; commit `fix(security): reject malformed Gorilla widths to prevent decoder panic (F1)`.

### Task A2: Validate chunk metadata on load (F2)

**Files:**
- Modify: `src/chunk_storage.zig` (`deserializeChunkMeta` :690-718, its caller `loadChunkMeta` :659, and the alloc sites in `queryRange` ~:529 and `decodeAll` :394)
- Test: `src/chunk_storage.zig` tests section

**Interfaces:**
- Produces: `deserializeChunkMeta` signature changes from `fn(...) ChunkMeta` to `fn(...) error{CorruptMeta}!ChunkMeta`. `loadChunkMeta` (already `!void`) must `try` it.

- [ ] **Step 1: Write the failing test.** Add a test that builds a 48-byte `chunk_meta` record buffer (use the field layout mirrored from `serializeChunkMeta`/`deserializeChunkMeta`) with `compression_raw = 99` and asserts `deserializeChunkMeta(&buf)` returns `error.CorruptMeta`. Add a second buffer with a valid compression tag but `num_points = 0xFFFFFFFF` and assert `error.CorruptMeta`.
- [ ] **Step 2: Run, verify fail** (panic on `@enumFromInt` today). `… zig build test`.
- [ ] **Step 3: Implement.** Change `deserializeChunkMeta` to return `error{CorruptMeta}!ChunkMeta`. Replace `.compression = @enumFromInt(compression_raw)` with a checked conversion computed before the struct literal:
  ```zig
  const compression = std.meta.intToEnum(CompressionAlgorithm, compression_raw) catch return error.CorruptMeta;
  ```
  Add sanity bounds before returning: reject records whose `num_points` exceeds a generous cap and whose `compressed_size`/`uncompressed_size` exceed a cap. Add near the top of the file:
  ```zig
  /// Upper bounds for values read from on-disk metadata (corruption/DoS guard).
  const MAX_CHUNK_POINTS: u32 = 1 << 26; // 67M points/chunk ceiling
  const MAX_CHUNK_BYTES: u32 = 1 << 30;  // 1 GiB compressed/uncompressed ceiling
  ```
  and:
  ```zig
  if (num_points > MAX_CHUNK_POINTS) return error.CorruptMeta;
  if (compressed_size > MAX_CHUNK_BYTES or uncompressed_size > MAX_CHUNK_BYTES) return error.CorruptMeta;
  ```
  Update the caller at :659 to `const meta = try deserializeChunkMeta(&buf);`.
- [ ] **Step 4: Run tests, verify pass** (both new tests error cleanly; existing chunk round-trip/retention integration tests still green: `… zig build test && … zig build test-integration`).
- [ ] **Step 5: fmt + commit** `fix(security): validate chunk metadata on load to prevent enum-UB and alloc DoS (F2)`.

### Task A3: Bound `metric_len` before allocation (F3)

**Files:**
- Modify: `src/store.zig` (`loadAllSeriesKeyMeta` :624-626, `readSeriesKeyForChunkId` :675-677)
- Test: `src/store.zig` tests section

**Interfaces:**
- Produces: both readers may now return `error.CorruptMeta`; both are already `!`-returning, so no caller change beyond error propagation (already `try`-ed).

- [ ] **Step 1: Write the failing test.** Add a test that writes a `series_meta.dat` under a temp dir with a single record whose `metric_len` field = `0xFFFFFFFF` (id 8 bytes, device 8 bytes, len 4 bytes = 0xFFFFFFFF, no metric bytes), constructs a `Store` with that `data_dir`, calls the load path, and asserts it returns `error.CorruptMeta` (not OOM/panic). Follow the temp-dir pattern used by existing store persistence tests (`/tmp/ts_..._{pid}`).
- [ ] **Step 2: Run, verify fail.** `… zig build test`.
- [ ] **Step 3: Implement.** Add near the top of `store.zig`:
  ```zig
  /// Max length of a persisted metric name (corruption/DoS guard).
  const MAX_METRIC_LEN: u32 = 4096;
  ```
  In both readers, immediately after `const metric_len = std.mem.readInt(u32, &len_buf, .little);`, insert:
  ```zig
  if (metric_len > MAX_METRIC_LEN) return error.CorruptMeta;
  ```
- [ ] **Step 4: Run tests, verify pass.** `… zig build test && … zig build test-integration`.
- [ ] **Step 5: fmt + commit** `fix(security): bound metric_len before allocation to prevent load-time DoS (F3)`.

---

## Workstream B — Filesystem & Supply-Chain Hardening (appsec F4, F5, F8)

### Task B1: Create persisted files with 0o600 and no-follow (F4)

**Files:**
- Modify: `src/chunk_storage.zig` (`createFile` at :428 for `chunks.dat`, :630 for `chunk_meta.dat`), `src/store.zig` (:541 for `series_meta.dat`)
- Test: `src/chunk_storage.zig` and/or `src/store.zig` tests (POSIX-gated)

**Interfaces:**
- Produces: a shared helper for secure create options. Add to each file a small local helper:
  ```zig
  /// Restrictive file permissions for persisted data (POSIX 0o600; default elsewhere).
  fn securePermissions() std.Io.File.Permissions {
      return if (@import("builtin").os.tag == .windows) .default_file else @enumFromInt(0o600);
  }
  ```

- [ ] **Step 1: Write the failing test.** POSIX-only test (`if (@import("builtin").os.tag == .windows) return;`): create a `ChunkStorage` in a temp dir, then `stat` `chunks.dat` via `std.Io.Dir.cwd().statFile` (or `file.stat`) and assert `mode & 0o777 == 0o600`. Because Zig applies umask, assert the world/group bits are clear: `assert(mode & 0o077 == 0)`.
- [ ] **Step 2: Run, verify fail** (default 0o644 today). `… zig build test`.
- [ ] **Step 3: Implement.** Add `.permissions = securePermissions(), .resolve_beneath = true,` to all three `createFile` option literals. Keep `.read = true, .truncate = false`.
- [ ] **Step 4: Run tests, verify pass.** `… zig build test && … zig build test-integration`.
- [ ] **Step 5: fmt + commit** `fix(security): restrict persisted file permissions to 0o600 and resolve-beneath (F4)`.

### Task B2: Pin CI catalog components and otel to immutable SHAs (F5, F8)

**Files:**
- Modify: `.gitlab-ci.yml` (:11-25 component includes), `build.zig.zon` (:11-15 otel dep)

- [ ] **Step 1: Resolve tag→SHA.** For each `gitlab.com/devnw/ci-catalog/<name>@v1.43.0` include and for `otel` `#v0.1.17`, resolve the tag to its commit SHA (`git ls-remote https://gitlab.com/devnw/ci-catalog.git v1.43.0` and `git ls-remote https://gitlab.com/devnw/zig/otel.git v0.1.17`). If the ci-catalog components require a `@version` semver ref (GitLab component syntax may not accept a SHA), pin the CI toolchain download and keep an explicit inline comment recording the resolved SHA per component so drift is detectable; prefer SHA where GitLab accepts it. For `otel`, change the URL fragment from `#v0.1.17` to the resolved commit SHA (matching the `thread_pool` pattern), leaving the `.hash` unchanged.
- [ ] **Step 2: Validate CI syntax.** Run the GitLab CI lint (`glab ci lint` or the MCP `validate_project_ci_lint`) to confirm the pipeline config still parses.
- [ ] **Step 3: Verify build unaffected.** `mise exec zig@0.16.0 -- zig build check` (otel is lazy/default-off; confirm no fetch break) and, if feasible, `-Dwith_otel=true` build still resolves the SHA-pinned dep.
- [ ] **Step 4: fmt-check + commit** `build(security): pin otel and CI components to immutable refs (F5, F8)`.

---

## Workstream C — ABI & API Robustness (appsec F6, F7, F9)

### Task C1: Null-check ABI input pointers (F6)

**Files:**
- Modify: `src/abi.zig` (all data functions taking `[*]const f64` inputs; `ts_twed` :371-394 has the widest surface with `a_times`/`b_times`)
- Test: `src/abi_test.zig`

- [ ] **Step 1: Write the failing test.** Add a test calling `ts_twed` (and one other, e.g. `ts_dtw`) with a NULL data pointer (`@ptrFromInt(0)`) and positive length, asserting the function returns the error sentinel (`-1`) instead of dereferencing. Match the existing `abi_test.zig` call conventions.
- [ ] **Step 2: Run, verify fail** (segfault/crash today). `… zig build test`.
- [ ] **Step 3: Implement.** For each exported function, before slicing input many-pointers, add guards mirroring the existing output-pointer `orelse return -1` style:
  ```zig
  if (@intFromPtr(a) == 0 or @intFromPtr(b) == 0) return -1;
  ```
  For `ts_twed` also guard `a_times` and `b_times`. Add a one-line doc note in `src/ts_abi.h` for the relevant functions stating input arrays must be non-NULL and `*_times` arrays must have length ≥ the corresponding `*_len`.
- [ ] **Step 4: Run tests, verify pass.** `… zig build test`.
- [ ] **Step 5: fmt + commit** `fix(security): null-check ABI input pointers incl. ts_twed time arrays (F6)`.

### Task C2: Overflow-safe span math in sampleBy/timeBucketAvg (F7)

**Files:**
- Modify: `src/store.zig` (`sampleBy` :311, `timeBucketAvg` :404)
- Test: `src/store.zig` tests

- [ ] **Step 1: Write the failing test.** Add a test calling `sampleBy` (and `timeBucketAvg`) with `start_ts = std.math.minInt(i64)`, `end_ts = std.math.maxInt(i64)`, `interval_ms = 1`, asserting it returns an error or an empty/handled result rather than panicking. (Given the existing early-return guards, the target behavior is: detect the overflow and return `error.RangeTooLarge` or an empty result — pick whichever matches the function's existing error surface; prefer returning an empty allocation-free result to preserve the current success-typed contract, else add the error to its set.)
- [ ] **Step 2: Run, verify fail** (checked-overflow panic today). `… zig build test`.
- [ ] **Step 3: Implement.** Replace the raw `(end_ts - start_ts)` subtraction with checked math and cap the bucket count:
  ```zig
  const span = std.math.sub(i64, end_ts, start_ts) catch return &.{}; // or return error.RangeTooLarge
  const n_buckets_u: u64 = @intCast(@divTrunc(span + interval_ms - 1, interval_ms));
  if (n_buckets_u > MAX_BUCKETS) return &.{}; // define MAX_BUCKETS, e.g. 1 << 26
  const n_buckets: usize = @intCast(n_buckets_u);
  ```
  Match the exact return type of each function (empty slice vs error); keep both functions' existing signatures unless an error tag is cleaner.
- [ ] **Step 4: Run tests, verify pass.** `… zig build test && … zig build test-integration`.
- [ ] **Step 5: fmt + commit** `fix(security): overflow-safe bucket math in sampleBy/timeBucketAvg (F7)`.

### Task C3: Return errors instead of asserting in parallel entry points (F9)

**Files:**
- Modify: `src/parallel.zig` (:127, :246, :324 `std.debug.assert` on caller slice lengths)
- Test: `src/parallel_test.zig`

- [ ] **Step 1: Write the failing test.** Add a test that calls the affected public batch function with mismatched output/candidate slice lengths and asserts it returns `error.LengthMismatch` (in a ReleaseFast build the current assert is compiled out, so this also closes a silent-UB path).
- [ ] **Step 2: Run, verify fail.** `… zig build test`.
- [ ] **Step 3: Implement.** Replace each `std.debug.assert(out_results.len == candidates.len);` with:
  ```zig
  if (out_results.len != candidates.len) return error.LengthMismatch;
  ```
  Add `error.LengthMismatch` to the function's error set if it is explicitly declared.
- [ ] **Step 4: Run tests, verify pass.** `… zig build test`.
- [ ] **Step 5: fmt + commit** `fix(robustness): return LengthMismatch instead of asserting in parallel batch APIs (F9)`.

---

## Workstream D — Build / Gap Compile Fixes (gap-scanner G1, G2; quality)

### Task D1: Fix `tests/fuzz.zig` for Zig 0.16 `std.testing.fuzz` (G1)

**Files:**
- Modify: `tests/fuzz.zig` (:83, :116, :138 `std.testing.fuzz(.{}, struct {...}.testOne, .{})`)

- [ ] **Step 1: Reproduce.** `mise exec zig@0.16.0 -- zig build fuzz --summary all` → 3 compile errors (`testOne` must be `fn(ctx, *testing.Smith)`).
- [ ] **Step 2: Update signatures.** In Zig 0.16, `testOne` takes `smith: *std.testing.Smith`. Replace each `testOne(ctx, input: []const u8)` with the new signature and derive the fuzz bytes from the smith (e.g. `const input = smith.bytes();` or the 0.16 equivalent — verify the exact Smith API in `lib/std/testing.zig` around line 1229). Keep each target's existing property assertions on the decoded/derived inputs.
- [ ] **Step 3: Verify compile + short run.** `mise exec zig@0.16.0 -- zig build fuzz` compiles; the CI native path `mise exec zig@0.16.0 -- zig build test --fuzz` (bounded, e.g. `timeout 60`) runs without crashing.
- [ ] **Step 4: fmt + commit** `fix(test): port fuzz targets to Zig 0.16 std.testing.Smith API (G1)`.

### Task D2: Fix `examples/basic.zig` and wire it into the build (G2)

**Files:**
- Modify: `examples/basic.zig` (:20 `std.io.getStdOut()`), `build.zig` (add an example compile/check step)

- [ ] **Step 1: Reproduce.** `mise exec zig@0.16.0 -- zig build-obj examples/basic.zig` → `std` has no member `io`.
- [ ] **Step 2: Make it compile and actually run.** Replace the removed stdout API with the 0.16 pattern (`std.fs.File.stdout()` / the current `std.Io`-based writer, verified against the installed stdlib), and convert the commented-out API calls into real, minimal working calls (`Store.init`, `insertMany`, `sampleBy`, `extractFeatures`, plus a `ChunkStorage.writePoints`/`queryRange` round-trip) so the example is a genuine, compiling demonstration.
- [ ] **Step 3: Wire into build.** Add an `examples` step in `build.zig` that compiles `examples/basic.zig` against the `timeseries` module and add it to `check` (or a dedicated `zig build examples` step) so CI catches future example breakage.
- [ ] **Step 4: Verify.** `mise exec zig@0.16.0 -- zig build examples` (or the new step) compiles and runs; `… zig build check` still green.
- [ ] **Step 5: fmt + commit** `fix(example): port basic.zig to Zig 0.16 and gate it in the build (G2)`.

### Task D3: Correct `minimum_zig_version` (quality)

**Files:**
- Modify: `build.zig.zon` (:5)

- [ ] **Step 1: Change** `.minimum_zig_version = "0.15.1"` → `.minimum_zig_version = "0.16.0"` (matches the CI-pinned `ZIG_VERSION` and the actual `std.Io` API requirement).
- [ ] **Step 2: Verify** `mise exec zig@0.16.0 -- zig build check` still passes and fmt-check is clean.
- [ ] **Step 3: Commit** `build: correct minimum_zig_version to 0.16.0 to match actual requirement`.

---

## Workstream E — Performance (perf-scanner P0/P1/P2/P3)

### Task E1: Gate `saveSeriesKeyMeta` on new series only (perf P0 / F1)

**Files:**
- Modify: `src/store.zig` (`insertMany` :235-236)
- Test: `src/store.zig` tests (behavioral: persistence round-trip unchanged)

- [ ] **Step 1: Write/confirm the guard test.** Ensure an existing or new test covers: insert the same series many times with a `chunk_store` enabled, then `loadFromDisk` into a fresh `Store` and assert the series key is recovered exactly once (proves dedup still works when the per-insert scan is removed).
- [ ] **Step 2: Implement.** Replace the unconditional call at :236 with a gate on the reverse-map insertion result already computed at :230-233:
  ```zig
  if (!id_gop.found_existing) {
      try self.saveSeriesKeyMeta(key, chunk_id);
  }
  ```
  This eliminates the O(total-distinct-series) file rescan on every `insertMany` (the map already tracks whether the mapping was persisted this run or loaded from disk).
- [ ] **Step 3: Verify.** `… zig build test && … zig build test-integration` all green (esp. persistence/loadFromDisk tests).
- [ ] **Step 4: Commit** `perf(store): persist series-key metadata once per series, not per insert (P0)`.

### Task E2: Give `crossCorrelate` a caller allocator, drop hidden `page_allocator` (perf P1 / quality)

**Files:**
- Modify: `src/distances.zig` (`crossCorrelateFFT` :145,:153-160; public `crossCorrelate` :210; `sbd` :263-267 caller), any callers in `src/parallel.zig`, `src/abi.zig`
- Test: `src/distances_test.zig`

**Interfaces:**
- Produces: `crossCorrelate` signature gains a leading `allocator: std.mem.Allocator` parameter: `pub fn crossCorrelate(allocator, a, b) TsError!CorrelationResult`. `sbd` and all callers thread an allocator through. The C ABI wrapper in `abi.zig` passes the existing `page_allocator` explicitly (documented, intentional at the FFI boundary).

- [ ] **Step 1: Update the test.** Adjust `distances_test.zig` cross-correlate/SBD tests to pass `std.testing.allocator`, which now leak-checks the FFT buffers.
- [ ] **Step 2: Run, verify fail** (signature mismatch compile error). `… zig build test`.
- [ ] **Step 3: Implement.** Add the `allocator` param to `crossCorrelate` and `crossCorrelateFFT`; replace `std.heap.page_allocator` with the passed allocator for the 4 FFT buffers. Thread the allocator through `sbd` and every caller (`parallel.zig` batch dispatch, `abi.zig` — pass `std.heap.page_allocator` there with a comment noting the FFI boundary has no caller allocator).
- [ ] **Step 4: Run tests, verify pass** with no leaks. `… zig build test && … zig build test-integration`.
- [ ] **Step 5: fmt + commit** `perf(distances): thread caller allocator through crossCorrelate/sbd (P1)`.

### Task E3: Hold `chunk_meta.dat` handle open instead of per-flush reopen (perf P2)

**Files:**
- Modify: `src/chunk_storage.zig` (`appendChunkMeta` :625-641; struct fields ~:406-414; `init` :428-447; `deinit` :452+)
- Test: existing chunk write/retention integration tests

- [ ] **Step 1: Implement.** Add a persistent `meta_file: std.Io.File` field to `ChunkStorage`, opened once in `init` (with the same `securePermissions()`/`resolve_beneath` from Task B1) and closed in `deinit`. Rewrite `appendChunkMeta` to append via the held handle (seek to `file.length` or track a running `meta_offset`) instead of open/write/close per call.
- [ ] **Step 2: Verify.** `… zig build test && … zig build test-integration` green (round-trip + retention). Confirm no double-close in `deinit`.
- [ ] **Step 3: Commit** `perf(chunk_storage): keep chunk_meta.dat handle open across flushes (P2)`.

### Task E4: Reconcile mpDist AB-join follow-up and missing `parallelBatchCrossCorrelate` (perf P2-suspected/P3)

**Files:**
- Modify: `src/parallel.zig` (stale comments at :74,:311,:394 referencing `parallelBatchCrossCorrelate`), `docs/PERF_GAP_ANALYSIS.md`

- [ ] **Step 1: Decide.** Either implement `parallelBatchCrossCorrelate` (mirroring `parallelBatchDistances` structure, dispatching `sbd`/`crossCorrelate` across the pool) OR correct the comments to remove the dangling reference. Prefer implementing it for API completeness if it is a thin wrapper; otherwise fix the comments and note it as a tracked enhancement.
- [ ] **Step 2: Record the AB-join finding.** Add a PERF_GAP_ANALYSIS.md entry: `mpDist`/`mpDistAbJoinRow` (`matrix_profile.zig:253-317`) still recomputes an O(w) dot product per pair; a diagonal-recurrence (STOMP-style) AB-join is a P2 follow-up needing a benchmark at plen≈1000-5000. Mark it Open with confidence::suspected.
- [ ] **Step 3: Verify + commit.** If code changed, `… zig build test`. Commit `perf(parallel): resolve parallelBatchCrossCorrelate reference; track AB-join QT follow-up`.

---

## Workstream F — CI & Docs Reconciliation (quality-scanner; gap-collector)

### Task F1: Add Zig toolchain + package cache to CI and de-duplicate optimize-mode jobs

**Files:**
- Modify: `.gitlab-ci.yml`

- [ ] **Step 1: Add caching.** Add a `cache:` block (keyed on `build.zig.zon`) that persists the extracted Zig toolchain dir and Zig's global package cache (`~/.cache/zig`) across the 11 jobs, so `thread_pool`/`otel` and the toolchain aren't re-fetched per job.
- [ ] **Step 2: De-duplicate.** Collapse the 7 near-identical `test*`/`test-integration*` optimize-mode jobs into a `parallel:matrix:` over `-Doptimize=` values (or a shared hidden-job template), preserving the exact commands each currently runs.
- [ ] **Step 3: Validate.** `glab ci lint` (or MCP `validate_project_ci_lint`) passes; confirm the job matrix still covers Debug/ReleaseSafe/ReleaseFast/ReleaseSmall for both test and test-integration.
- [ ] **Step 4: Commit** `ci: cache Zig toolchain/packages and collapse optimize-mode jobs via matrix`.

### Task F2: Fix markdownlint MD040 and `.cz.yaml` formatting

**Files:**
- Modify: `docs/SECURITY_GAP_ANALYSIS.md` (:175), `.gitlab/issue_templates/Bug Report.md` (:44), `CONTRIBUTING.md` (:48), `.cz.yaml`

- [ ] **Step 1: Implement.** Add a language tag (e.g. ```` ```text ````) to each unlabeled fenced code block flagged by MD040; run `pretty-format-yaml` on `.cz.yaml` and keep the result.
- [ ] **Step 2: Verify.** `pre-commit run markdownlint --all-files` and `pre-commit run pretty-format-yaml --all-files` report clean (no auto-fix rewrites).
- [ ] **Step 3: Commit** `docs: add fenced-code languages (MD040) and format .cz.yaml`.

### Task F3: Reconcile flatfile gap docs with verified code state

**Files:**
- Modify: `docs/SECURITY_GAP_ANALYSIS.md` (S9/S10 status, S12 classification), `docs/QUALITY_GAP_ANALYSIS.md` (Q17, Q18 → Closed), `docs/GAP_ANALYSIS.md` (GAP-0014 fuzz, GAP-0019 example staleness), `docs/PERF_GAP_ANALYSIS.md` (#32/#58 reconciliation from Task E4)

- [ ] **Step 1: Update security doc.** Mark S9/S10 as Closed-by-this-work (now that Task B1 implements 0o600 + resolve_beneath), citing the new commits/tests. Re-classify S12 honestly as "accepted risk / now SHA-pinned" per Task B2's outcome.
- [ ] **Step 2: Update quality doc.** Move Q17 (algorithm citations — verified present in dtw/distances/pelt/matrix_profile) and Q18 (broken doc links — verified all 8 targets exist) from triage to Closed with evidence.
- [ ] **Step 3: Update gap doc.** Note GAP-0014 (fuzz) closed by Task D1 and GAP-0019 (example) closed by Task D2.
- [ ] **Step 4: Commit** `docs: reconcile gap-analysis flatfiles with verified code state`.

### Task F4: Sync GitLab issue state to match verified closures

**Files:** (platform, not code)

- [ ] **Step 1:** For each finding closed by Workstreams A–F, transition the corresponding GitLab issue (from the gap-collector mapping: S-findings #38/#45/#48/#53/#57/#61/#66/#69/#71/#73; Q #34…#65; P #32/#36/…; plus new appsec F1–F9) to closed with a comment citing the commit/test evidence, OR file new issues for genuinely new findings (F1–F9, perf E-findings, CI items) and then close the ones this work resolves. Use `glab`/GitLab MCP. Leave genuinely-open follow-ups (mpDist AB-join QT) open.
- [ ] **Step 2:** Record the issue actions in the final audit summary.

---

## Self-Review

- **Spec coverage:** Every appsec finding F1–F9 → A1/A2/A3/B1/B2/C1/C2/B2/C3. Every gap-scanner gap (fuzz, example, min-zig) → D1/D2/D3. Every perf finding P0–P3 → E1/E2/E3/E4. Every quality finding (min-zig, CI cache, CI dup, MD040, cz.yaml, Q17/Q18) → D3/F1/F2/F3. Doc/issue reconciliation → F3/F4. Covered.
- **Placeholders:** None — each task names exact files, line anchors, and the concrete guard/edit.
- **Type consistency:** New error tags (`error.CorruptChunk`, `error.CorruptMeta`, `error.LengthMismatch`) and the `crossCorrelate(allocator, …)` signature change are threaded through their callers in the same task that introduces them.
- **Ordering note:** Do Workstream A and B1 before E3 (E3 reuses `securePermissions()` from B1). Do D3 anytime. Everything else is independent.
