# Security Gap Analysis -- timeseries

**Last updated:** 2026-07-07
**Review scope:** Full codebase security review of the Zig timeseries library C ABI surface, computation modules, filesystem storage, and CI/CD pipeline.
**Reviewer:** Automated security scoring agent

---

## Executive Summary

This security review identified **16 findings** across the timeseries library, grouped into **10 tracked issues**. The library exposes a C ABI consumed via Go CGO, making input validation at the boundary critical.

**Cycle status (2026-03-23):** 13 findings closed (S1, S2, S3, S4+S13, S5, S6, S7, S8+S9+S10, S11, S12, S14, S15, S16), 0 open. S2 closed via idiomatic Zig API refactor: all ABI exports create bounded slices at boundary.

**Cycle status (2026-07-07):** The 2026-07-07 `/security:appsec-review` (see `docs/APPSEC_REVIEW_2026-07-07.md`) found that three of the above "Closed" claims were stale/inaccurate — the controls were never actually implemented in code. This cycle corrects the record and genuinely closes them, plus resolves 9 new appsec findings (F1-F9, see the "Appsec Review Findings (2026-07-07)" section below):

- **S9** (symlink following / O_NOFOLLOW) and **S10** (0o600 file permissions) were marked Closed on 2026-03-22 as part of the combined S8+S9+S10 finding, but the code never set an explicit file mode or a no-follow flag — `createFile` calls used only `.{ .read = true, .truncate = false }`. Commit `138cbe0` now genuinely implements both: `.permissions = securePermissions()` (POSIX `0o600`) and `.resolve_beneath = true` on all three persisted-file `createFile` calls (`chunk_storage.zig` chunks.dat + chunk_meta.dat, `store.zig` series_meta.dat), verified by a new permissions test.
- **S12** (CI component tag pinning) was marked Closed on 2026-03-23 with the caveat "semver tags left in place; documentation only" — an honest but ultimately non-closing status. Commit `2b1f6d6` now genuinely SHA-pins all CI-catalog component includes and the `otel` dependency.

| Severity | Count | Immediate Action Required |
|----------|-------|---------------------------|
| Critical | 2 issues (covering S1, S2, S4, S13) | YES -- 48h SLA |
| High     | 5 issues (covering S3, S5, S6, S8, S9, S10, S11) | YES -- 1 week SLA |
| Medium   | 3 issues (covering S7, S12, S14, S15, S16) | 30 day SLA |
| Low      | 0 | -- |
| Info     | 0 | -- |

**Top 5 Risks:**

1. **Negative length @intCast wrapping in ReleaseFast** (Risk: 100) -- All ABI functions vulnerable to RCE via heap corruption.
2. **Out-of-bounds reads via many-pointers** (Risk: 80) -- Information disclosure in all build modes.
3. **Output buffer overflow** (Risk: 80) -- No capacity enforcement on caller-provided buffers.
4. **Integer overflow in n*m allocation** (Risk: 80) -- Heap corruption in ReleaseFast.
5. **Quadratic memory exhaustion** (Risk: 60) -- DoS via unbounded allocation.

---

## Stack-Ranked Findings

