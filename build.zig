// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const thread_pool_dep = b.dependency("thread_pool", .{
        .target = target,
        .optimize = optimize,
    });
    const thread_pool_module = thread_pool_dep.module("thread_pool");

    // Main library module (for Zig consumers).
    const module = b.addModule("timeseries", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "thread_pool", .module = thread_pool_module },
        },
    });

    // Shared library for C ABI consumers (Go CGO, Python ctypes, etc.).
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
            .imports = &.{
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate test file with module import).
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "timeseries", .module = module },
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
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
            .imports = &.{
                .{ .name = "timeseries", .module = module },
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
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
            .imports = &.{
                .{ .name = "timeseries", .module = module },
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
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
            .imports = &.{
                .{ .name = "thread_pool", .module = thread_pool_module },
            },
        }),
    });
    check_step.dependOn(&check.step);
}
