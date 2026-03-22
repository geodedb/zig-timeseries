# Requirements

Last updated: 2026-03-21

## Functional Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| TS-REQ-001 | The library SHALL expose the core timeseries value types and store. | `src/timeseries/timeseries.zig:4`, `:13`, `:52`, `:56` |
| TS-REQ-002 | The library SHALL support batch insertion and aggregation sampling. | `src/timeseries/timeseries.zig:95`, `:134`, `:219` |
| TS-REQ-003 | The library SHALL expose chunk storage with compression and retention controls. | `src/timeseries/chunk_storage.zig:6`, `:167`, `:214`, `:282`, `:313` |
| TS-REQ-004 | The core package SHALL NOT include Geode’s GQL execution adapter in the initial extraction. | `src/timeseries/gql_functions.zig:76`, `:104`, `:129` stay in Geode |

## Packaging Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| TS-PKG-001 | The library SHALL be updated to build cleanly on the pinned Zig toolchain. | current blocker `src/timeseries/timeseries.zig:90` |
| TS-PKG-002 | Filesystem behavior for chunk storage SHALL be explicit and documented. | `src/timeseries/chunk_storage.zig:175`, `:214`, `:282` |

## Test Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| TS-TEST-001 | Port the store and aggregation unit tests. | `src/timeseries/timeseries.zig:255`, `:267`, `:279`, `:319` |
| TS-TEST-002 | Port chunk storage and retention tests. | `src/timeseries/chunk_storage.zig:348`, `:380` |
| TS-TEST-003 | Preserve end-to-end parity via Geode integration tests. | `tests/e2e_timeseries.zig:6`, `:80`, `:139`, `:188` |
| TS-TEST-004 | Preserve the current performance reference. | `tests/e2e_timeseries.zig:335` |

## Documentation Requirements

- Provide one basic store example.
- Provide one chunk-storage example.
- Document that GQL bindings remain outside the initial core extraction.

## Migration Requirements

1. Fix standalone build drift first.
2. Extract the core store and chunk-storage layers.
3. Keep `gql_functions.zig` in Geode until an optional adapter story exists.
