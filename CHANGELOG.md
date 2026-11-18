# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial project structure
- Core library implementation
- Unit and integration tests
- CI/CD pipeline
- Documentation

## [0.1.20] - 2026-11-17

### Changed

- otel v0.1.28 -> v0.1.30, whose tree (slog, json, config, yaml, metrics, tls, grpc-zig v0.1.16) is on thread-pool v0.2.11, so this library and its consumers resolve a single otel and thread-pool (SONNY-6630).

## [0.1.14] - 2026-09-15

### Changed

- Converge grpc_zig v0.1.10 (GAP-0838 diamond sync).

## [0.1.13] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.1.12] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.1.0] - YYYY-MM-DD

### Added

- Initial release
- Basic functionality
- Documentation and examples

[Unreleased]: https://gitlab.com/devnw/zig/timeseries/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/timeseries/-/releases/v0.1.0
