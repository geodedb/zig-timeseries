// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Import = std.Build.Module.Import;
const OptimizeMode = std.builtin.OptimizeMode;

const Deps = struct {
    thread_pool_mod: *std.Build.Module,
    /// Shared `build_options` module so every consumer module resolves to
    /// the SAME instance. Required by the otel seam (`@import("build_options")`)
    /// and shared with the named `observability` module so the file
    /// doesn't get pulled into two module trees.
    build_options_mod: *std.Build.Module,
    /// Shared `observability` named module. Imported by the public
    /// `timeseries` module + every test root that exercises the seam
    /// (so the source file stays in a single module tree).
    observability_mod: *std.Build.Module,
    /// Optional otel module. `null` when `-Dwith_otel=false`. When
    /// non-null, every consumer that wants telemetry imports it as
    /// `@import("otel")` — but call sites should generally go through
    /// the named `observability` seam instead.
    otel_mod: ?*std.Build.Module,
    /// Optional bootstrap helper module (`observability_init`). Only
    /// non-null when `-Dwith_otel=true`. The public `timeseries`
    /// module imports this so the in-process init helper is reachable
    /// from caller binaries via `timeseries.observability_init`.
    observability_init_mod: ?*std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dwith_otel: compile in otel instrumentation. OFF by default;
    // when off the otel dependency is never resolved and the seam
    // collapses to a comptime-known no-op (verified by
    // otel/scripts/verify-consumer-noop.sh).
    const with_otel = b.option(
        bool,
        "with_otel",
        "Compile in otel instrumentation (off by default; zero overhead when off)",
    ) orelse false;

    const deps = loadDeps(b, target, optimize, with_otel);

    // Main library module (for Zig consumers).
    const module = b.addModule("timeseries", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "thread_pool", .module = deps.thread_pool_mod },
            .{ .name = "observability", .module = deps.observability_mod },
            .{ .name = "build_options", .module = deps.build_options_mod },
        }),
    });
    if (deps.observability_init_mod) |init_mod| {
        module.addImport("observability_init", init_mod);
    }
    if (deps.otel_mod) |otel_mod| {
        module.addImport("otel", otel_mod);
    }

    // Shared library for C ABI consumers (Go CGO, Python ctypes, etc.).
    // The C ABI surface does NOT depend on the observability seam — it
    // intentionally stays a thin FFI wrapper. Spans live behind the
    // Zig-only `timeseries` module so binary consumers (Go, Python) are
    // unaffected by `-Dwith_otel`.
    const shared_lib = b.addLibrary(.{
        .name = "ai_ts",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(shared_lib);

    // Static library for C ABI consumers.
    const static_lib = b.addLibrary(.{
        .name = "ai_ts",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(static_lib);

    // Install the C header.
    b.installFile("src/ts_abi.h", "include/ts_abi.h");

    // Unit tests (run tests defined in all source modules).
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "thread_pool", .module = deps.thread_pool_mod },
                .{ .name = "observability", .module = deps.observability_mod },
                .{ .name = "build_options", .module = deps.build_options_mod },
            }),
        }),
    });
    if (deps.observability_init_mod) |init_mod| {
        unit_tests.root_module.addImport("observability_init", init_mod);
    }
    if (deps.otel_mod) |otel_mod| {
        unit_tests.root_module.addImport("otel", otel_mod);
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Observability seam tests — see addObservabilityTests below.
    addObservabilityTests(b, target, optimize, module, deps, test_step);

    // Integration tests (separate test file with module import).
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "timeseries", .module = module },
                .{ .name = "thread_pool", .module = deps.thread_pool_mod },
            }),
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    // Fuzz / property-based tests (separate test file with module import).
    const fuzz_step = b.step("fuzz", "Run fuzz and property-based tests");
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "timeseries", .module = module },
                .{ .name = "thread_pool", .module = deps.thread_pool_mod },
            }),
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    fuzz_step.dependOn(&run_fuzz_tests.step);

    // Benchmark executable (compiled with ReleaseFast for accurate timing).
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = allocImports(b, &.{
                .{ .name = "timeseries", .module = module },
                .{ .name = "thread_pool", .module = deps.thread_pool_mod },
            }),
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Check step for IDE integration (fast syntax validation).
    const check_step = b.step("check", "Check for compilation errors");
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "thread_pool", .module = deps.thread_pool_mod },
                .{ .name = "observability", .module = deps.observability_mod },
                .{ .name = "build_options", .module = deps.build_options_mod },
            }),
        }),
    });
    if (deps.observability_init_mod) |init_mod| {
        check.root_module.addImport("observability_init", init_mod);
    }
    if (deps.otel_mod) |otel_mod| {
        check.root_module.addImport("otel", otel_mod);
    }
    check_step.dependOn(&check.step);
}

