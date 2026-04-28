//! Verifies one timeseries operation span lands in an in-memory recorder
//! when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.
//!
//! NOTE: this file is finalised in Chunk C of the otel rollout
//! sequence. It is registered under both flag values by `build.zig`;
//! every test inside it skips when the flag is off, so the file
//! compiles cleanly under either build.

const std = @import("std");
const build_options = @import("build_options");
const timeseries = @import("timeseries");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "stub: enabled smoke test placeholder" {
    if (!timeseries.observability.enabled) return error.SkipZigTest;
    // The full smoke test is finalised in Chunk C. This stub keeps the
    // file compilable under both flag values during Chunk A.
    return error.SkipZigTest;
}
