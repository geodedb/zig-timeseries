# Parallel Batch API

Status: live (added 2026-04-16 — see `docs/superpowers/plans/2026-04-16-timeseries-parallel-api.md`).

## Scope

The `parallel` submodule exposes batch entry points for the timeseries
algorithms that have clean embarrassingly-parallel structure:

- `parallelBatchDTW` — constrained / derivative / open-end / shape / soft
- `parallelBatchLbKeogh` — O(n·w) lower-bound prefilter
- `parallelBatchDistances` — SBD / LCSS / EDR / ERP
- `parallelMpDistAbJoin` — AB-join MP-distance, row-parallel

Each entry point takes a caller-provided `*tp.ThreadPool`; passing `null`
runs serially in the caller thread. Per-pair errors are reported in a
`BatchResult(T)` union — the call itself returns only setup-allocation
errors (`error.OutOfMemory`).

Chunk size is caller-tunable via `BatchOptions.chunk_size`; the default
(`parallel.default_chunk_size`) is benchmarked in `tests/bench.zig`.

## Allocator thread-safety contract (SEC-5 / PERF-2)

`crossCorrelate`/`sbd` and the batch entry points above take a
caller-provided `std.mem.Allocator`. When you pass a non-null
`*tp.ThreadPool` to `parallelBatchDistances(.{ .metric = .sbd })` or to
`parallelBatchCrossCorrelate`, worker threads allocate and free FFT
scratch buffers from that allocator **concurrently** (each dispatched
chunk does its own alloc/free independently of the others).

**The allocator you pass MUST be thread-safe whenever `pool` is
non-null.** Safe choices include `std.heap.page_allocator`, or a
`GeneralPurposeAllocator`/`DebugAllocator` constructed with
`.thread_safe = true`. Passing a non-thread-safe allocator (a bare
arena, or a GPA/DebugAllocator without `.thread_safe = true`) together
with a non-null pool is a data race — concurrent mutation of the
allocator's internal state from multiple threads with no synchronization.

This constraint does not apply when `pool == null`: all work then runs
serially on the caller's thread.

## Length-mismatch handling

`parallelBatchDTW`, `parallelBatchLbKeogh`, `parallelBatchDistances`, and
`parallelBatchCrossCorrelate` all require their `out_*` slice to be the
same length as `candidates`. A mismatch returns `error.LengthMismatch`
(not a panic/assert), so callers can detect and handle it.

## Out-of-scope algorithms

Several algorithms are **intentionally not** parallelized in this iteration:

1. **`matrixProfile` STOMP self-join** — the incremental dot-product
   update (`qt[j] = qt_prev[j-1] - a[i-1]*a[j-1] + a[i+w-1]*a[j+w-1]`)
   at `src/matrix_profile.zig` creates a carried data dependency across
   rows. Parallelizing requires algorithm redesign (SCRIMP++ random-row
   sampling, or diagonal-block STAMP with per-diagonal dot products).
   Tracked separately.

2. **`softDTW` row-level parallelism** — the 2-row rolling buffer
   couples `curr_row[j]` to `curr_row[j-1]` within the same row, and
   both rows to `prev_row`. Wavefront (anti-diagonal) traversal would
   expose parallelism but complicates the min-for-numerical-stability
   trick. Kept serial.

3. **Per-call internal DTW parallelism** — same DP row dependency as
   STOMP. The batch API above is the recommended path: callers with
   one-to-many similarity search get full parallelism; callers with
   single pairs pay nothing.

4. **TWED (time warp edit distance)** — requires per-timestep time
   vectors (`a_times`, `b_times`) that don't fit the uniform
   `(query, candidates[])` batch shape. Use `distances.twed` directly
   for single-pair TWED. The `DistanceMetric.twed` variant is kept
   for API stability but returns `TsError.InvalidInput` when selected
   via `parallelBatchDistances`.

## C ABI

No parallel entry points are exposed via `src/abi.zig`.

Reason: Go and Python consumers already have native concurrency
primitives (goroutines, `concurrent.futures.ThreadPoolExecutor`,
`asyncio`). Having the Zig library dispatch its own pool in addition
would put two parallel runtimes in contention inside the same process.
FFI callers should fan out per-pair calls on their own runtime.

Zig-native callers who want the batch API import the module directly.
