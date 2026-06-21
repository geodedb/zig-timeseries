# FIPS-140-3 Status — timeseries

**REQ-ID:** REQ-FIPS-EXEMPT-001 — non-security crypto/hash/RNG sites are
allow-listed (exempt) from the workspace FIPS-140-3 routing requirement per
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5.

**Mode:** This library performs only **non-security** hashing: a 128-bit
series-key hash for the time-series index hashmap. It is **exempt** from the
workspace FIPS-140-3 routing requirement (see `fips` package spec
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5). No site produces,
protects, or verifies a secret, key, credential, authentication tag, or
signature; therefore none is routed through the `crypto_backend` seam and none
links the OpenSSL FIPS provider. When a consumer builds with `-Dfips=true`,
this library is unaffected: it adds no `-Dfips` flag and changes no behavior.

## Exempt call sites

| File:Line | Primitive | Use | Why non-security (exempt) |
|-----------|-----------|-----|---------------------------|
| `src/store.zig:705,709` | `std.hash.Wyhash` | Two-seed combination into a 128-bit series-key hash (`device_id` + `metric`) | Index hashmap distribution/lookup; not a secret |

Line numbers are pre-annotation approximations.

## Scope note

Spec §6 lists a future `timeseries-storage` AES-GCM routing task. That is a
**different repo** from this `timeseries` measurement library. This
`timeseries` library has only the Wyhash sites above and is fully exempt; it
contains no AES-GCM or other security crypto.

## zlint allow-list

The Wyhash sites above carry inline `// fips-exempt: non-security — <reason>`
annotations so the `zlint` FIPS rule treats them as allow-listed rather than a
violation. Adding a new `std.crypto` / `std.hash` / `std.Random` use to this
library REQUIRES adding both the inline annotation and a row in the table
above.