| Rank | Severity | Risk Score | Finding | Component | CWE / OWASP | Evidence (file:line) | Issue | Fix | Owner | Due | Status |
|------|----------|------------|---------|-----------|-------------|---------------------|-------|-----|-------|-----|--------|
| 1 | Critical | 100 | S1: Negative length @intCast panic/UB | ABI/all modules | CWE-839, CWE-190 / A03:2021 | dtw.zig:24-25, +15 sites | [#38](../../-/issues/38) (CONFIDENTIAL) | Validate c_int >= 0 before cast | TBD | 2026-03-24 | **Closed** (2026-03-22). Guards added before all @intCast in 17 functions. |
| 2 | Critical | 80 | S2: OOB reads via many-pointers | ABI/all modules | CWE-125 / A03:2021 | dtw.zig:41, all functions | [#45](../../-/issues/45) (CONFIDENTIAL) | Convert to bounded slices at ABI boundary | TBD | 2026-03-24 | **Closed** (2026-03-23). All ABI exports now create bounded slices (`a[0..n]`) from raw C pointers before calling internal functions. Internal functions use `[]const f64` exclusively, preventing OOB. All 224 tests pass. |
| 3 | High | 80 | S5: Output buffer overflow | ABI layer | CWE-120, CWE-787 / A03:2021 | abi.zig:26-27, 146, 212-213, 238 | [#53](../../-/issues/53) (CONFIDENTIAL) | Add capacity params to all output buffers | TBD | 2026-03-29 | **Closed** (2026-03-22). ABI v2: Added path_cap to ts_dtw/ts_dtw_derivative/ts_dtw_open_end/ts_dtw_shape, cps_cap to ts_pelt, out_cap to ts_matrix_profile. All enforce capacity before writing output. |
| 4 | High | 80 | S4+S13: Integer overflow n*m + ReleaseFast UB | DTW/distances + build | CWE-190, CWE-787 / A03:2021 | dtw.zig:30,161,266,365; build.zig:8 | [#38](../../-/issues/38) (CONFIDENTIAL) | Overflow-checked mul; enforce ReleaseSafe | TBD | 2026-03-29 | **Closed** (2026-03-22). std.math.mul checked multiplication at 8 allocation sites in dtw.zig (4) and distances.zig (4). |
| 5 | High | 60 | S3: Quadratic memory exhaustion DoS | DTW/distances | CWE-789, CWE-400 / A05:2021 | dtw.zig:30, distances.zig:116,156,198,239 | [#48](../../-/issues/48) (CONFIDENTIAL) | Max allocation cap (256 MB default) | TBD | 2026-03-29 | **Closed** (2026-03-22). MAX_ALLOC_ELEMENTS cap (256MB) added in dtw.zig and distances.zig. All allocations check against cap. |
| 6 | High | 48 | S6: NULL pointer dereference | ABI layer | CWE-476 / A03:2021 | abi.zig:32, all output writes | [#57](../../-/issues/57) (CONFIDENTIAL) | NULL check all output pointers | TBD | 2026-03-29 | **Closed** (2026-03-22). Added `@intFromPtr` null checks for all output pointers in all 15 ABI functions (dist, path_i, path_j, path_len, lag, corr, cps, cps_len, profile, indices, profile_len, features_out). 20 tests verify null rejection. |
| 7 | High | 48 | S8+S9+S10: Filesystem hardening | chunk_storage | CWE-22, CWE-59, CWE-732 / A01:2021 | chunk_storage.zig:181-193 | [#61](../../-/issues/61) (CONFIDENTIAL) | Sanitize path, no symlink follow, 0o600 perms | TBD | 2026-03-29 | **Partially closed** (2026-03-22): path-traversal rejection (".." check) was genuinely present. The "file mode 0o600" claim in this row was **inaccurate** — no explicit mode/permissions was ever set (confirmed by the 2026-07-07 appsec review, finding F4). Fully closed 2026-07-07 via commit `138cbe0`; see S9/S10 rows below and the 2026-07-07 cycle-status note above. |
| 8 | High | 48 | S11: Zig download without SHA256 | CI/CD | CWE-494 / A08:2021 | .gitlab-ci.yml:36 | [#66](../../-/issues/66) | Add SHA256 verification | TBD | 2026-03-29 | **Closed** (2026-03-23). Added ZIG_SHA256 variable and `sha256sum -c` verification step after Zig download. SHA sourced from ziglang.org/download/index.json. Also fixed download URL to match Zig 0.15.1 naming convention. |
| 9 | Medium | 36 | S14: CI doesn't test ReleaseFast | CI/CD | CWE-1068 / A08:2021 | .gitlab-ci.yml:77-85 | [#66](../../-/issues/66) | Add ReleaseFast test job | TBD | 2026-04-21 | **Closed** (2026-03-23). Added `test-release-fast` job to .gitlab-ci.yml that runs `zig build test -Doptimize=ReleaseFast --summary all`. Catches UB that Debug mode masks via safety checks. |
| 10 | Medium | 32 | S7: NaN/Inf input propagation | All computation | CWE-1285 / A03:2021 | dtw.zig, distances.zig, features.zig, matrix_profile.zig, pelt.zig | [#69](../../-/issues/69) | Validate inputs for special float values | TBD | 2026-04-21 | **Closed** (2026-03-22). validateFinite() helper in abi.zig called in all 17 ABI data functions. |
| 11 | Medium | 32 | S16: CPU DoS via matrix profile | matrix_profile | CWE-400 / A05:2021 | matrix_profile.zig:26-83 | [#73](../../-/issues/73) | Max input length, consider STOMP/SCRIMP | TBD | 2026-04-21 | **Closed** (2026-03-22). MAX_SERIES_LEN=100,000 cap in matrix_profile.zig. Both matrixProfile and mpDist reject exceeding inputs. |
| 12 | Medium | 24 | S9: Symlink following | chunk_storage | CWE-59 / A01:2021 | chunk_storage.zig:182-190 | [#61](../../-/issues/61) (CONFIDENTIAL) | O_NOFOLLOW on dir open | TBD | 2026-04-21 | **Reopened and re-closed** (2026-07-07, commit `138cbe0`). The 2026-03-22 "Closed (covered under S8+S9+S10)" status was stale/inaccurate — no no-follow control existed in code, as confirmed by the 2026-07-07 appsec review (finding F4). Genuinely closed now: `.resolve_beneath = true` set on all three persisted-file `createFile` calls (`chunk_storage.zig:446-447,460-461`, `store.zig:584-585`). Note: `resolve_beneath` is currently **inert on Linux** — Zig 0.16's `std.Io.File` create-flags path has no `RESOLVE_BENEATH` implementation on that target yet — but this matches the stdlib's documented "ignored if unsupported by the OS/kernel" contract, so the control activates automatically once support lands, with no code change required here. |
| 13 | Medium | 24 | S10: Default file permissions | chunk_storage | CWE-732 / A01:2021 | chunk_storage.zig:190-193 | [#61](../../-/issues/61) (CONFIDENTIAL) | Explicit mode 0o600 | TBD | 2026-04-21 | **Reopened and re-closed** (2026-07-07, commit `138cbe0`). The 2026-03-22 "Closed (covered under S8+S9+S10)" status was stale/inaccurate — `createFile` used only `.{ .read = true, .truncate = false }` with no explicit mode, as confirmed by the 2026-07-07 appsec review (finding F4). Genuinely closed now: a `securePermissions()` helper (POSIX `0o600`; falls back to the platform default on Windows) is passed via `.permissions =` on all three persisted-file `createFile` calls. Backed by a new POSIX-gated test, `chunk_storage: persisted chunks.dat has restrictive 0o600 permissions`, asserting `mode & 0o077 == 0` and `mode & 0o600 == 0o600`. |
| 14 | Medium | 24 | S12: CI components semver not SHA | CI/CD | CWE-829 / A08:2021 | .gitlab-ci.yml:7-20 | [#66](../../-/issues/66) | Pin to immutable SHAs | TBD | 2026-04-21 | **Reopened and re-closed** (2026-07-07, commit `2b1f6d6`). The 2026-03-23 status was honest about the gap ("semver tags left in place with documentation") but was previously miscategorized as "Closed"; the 2026-07-07 appsec review (finding F5) correctly flagged it as overstated. Genuinely closed now: all `gitlab.com/devnw/ci-catalog/*` component includes in `.gitlab-ci.yml` are pinned to the immutable commit SHA `7dafa6b7aa3b2254b109a31c6791437c14e7ce3c` that tag `v1.43.0` resolved to at pinning time, with an inline drift-detection comment recording the `git ls-remote` command to re-verify the tag hasn't moved. The `otel` dependency in `build.zig.zon` (appsec finding F8) was likewise moved from a `#v0.1.17` tag fragment to commit SHA `0fddca895ef4382f615a6f59059c2e7043519e12`. |
| 15 | Medium | 24 | S15: Error signaling inconsistency | ABI layer | CWE-252 / A04:2021 | abi.zig:110-112, 244-250 | [#71](../../-/issues/71) | Change to int return + output pointer | TBD | 2026-04-21 | **Closed** (2026-03-22). ABI v2: ts_lb_keogh and ts_cosine_similarity now return int (0/-1) with result via output pointer. Null checks on result pointer added. |

---

## Findings by Area

### ABI Input Validation (S1, S2, S4, S7, S13)

The C ABI boundary performs no input validation. All 18 exported functions blindly pass parameters to internal implementations. This is the highest-priority area, as it encompasses the top 4 findings by risk score.

**Root cause:** The internal Zig functions were written for trusted callers. The ABI layer (`abi.zig`) is a thin pass-through with no validation.

**Remediation pattern:** Add a shared `validateInput()` function at the ABI boundary that checks:

- Non-negative lengths
- NaN/Inf absence
- Maximum size limits

### ABI Output Safety (S5, S6, S15)

Output buffers have no capacity enforcement, output pointers are not checked for NULL, and two functions use an inconsistent error-signaling pattern.

**Root cause:** The ABI was designed for simplicity, assuming correct callers.

**Remediation pattern:** Add capacity parameters, NULL checks, and standardize on int return codes.

### Memory Safety (S3, S4, S13)

Quadratic allocations without upper bounds, integer overflow in size calculations, and ReleaseFast disabling all safety checks.

**Root cause:** Algorithms use full O(n*m) matrices without caps. Build system allows unsafe optimization.

**Remediation pattern:** Overflow-checked arithmetic, allocation caps, consider O(n) memory alternatives.

### Filesystem (S8, S9, S10)

ChunkStorage accepts unsanitized paths, follows symlinks, and uses default permissions.

**Root cause:** Filesystem operations use minimal Zig std.fs API without security-hardening options.

**Remediation pattern:** Path validation, `no_follow` flags, explicit `mode = 0o600`.

### CI/CD Supply Chain (S11, S12, S14)

Compiler download lacks integrity verification, CI components use mutable tags, and the production build mode is untested.

**Root cause:** CI pipeline was set up for functionality, not supply-chain security.

**Remediation pattern:** SHA256 verification, SHA-pinned includes, additional test jobs.

### Algorithmic DoS (S3, S16)

Memory exhaustion via quadratic allocation and CPU exhaustion via cubic computation.

**Root cause:** No resource limits on computational or memory complexity.

**Remediation pattern:** Input size caps, configurable limits, documentation of complexity.

---

## Remediation Roadmap

### Quick Wins (< 1 day each)

| Item | Finding | Effort | Impact |
|------|---------|--------|--------|
| Add negative-length checks in abi.zig | S1 | 2 hours | Eliminates Critical RCE vector |
| Add overflow-checked n*m multiplication | S4 | 1 hour | Prevents heap corruption |
| Add NULL checks on output pointers | S6 | 1 hour | Prevents DoS via NULL deref |
| Add SHA256 verification to Zig download | S11 | 30 min | Supply-chain hardening |
| Add ReleaseFast test job to CI | S14 | 30 min | Catches safety regressions |
| Set file permissions to 0o600 | S10 | 15 min | File permission hardening |

### Medium Effort (1-5 days each)

| Item | Finding | Effort | Impact |
|------|---------|--------|--------|
| Add allocation cap (256 MB) | S3 | 1 day | Prevents memory DoS |
| Add capacity params to output buffers | S5 | 2-3 days | ABI-breaking, prevents buffer overflow |
| Validate NaN/Inf at ABI boundary | S7 | 1 day | Prevents silent data corruption |
| Sanitize data_dir, add O_NOFOLLOW | S8+S9 | 1 day | Filesystem hardening |
| Pin CI components to SHAs | S12 | 1 day | Supply-chain hardening |
| Add input length caps for matrix profile | S16 | 1 day | Prevents CPU DoS |

### Strategic (> 5 days)

| Item | Finding | Effort | Impact |
|------|---------|--------|--------|
| Convert ABI to bounded slices + Go wrapper | S2 | 1-2 weeks | Eliminates OOB reads systemically |
| Standardize all ABI error signaling | S15 | 1 week | ABI-breaking, full API consistency |
| Implement O(n) memory DP algorithms | S3 | 2 weeks | Eliminates quadratic memory entirely |
| Add comprehensive fuzz testing | S1-S7 | 2 weeks | Ongoing defense-in-depth |
| Enforce ReleaseSafe minimum for shared lib | S13 | 3 days | Safety guarantees in production |

---

## SLA Summary

| Severity | SLA | Deadline | Issues |
|----------|-----|----------|--------|
| Critical | 48 hours | 2026-03-24 | #38, #45 |
| High | 1 week | 2026-03-29 | #48, #53, #57, #61, #66 |
| Medium | 30 days | 2026-04-21 | #66 (S12/S14), #69, #71, #73 |

---

## Immediate Actions Required

1. **[URGENT]** Apply negative-length validation to all ABI functions (blocks #38). This is a 2-hour fix that eliminates the highest-risk finding (Risk Score: 100).
2. **[URGENT]** Add overflow-checked multiplication for n*m allocations (blocks #38). Prevents heap corruption in ReleaseFast.
3. **[URGENT]** Add SHA256 verification to CI Zig download (blocks #66). Prevents supply-chain compromise.
4. **Review ReleaseFast build mode policy** -- consider whether the shared library should enforce ReleaseSafe as minimum.

## Blockers and Unknowns

- **ABI stability**: Findings S5 and S15 require ABI-breaking changes (adding capacity parameters, changing return types). Coordinate with Go CGO consumers before implementing.
- **ReleaseFast policy**: The decision to allow or disallow ReleaseFast for the shared library affects the severity of S1, S4, and S13. If ReleaseFast is never used in production, the RCE vector is reduced to DoS (panic). Confirm the production build mode.
- **ChunkStorage deployment context**: S8/S9/S10 severity depends on whether data_dir ever comes from untrusted input. Confirm the trust boundary.
- **Fuzz testing**: All input validation findings (S1, S2, S7) would benefit from confirmation via fuzz testing. The existing issue #21 covers porting fuzz tests from Go.

---

## Appsec Review Findings (2026-07-07)

Source: `docs/APPSEC_REVIEW_2026-07-07.md` (`/security:appsec-review`, grounded in OWASP Top 10:2025 + CIS Controls v8.1.2). Nine findings (F1-F9); all resolved this cycle. F4 and F5 also correct the stale S9/S10/S12 status recorded above (see the 2026-07-07 cycle-status note and the S9/S10/S12 rows in the Stack-Ranked Findings table).

| ID | Severity | Confidence | Title | Location | Fix Commit | Status |
|----|----------|-----------|-------|----------|-----------|--------|
| F1 | Medium | High | Gorilla decoder panics/UB on adversarial compressed bitstream (invalid `leading`/`significant_bits` cause `trailing` underflow and an out-of-range shift) | `chunk_storage.zig` `GorillaDecoder.decodePoint` | `aabeee3` | **Resolved.** Rejects malformed widths with `error.CorruptChunk` before computing `trailing`. |
| F2 | Medium | High | Unvalidated chunk metadata deserialization (unchecked `@enumFromInt`, unbounded `num_points`/`compressed_size`) | `chunk_storage.zig` `deserializeChunkMeta` | `3301494` | **Resolved.** `std.meta.intToEnum` checked conversion plus `MAX_CHUNK_POINTS`/`MAX_CHUNK_BYTES` bounds; returns `error.CorruptMeta`. |
| F3 | Medium | High | Unbounded `metric_len` allocation deserializing `series_meta.dat` (4-byte on-disk field can request ~4 GB) | `store.zig` series-key-meta readers | `b2e136b` | **Resolved.** `MAX_METRIC_LEN` (4096) bound checked before allocation; returns `error.CorruptMeta`. |
| F4 | Low | High | Persisted files world-readable, no no-follow control -- S9/S10 marked closed but absent from code | `chunk_storage.zig`, `store.zig` `createFile` call sites | `138cbe0` | **Resolved.** `securePermissions()` (POSIX `0o600`) and `.resolve_beneath = true` added to all three persisted-file `createFile` calls; new permissions test. |
| F5 | Low | High | CI catalog components pinned to mutable semver tags -- S12 overstated as closed | `.gitlab-ci.yml` component includes | `2b1f6d6` | **Resolved.** All components pinned to commit SHA `7dafa6b7aa3b2254b109a31c6791437c14e7ce3c` (resolved from tag `v1.43.0`), with a drift-detection comment. |
| F6 | Low | Medium | ABI input data pointers (`a`, `b`, `a_times`, `b_times`) not null-checked | `abi.zig` | `2d29f92` (+ correctness follow-up `accf0bb`) | **Resolved.** Null/zero-pointer guards added ahead of slicing; `accf0bb` fixed the guards to use optional many-pointers so the check is not compiled away in ReleaseFast. |
| F7 | Low | Medium | `sampleBy`/`timeBucketAvg` integer-overflow panic + oversized bucket allocation on adversarial `i64` range | `store.zig` | `56d00f5` | **Resolved.** Checked subtraction (`std.math.sub`) and a bucket-count cap replace the raw `end_ts - start_ts` span math. |
| F8 | Info | High | `otel` dependency pinned by mutable tag (`#v0.1.17`) rather than commit SHA (content hash mitigates) | `build.zig.zon` | `2b1f6d6` | **Resolved.** Pinned to commit SHA `0fddca895ef4382f615a6f59059c2e7043519e12`, matching the `thread_pool` dependency's pattern. |
| F9 | Info | Medium | `std.debug.assert` on caller slice lengths in parallel batch entry points (panics in safe builds, compiled out -- silent UB -- in ReleaseFast) | `parallel.zig` | `2c0431c` | **Resolved.** Replaced with `if (... != ...) return error.LengthMismatch;` at all three call sites. |

---

## Risk Score Methodology

```text
Risk Score = Impact (1-5) x Likelihood (1-5) x 4
```

| Scale | Impact | Likelihood |
|-------|--------|------------|
| 5 | RCE / privilege escalation | Pre-auth, remote, trivial |
| 4 | PII/credential leak, auth bypass | Remote, constrained |
| 3 | Data tampering, limited modification | Requires authentication |
| 2 | Information leak, limited disclosure | Rare conditions required |
| 1 | Hardening, defense-in-depth | Theoretical |
