# GAP Analysis

Last updated: 2026-03-21

Repository status: bootstrapped from `../zig-template`; no Geode code has been moved yet.

## Goal

Extract Geode’s reusable timeseries store and chunk-storage core into a standalone library, while leaving GQL-facing query integration in Geode.

## Intended Boundary

Move into this library:

| Geode source | Why it belongs here |
|---|---|
| `src/timeseries/timeseries.zig:4`, `:13`, `:52`, `:56`, `:95`, `:134`, `:219` | Core point/series/store and aggregation logic |
| `src/timeseries/chunk_storage.zig:6`, `:167`, `:175`, `:214`, `:256`, `:282`, `:313` | Chunk compression, persistence, range query, retention, and stats |

Keep in Geode:

| Geode source | Why it stays |
|---|---|
| `src/timeseries/gql_functions.zig:76`, `:104`, `:129` | GQL-facing execution adapter over the timeseries store |

## Concrete Gaps

| Gap | Evidence | Impact | Required fix |
|---|---|---|---|
| Standalone build fails on Zig API drift | `src/timeseries/timeseries.zig:90` currently trips the reviewed Zig 0.15.2 build | Blocks immediate extraction | Update the ArrayList initialization/usage to the pinned Zig API |
| GQL integration is mixed in the same subsystem tree | `src/timeseries/gql_functions.zig:76` | Risks over-extraction | Keep query-language bindings local to Geode |
| Chunk storage is filesystem-backed | `src/timeseries/chunk_storage.zig:175`, `:214`, `:282` | Requires explicit packaging around filesystem assumptions | Keep FS dependencies explicit in this repo |

## Tests And Benchmarks To Carry Over

| Geode test / benchmark | Coverage provided |
|---|---|
| `src/timeseries/timeseries.zig:255`, `:267`, `:279`, `:319` | Core store and aggregation unit tests |
| `src/timeseries/chunk_storage.zig:348`, `:380` | Chunk compression and retention tests |
| `tests/e2e_timeseries.zig:6`, `:80`, `:139`, `:188` | End-to-end store, chunk storage, retention, and GQL integration flows |
| `tests/e2e_timeseries.zig:335` | Performance benchmark reference |
| `src/timeseries/gql_functions.zig:339`, `:370` | Keep in Geode or port later if an optional query adapter is added |

## Proposed Public API

Initial public surface should include:

- `Point`
- `SeriesKey`
- `Store`
- `insertMany`
- `sampleBy`
- `timeBucketAvg`
- `ChunkConfig`
- `ChunkStorage`
- `writePoints`
- `queryRange`
- `runRetention`

## Extraction Plan

1. Fix the standalone Zig drift in `timeseries.zig`.
2. Move the store and chunk-storage modules into this repo.
3. Port core unit tests and the end-to-end storage tests.
4. Keep GQL function bindings in Geode initially.
5. Rewire Geode’s GQL integration to import this repo.

## Acceptance Criteria

- This repo builds and tests standalone.
- Geode keeps only the GQL-facing adapter locally.
- The performance reference in `tests/e2e_timeseries.zig:335` remains within an acceptable delta after extraction.
