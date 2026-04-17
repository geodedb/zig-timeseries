// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Tests for parallel batch entry points. Each test constructs a small
//! `ThreadPool`, drives a batch call, and verifies results against
//! per-pair serial calls.

const std = @import("std");