fn loadDeps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    with_otel: bool,
) Deps {
    const thread_pool_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });

    // Materialize ONE shared `build_options` module. Each consumer module
    // imports the SAME module instance via `addImport` to avoid Zig 0.16's
    // "file exists in modules X and X0" error when two independent
    // `addOptions` modules end up sharing a transitive file path.
    const build_options = b.addOptions();
    build_options.addOption(bool, "with_otel", with_otel);
    build_options.addOption([]const u8, "package_name", "timeseries");
    const build_options_mod = build_options.createModule();

    // Observability seam (otel). Declared as a SHARED NAMED MODULE so
    // every consumer (lib, tests, example, benchmarks, plus the seam
    // tests) resolves to the same source file via
    // `@import("observability")`. Using relative
    // `@import("observability.zig")` from each module would trip Zig's
    // "file exists in modules X and Y" error because the file would be
    // pulled into multiple module trees. The seam's `enabled` flag
    // tracks `build_options.with_otel`; when off, every helper compiles
    // to a comptime-known no-op and the otel dependency is never
    // resolved. The optional `otel` import is wired below inside the
    // `if (with_otel)` block.
    const observability_mod = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "build_options", .module = build_options_mod },
        }),
    });

    // Gated otel dependency. The `lazy = true` entry in build.zig.zon
    // means Zig only fetches the package when this branch executes;
    // with the flag off the dependency is never resolved and the
    // produced artifacts contain zero otel symbols (verified by
    // otel/scripts/verify-consumer-noop.sh).
    var otel_mod: ?*std.Build.Module = null;
    var observability_init_mod: ?*std.Build.Module = null;
    if (with_otel) {
        if (b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        })) |otel_dep| {
            const m = otel_dep.module("otel");
            otel_mod = m;
            // The seam itself imports `otel` when enabled.
            observability_mod.addImport("otel", m);

            // Bootstrap helper. Only registered when `-Dwith_otel=true`
            // so the disabled build never compiles otel-touching code.
            // Gated from root.zig via
            // `if (observability.enabled) @import("observability_init")`.
            observability_init_mod = b.addModule("observability_init", .{
                .root_source_file = b.path("src/observability_init.zig"),
                .target = target,
                .optimize = optimize,
                .imports = allocImports(b, &.{
                    .{ .name = "otel", .module = m },
                    .{ .name = "observability", .module = observability_mod },
                }),
            });
        }
    }

    return .{
        .thread_pool_mod = thread_pool_dep.module("thread_pool"),
        .build_options_mod = build_options_mod,
        .observability_mod = observability_mod,
        .otel_mod = otel_mod,
        .observability_init_mod = observability_init_mod,
    };
}

fn allocImports(b: *std.Build, imports: []const Import) []Import {
    return b.allocator.dupe(Import, imports) catch @panic("out of memory");
}

// ============================================================================
// Observability seam tests
// ============================================================================
//
// Two test targets:
//
//   - `observability_disabled_test.zig` runs under BOTH flag values. Each
//     test inside it is skip-guarded via
//     `if (timeseries.observability.enabled) return error.SkipZigTest;`
//     so the disabled-mode invariants only fire when the flag is off.
//
//   - `observability_enabled_test.zig` is registered under both flag
//     values too, but every test inside it skips when the flag is off.
//     The `otel` import is wired only when `with_otel = true`; the
//     stub branch in the test file (`const otel = if (build_options.with_otel) ...`)
//     ensures the file still compiles cleanly under the disabled build.
fn addObservabilityTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    timeseries_mod: *std.Build.Module,
    deps: Deps,
    test_step: *std.Build.Step,
) void {
    // Disabled-mode no-op tests. Verifies `build_options.with_otel == false`
    // is the default and that the seam's public surface returns a
    // comptime-known no-op when otel is off.
    const disabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_disabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "timeseries", .module = timeseries_mod },
                .{ .name = "build_options", .module = deps.build_options_mod },
            }),
        }),
    });
    const run_disabled_tests = b.addRunArtifact(disabled_tests);
    test_step.dependOn(&run_disabled_tests.step);

    // Enabled-mode smoke test. Skips under -Dwith_otel=false; under
    // -Dwith_otel=true it installs an in-memory recorder, drives one
    // operation span through the seam, and asserts the recorder
    // captured it.
    const enabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_enabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "timeseries", .module = timeseries_mod },
                .{ .name = "build_options", .module = deps.build_options_mod },
            }),
        }),
    });
    if (deps.otel_mod) |m| enabled_tests.root_module.addImport("otel", m);
    const run_enabled_tests = b.addRunArtifact(enabled_tests);
    test_step.dependOn(&run_enabled_tests.step);
}
