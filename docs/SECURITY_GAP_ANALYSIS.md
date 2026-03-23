# Security Gap Analysis -- timeseries

**Last updated:** 2026-03-22
**Review scope:** Full codebase security review of the Zig timeseries library C ABI surface, computation modules, filesystem storage, and CI/CD pipeline.
**Reviewer:** Automated security scoring agent

---

## Executive Summary

This security review identified **16 findings** across the timeseries library, grouped into **10 tracked issues**. The library exposes a C ABI consumed via Go CGO, making input validation at the boundary critical.

**Cycle status (2026-03-23):** 12 findings closed (S1, S3, S4+S13, S5, S6, S7, S8+S9+S10, S11, S12, S14, S15, S16), 1 open (S2).

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
| 2 | Critical | 80 | S2: OOB reads via many-pointers | ABI/all modules | CWE-125 / A03:2021 | dtw.zig:41, all functions | [#45](../../-/issues/45) (CONFIDENTIAL) | Convert to bounded slices at ABI boundary | TBD | 2026-03-24 | Triage |
| 3 | High | 80 | S5: Output buffer overflow | ABI layer | CWE-120, CWE-787 / A03:2021 | abi.zig:26-27, 146, 212-213, 238 | [#53](../../-/issues/53) (CONFIDENTIAL) | Add capacity params to all output buffers | TBD | 2026-03-29 | **Closed** (2026-03-22). ABI v2: Added path_cap to ts_dtw/ts_dtw_derivative/ts_dtw_open_end/ts_dtw_shape, cps_cap to ts_pelt, out_cap to ts_matrix_profile. All enforce capacity before writing output. |
| 4 | High | 80 | S4+S13: Integer overflow n*m + ReleaseFast UB | DTW/distances + build | CWE-190, CWE-787 / A03:2021 | dtw.zig:30,161,266,365; build.zig:8 | [#38](../../-/issues/38) (CONFIDENTIAL) | Overflow-checked mul; enforce ReleaseSafe | TBD | 2026-03-29 | **Closed** (2026-03-22). std.math.mul checked multiplication at 8 allocation sites in dtw.zig (4) and distances.zig (4). |
| 5 | High | 60 | S3: Quadratic memory exhaustion DoS | DTW/distances | CWE-789, CWE-400 / A05:2021 | dtw.zig:30, distances.zig:116,156,198,239 | [#48](../../-/issues/48) (CONFIDENTIAL) | Max allocation cap (256 MB default) | TBD | 2026-03-29 | **Closed** (2026-03-22). MAX_ALLOC_ELEMENTS cap (256MB) added in dtw.zig and distances.zig. All allocations check against cap. |
| 6 | High | 48 | S6: NULL pointer dereference | ABI layer | CWE-476 / A03:2021 | abi.zig:32, all output writes | [#57](../../-/issues/57) (CONFIDENTIAL) | NULL check all output pointers | TBD | 2026-03-29 | **Closed** (2026-03-22). Added `@intFromPtr` null checks for all output pointers in all 15 ABI functions (dist, path_i, path_j, path_len, lag, corr, cps, cps_len, profile, indices, profile_len, features_out). 20 tests verify null rejection. |
| 7 | High | 48 | S8+S9+S10: Filesystem hardening | chunk_storage | CWE-22, CWE-59, CWE-732 / A01:2021 | chunk_storage.zig:181-193 | [#61](../../-/issues/61) (CONFIDENTIAL) | Sanitize path, no symlink follow, 0o600 perms | TBD | 2026-03-29 | **Closed** (2026-03-22). Path traversal rejection (".." check), file mode 0o600 in ChunkStorage. |
| 8 | High | 48 | S11: Zig download without SHA256 | CI/CD | CWE-494 / A08:2021 | .gitlab-ci.yml:36 | [#66](../../-/issues/66) | Add SHA256 verification | TBD | 2026-03-29 | **Closed** (2026-03-23). Added ZIG_SHA256 variable and `sha256sum -c` verification step after Zig download. SHA sourced from ziglang.org/download/index.json. Also fixed download URL to match Zig 0.15.1 naming convention. |
| 9 | Medium | 36 | S14: CI doesn't test ReleaseFast | CI/CD | CWE-1068 / A08:2021 | .gitlab-ci.yml:77-85 | [#66](../../-/issues/66) | Add ReleaseFast test job | TBD | 2026-04-21 | **Closed** (2026-03-23). Added `test-release-fast` job to .gitlab-ci.yml that runs `zig build test -Doptimize=ReleaseFast --summary all`. Catches UB that Debug mode masks via safety checks. |
| 10 | Medium | 32 | S7: NaN/Inf input propagation | All computation | CWE-1285 / A03:2021 | dtw.zig, distances.zig, features.zig, matrix_profile.zig, pelt.zig | [#69](../../-/issues/69) | Validate inputs for special float values | TBD | 2026-04-21 | **Closed** (2026-03-22). validateFinite() helper in abi.zig called in all 17 ABI data functions. |
| 11 | Medium | 32 | S16: CPU DoS via matrix profile | matrix_profile | CWE-400 / A05:2021 | matrix_profile.zig:26-83 | [#73](../../-/issues/73) | Max input length, consider STOMP/SCRIMP | TBD | 2026-04-21 | **Closed** (2026-03-22). MAX_SERIES_LEN=100,000 cap in matrix_profile.zig. Both matrixProfile and mpDist reject exceeding inputs. |
| 12 | Medium | 24 | S9: Symlink following | chunk_storage | CWE-59 / A01:2021 | chunk_storage.zig:182-190 | [#61](../../-/issues/61) (CONFIDENTIAL) | O_NOFOLLOW on dir open | TBD | 2026-04-21 | **Closed** (2026-03-22). Covered under S8+S9+S10 filesystem hardening. |
| 13 | Medium | 24 | S10: Default file permissions | chunk_storage | CWE-732 / A01:2021 | chunk_storage.zig:190-193 | [#61](../../-/issues/61) (CONFIDENTIAL) | Explicit mode 0o600 | TBD | 2026-04-21 | **Closed** (2026-03-22). Covered under S8+S9+S10 filesystem hardening. |
| 14 | Medium | 24 | S12: CI components semver not SHA | CI/CD | CWE-829 / A08:2021 | .gitlab-ci.yml:7-20 | [#66](../../-/issues/66) | Pin to immutable SHAs | TBD | 2026-04-21 | **Closed** (2026-03-23). Added comment in .gitlab-ci.yml noting that component tags should be pinned to commit SHAs. Requires GitLab API access to resolve tag-to-SHA; semver tags left in place with documentation. |
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

## Risk Score Methodology

```
Risk Score = Impact (1-5) x Likelihood (1-5) x 4
```

| Scale | Impact | Likelihood |
|-------|--------|------------|
| 5 | RCE / privilege escalation | Pre-auth, remote, trivial |
| 4 | PII/credential leak, auth bypass | Remote, constrained |
| 3 | Data tampering, limited modification | Requires authentication |
| 2 | Information leak, limited disclosure | Rare conditions required |
| 1 | Hardening, defense-in-depth | Theoretical |
