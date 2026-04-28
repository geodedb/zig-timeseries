# timeseries

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A Zig library for timeseries

## Features

- **Zero Dependencies**: Pure Zig standard library only
- **Memory Safe**: Proper allocation patterns with no leaks
- **Cross-Platform**: Linux, macOS, Windows support
- **Well Tested**: Comprehensive unit and integration tests

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .timeseries = .{
        .url = "https://gitlab.com/devnw/zig/timeseries/-/archive/v0.1.0/timeseries-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const timeseries = b.dependency("timeseries", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("timeseries", timeseries.module("timeseries"));
```

## Quick Start

```zig
const std = @import("std");
const timeseries = @import("timeseries");

pub fn main() !void {
    try timeseries.init(.{
        .debug = true,
    });
}
```

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
make build

# Run tests
make test

# Quick development iteration
make dev

# Full CI pipeline
make ci
```

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Observability

timeseries ships an opt-in OpenTelemetry seam. Build with
`-Dwith_otel=true` to compile in instrumentation; the default
(`-Dwith_otel=false`) leaves every span site as a comptime no-op so
the optimizer eliminates the entry/exit calls and the `otel`
dependency is never fetched.

Each public timeseries operation emits exactly one span per call,
named `ts.{operation}` (e.g. `ts.insert`, `ts.query`,
`ts.downsample`, `ts.retention`, `ts.compact`) with the
OpenTelemetry `db.*` semantic-convention attributes plus a
ts-specific metric tag:

- `db.system = "timeseries"`
- `db.operation = <method>` (e.g. `insert`, `query`, `downsample`)
- `ts.metric = <metric_name>` (the metric NAME, e.g. `"cpu.usage"`;
  metric VALUES are intentionally never recorded)
- `ts.points = <count>` (batch size for inserts; row count for
  queries/downsamples; total flushed for compact)

```bash
zig build test                  # default: -Dwith_otel=false (no-op)
zig build test -Dwith_otel=true # otel compiled in, spans emitted
```

When enabled, the consumer's process bootstrap calls
`timeseries.observability_init.Otel.init(allocator, "service-name")`
and parks the returned value at a stable address (a `var` in `main`
or a heap allocation), then calls `installGlobals(&that_value)` so
the seam can publish its tracer pointer. Span emission is non-fatal:
every emit is `catch {}`-discarded so a failed exporter cannot
propagate into timeseries operations.

The C ABI surface (`ai_ts` shared/static library) is unaffected by
`-Dwith_otel` — Go (CGO) and Python (ctypes) consumers don't need to
opt in to the seam.

For the full integration recipe and template files, see
`otel/docs/integration/RECIPE.md` in the otel repo.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
