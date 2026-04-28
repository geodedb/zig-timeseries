//! Verifies the no-op invariant when -Dwith_otel=false (the default).
//!
//! timeseries publishes its public surface as the "timeseries" module
//! rooted at src/root.zig. The seam is exposed as
//! `timeseries.observability` so this test can drive the disabled-mode
//! invariants through the public root.

const std = @import("std");
const timeseries = @import("timeseries");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    // The "default" assertion only holds for the disabled build. When
    // the operator forces -Dwith_otel=true, this test runs against the
    // enabled module and must skip rather than misreport the default.
    if (build_options.with_otel) return error.SkipZigTest;
    try std.testing.expectEqual(false, build_options.with_otel);
}

test "observability.enabled tracks build_options.with_otel" {
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, timeseries.observability.enabled);
}

test "client/server seams are no-ops when otel disabled" {
    if (timeseries.observability.enabled) return error.SkipZigTest;
    var span = timeseries.observability.startClientSpan(.{
        .method = "GET",
        .route = "/",
        .url = "https://example.test/",
    });
    timeseries.observability.endClientSpan(span, 200);
    // Belt-and-suspenders: the seam's `endClientSpan` already covers
    // the lifecycle; this line just verifies the no-op fallback's
    // signature matches the real API's `Span.end(?u64) void`.
    span.end(null);

    var sspan = timeseries.observability.startServerSpan(.{
        .method = "GET",
        .route = "/",
        .url = "/",
    });
    timeseries.observability.endServerSpan(sspan, 200);
    sspan.end(null);
}

test "timeseries operation span helper is a no-op when otel disabled" {
    if (timeseries.observability.enabled) return error.SkipZigTest;
    var span = timeseries.observability.startTimeseriesSpan("insert", "cpu.usage");
    timeseries.observability.endTimeseriesSpan(span, true, 0);
    span.end(null);
}
