//! Verifies one timeseries operation span lands in an in-memory recorder
//! when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from template — we exercise the seam directly
//! (`startTimeseriesSpan` -> `endTimeseriesSpan`) rather than driving a
//! real `Store.insertMany` call. The store path requires a temp data
//! directory + chunk-storage init; the seam's behaviour is identical
//! regardless of who emits the span. The smoke test asserts the
//! recorder captured one span with the expected name shape and the
//! `db.system` / `db.operation` / `ts.metric` semantic-convention
//! attributes.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const timeseries = @import("timeseries");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one ts.* operation span recorded when otel enabled" {
    if (!timeseries.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "timeseries-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "timeseries-test" });
    timeseries.observability.global.tracer = &tracer;
    defer timeseries.observability.global.tracer = null;

    // Drive the timeseries-shaped span through the public seam exactly
    // the way the wired-in operations do (insertMany -> ts.insert).
    const span = timeseries.observability.startTimeseriesSpan("insert", "cpu.usage");
    timeseries.observability.endTimeseriesSpan(span, true, 100);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    // Verify span name shape: "ts.{operation}".
    const recorded = recorder.spans.items[0];
    try std.testing.expectEqualStrings("ts.insert", recorded.name);

    // Verify the timeseries semantic-convention attributes landed on
    // the span. The in-memory recorder stores attributes as `[]KV`
    // (string-stringified key/value pairs) — see
    // otel/src/exporters/in_memory.zig:30.
    var found_system: ?[]const u8 = null;
    var found_op: ?[]const u8 = null;
    var found_metric: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "db.system")) {
            found_system = kv.value;
        } else if (std.mem.eql(u8, kv.key, "db.operation")) {
            found_op = kv.value;
        } else if (std.mem.eql(u8, kv.key, "ts.metric")) {
            found_metric = kv.value;
        }
    }
    const system_value = found_system orelse return error.MissingDbSystemAttribute;
    try std.testing.expectEqualStrings("timeseries", system_value);
    const op_value = found_op orelse return error.MissingDbOperationAttribute;
    try std.testing.expectEqualStrings("insert", op_value);
    const metric_value = found_metric orelse return error.MissingTsMetricAttribute;
    try std.testing.expectEqualStrings("cpu.usage", metric_value);
}
