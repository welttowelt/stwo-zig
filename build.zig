const std = @import("std");
const metal_core_aot = @import("build_support/metal_core_aot.zig");
const metal_products = @import("build_support/metal_products.zig");
const verification_products = @import("build_support/verification_products.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optimize_arg = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
    const zig_optimize_arg = b.fmt("-O{s}", .{@tagName(optimize)});

    // Library module (importable by downstream packages).
    const stwo_module = b.addModule("stwo", .{
        .root_source_file = b.path("src/stwo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const interop_cli_module = b.createModule(.{
        .root_source_file = b.path("src/tools/interop/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    interop_cli_module.addImport("stwo", stwo_module);
    const interop_cli = b.addExecutable(.{
        .name = "interop_cli",
        .root_module = interop_cli_module,
    });
    interop_cli.linkLibC();
    const install_interop_cli = b.addInstallArtifact(interop_cli, .{});
    const interop_cli_build_step = b.step("interop-cli", "Build the proof interoperability CLI");
    interop_cli_build_step.dependOn(&install_interop_cli.step);

    const native_proof_runner_module = b.createModule(.{
        .root_source_file = b.path("src/bench/native_proof/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_proof_runner_module.addImport("stwo", stwo_module);

    // Unit tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/stwo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_module,
    });
    if (target.result.os.tag == .macos) metal_products.linkRuntime(b, tests);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const shader_manifest_module = b.createModule(.{
        .root_source_file = b.path("src/backends/metal/shader_manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_core_aot.addProducts(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .shader_manifest_module = shader_manifest_module,
        .test_step = test_step,
    });

    const native_proof_runner_test_module = b.createModule(.{
        .root_source_file = b.path("src/bench/native_proof/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_proof_runner_test_module.addImport("stwo", stwo_module);
    const native_proof_runner_tests = b.addTest(.{ .root_module = native_proof_runner_test_module });
    const run_native_proof_runner_tests = b.addRunArtifact(native_proof_runner_tests);
    test_step.dependOn(&run_native_proof_runner_tests.step);

    const pcs_test_module = b.createModule(.{
        .root_source_file = b.path("src/stwo_deep.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pcs_tests = b.addTest(.{
        .root_module = pcs_test_module,
        .filters = &.{"prover pcs:"},
    });
    const run_pcs_tests = b.addRunArtifact(pcs_tests);
    test_step.dependOn(&run_pcs_tests.step);

    const cross_module_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cross_module_test_options = b.addOptions();
    cross_module_test_options.addOption(bool, "riscv_only", false);
    cross_module_test_options.addOption(bool, "metal_only", false);
    cross_module_test_module.addOptions("test_options", cross_module_test_options);
    const cross_module_tests = b.addTest(.{ .root_module = cross_module_test_module });
    if (target.result.os.tag == .macos) metal_products.linkRuntime(b, cross_module_tests);
    const run_cross_module_tests = b.addRunArtifact(cross_module_tests);
    test_step.dependOn(&run_cross_module_tests.step);

    inline for ([_][]const u8{
        "proof_layout.zig",
        "schedule_addressing.zig",
        "schedule_coverage.zig",
        "transcript_fixture.zig",
    }) |filename| {
        const arena_schedule_test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/tools/metal_arena_plan/{s}", .{filename})),
            .target = target,
            .optimize = optimize,
        });
        arena_schedule_test_module.addImport("stwo", stwo_module);
        const arena_schedule_tests = b.addTest(.{ .root_module = arena_schedule_test_module });
        const run_arena_schedule_tests = b.addRunArtifact(arena_schedule_tests);
        test_step.dependOn(&run_arena_schedule_tests.step);
    }

    const metal_session_protocol_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_session/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const metal_session_protocol_tests = b.addTest(.{ .root_module = metal_session_protocol_test_module });
    const run_metal_session_protocol_tests = b.addRunArtifact(metal_session_protocol_tests);
    test_step.dependOn(&run_metal_session_protocol_tests.step);

    const cairo_input_module = b.createModule(.{
        .root_source_file = b.path("src/tools/cairo/input_inspector.zig"),
        .target = target,
        .optimize = optimize,
    });
    cairo_input_module.addImport("stwo", stwo_module);
    const cairo_input_cli = b.addExecutable(.{
        .name = "cairo-input",
        .root_module = cairo_input_module,
    });
    const install_cairo_input_cli = b.addInstallArtifact(cairo_input_cli, .{});
    const cairo_input_step = b.step("cairo-input", "Build adapted Cairo input inspector");
    cairo_input_step.dependOn(&install_cairo_input_cli.step);

    // RISC-V trace dumper CLI for cross-verification
    const riscv_trace_module = b.createModule(.{
        .root_source_file = b.path("src/riscv_trace_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const riscv_trace_cli = b.addExecutable(.{
        .name = "riscv-trace-dump",
        .root_module = riscv_trace_module,
    });
    b.installArtifact(riscv_trace_cli);
    const riscv_trace_step = b.step("riscv-trace-dump", "Build RISC-V trace dumper CLI");
    riscv_trace_step.dependOn(&riscv_trace_cli.step);

    // RISC-V runner tests use the src-wide test root for nested source access.
    const riscv_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const riscv_test_options = b.addOptions();
    riscv_test_options.addOption(bool, "riscv_only", true);
    riscv_test_options.addOption(bool, "metal_only", false);
    riscv_test_module.addOptions("test_options", riscv_test_options);
    const riscv_tests = b.addTest(.{
        .root_module = riscv_test_module,
    });
    const run_riscv_tests = b.addRunArtifact(riscv_tests);
    const riscv_test_step = b.step("test-riscv", "Run RISC-V runner tests (trace_dump)");
    riscv_test_step.dependOn(&run_riscv_tests.step);

    // RISC-V prover tests (prove + verify roundtrips).
    const riscv_prover_test_module = b.createModule(.{
        .root_source_file = b.path("src/riscv_prover_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const riscv_prover_tests = b.addTest(.{
        .root_module = riscv_prover_test_module,
    });
    const run_riscv_prover_tests = b.addRunArtifact(riscv_prover_tests);
    const riscv_prover_test_step = b.step("test-riscv-prover", "Run RISC-V prover tests (prove+verify)");
    riscv_prover_test_step.dependOn(&run_riscv_prover_tests.step);

    // RISC-V benchmark CLI (execute, prove, verify, hosted mode)
    const riscv_bench_module = b.createModule(.{
        .root_source_file = b.path("src/riscv_bench_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const riscv_bench_cli = b.addExecutable(.{
        .name = "riscv-bench",
        .root_module = riscv_bench_module,
    });
    const install_riscv_bench = b.addInstallArtifact(riscv_bench_cli, .{});
    b.getInstallStep().dependOn(&install_riscv_bench.step);
    const riscv_bench_step = b.step("riscv-bench", "Build RISC-V benchmark CLI");
    riscv_bench_step.dependOn(&install_riscv_bench.step);

    const native_proof_cpu_module = b.createModule(.{
        .root_source_file = b.path("src/tools/native_proof_bench/cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_proof_cpu_module.addImport("stwo", stwo_module);
    native_proof_cpu_module.addImport("native_proof_runner", native_proof_runner_module);
    const native_proof_cpu = b.addExecutable(.{
        .name = "native-proof-bench-cpu",
        .root_module = native_proof_cpu_module,
    });
    const install_native_proof_cpu = b.addInstallArtifact(native_proof_cpu, .{});
    const native_proof_cpu_step = b.step(
        "native-proof-bench-cpu",
        "Build the machine-readable native CPU full-proof benchmark with SIMD hot paths",
    );
    native_proof_cpu_step.dependOn(&install_native_proof_cpu.step);

    // Metal products are platform-specific; their internal graph lives with the backend.
    if (target.result.os.tag == .macos) {
        metal_products.addProducts(.{
            .b = b,
            .target = target,
            .optimize = optimize,
            .stwo_module = stwo_module,
            .native_proof_runner_module = native_proof_runner_module,
            .test_step = test_step,
        });
    }

    // -----------------------------------------------------------------
    // CUDA GPU backend (opt-in via -Dcuda=true)
    // -----------------------------------------------------------------
    const cuda_enabled = b.option(bool, "cuda", "Enable CUDA GPU backend") orelse false;
    const cuda_lib_path = b.option([]const u8, "cuda-lib-path", "Path to libstwo_cuda.a") orelse "/Users/theodorepender/Coding/gpu-acc/stwo-cuda/build/lib";
    const cuda_runtime_path = b.option([]const u8, "cuda-runtime-path", "Path to CUDA runtime libraries (libcudart)") orelse "/usr/local/cuda/lib64";

    if (cuda_enabled) {
        // CUDA-linked test binary: runs the same test suite but with the
        // real CUDA libraries available at link time.
        const cuda_test_module = b.createModule(.{
            .root_source_file = b.path("src/stwo.zig"),
            .target = target,
            .optimize = optimize,
        });
        const cuda_tests = b.addTest(.{
            .root_module = cuda_test_module,
        });
        cuda_tests.addLibraryPath(.{ .cwd_relative = cuda_lib_path });
        cuda_tests.addLibraryPath(.{ .cwd_relative = cuda_runtime_path });
        cuda_tests.linkSystemLibrary("stwo_cuda");
        cuda_tests.linkSystemLibrary("cudart");
        cuda_tests.linkSystemLibrary("stdc++");

        const run_cuda_tests = b.addRunArtifact(cuda_tests);
        const cuda_test_step = b.step("cuda-test", "Run unit tests with CUDA backend linked");
        cuda_test_step.dependOn(&run_cuda_tests.step);
    }

    verification_products.addProducts(.{
        .b = b,
        .zig_optimize_arg = zig_optimize_arg,
    });
    // Formatting gate.
    const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "tools" });
    const fmt_step = b.step("fmt", "Check formatting (zig fmt --check)");
    fmt_step.dependOn(&fmt_cmd.step);

    // API parity ledger validation.
    const api_parity_cmd = b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" });
    const api_parity_step = b.step("api-parity", "Validate API parity ledger coverage");
    api_parity_step.dependOn(&api_parity_cmd.step);

    // Scope-aware Rust oracle pin ledger validation.
    const upstream_pins_cmd = b.addSystemCommand(&.{ "python3", "scripts/check_upstream_pins.py" });
    const upstream_pins_step = b.step(
        "upstream-pins",
        "Validate Native and Cairo pin carriers against the upstream ledger",
    );
    upstream_pins_step.dependOn(&upstream_pins_cmd.step);

    // Source ownership, dependency direction, and file-size ratchet.
    const source_conformance_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/check_source_conformance.py",
    });
    const source_conformance_step = b.step(
        "source-conformance",
        "Reject new source layout, dependency direction, and file-size violations",
    );
    source_conformance_step.dependOn(&source_conformance_cmd.step);

    // Upstream surface audit for rust_path validity at pinned commit.
    const upstream_surface_cmd = b.addSystemCommand(&.{ "python3", "scripts/check_upstream_surface.py" });
    const upstream_surface_step = b.step(
        "upstream-surface",
        "Validate API parity rust_path entries against pinned upstream commit",
    );
    upstream_surface_step.dependOn(&upstream_surface_cmd.step);

    // Capture current roadmap baseline snapshot for section-15 closure tracking.
    const roadmap_baseline_cmd = b.addSystemCommand(&.{ "python3", "scripts/roadmap_baseline.py" });
    const roadmap_baseline_step = b.step(
        "roadmap-baseline",
        "Capture roadmap baseline snapshot (CONFORMANCE section 15 + report hashes)",
    );
    roadmap_baseline_step.dependOn(&roadmap_baseline_cmd.step);

    // Deterministic release gate sequence:
    // fmt -> upstream-pins -> source-conformance -> test -> api-parity -> deep-gate -> vectors -> interop -> bench-smoke -> profile-smoke
    const rg_fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "tools" });
    const rg_upstream_pins = b.addSystemCommand(&.{ "python3", "scripts/check_upstream_pins.py" });
    rg_upstream_pins.step.dependOn(&rg_fmt.step);
    const rg_source_conformance = b.addSystemCommand(&.{
        "python3",
        "scripts/check_source_conformance.py",
    });
    rg_source_conformance.step.dependOn(&rg_upstream_pins.step);
    const rg_test = b.addSystemCommand(&.{ "zig", "build", "test", optimize_arg });
    rg_test.step.dependOn(&rg_source_conformance.step);
    const rg_api_parity = b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" });
    rg_api_parity.step.dependOn(&rg_test.step);
    const rg_deep = b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig", zig_optimize_arg });
    rg_deep.step.dependOn(&rg_api_parity.step);
    const rg_vectors_fields = b.addSystemCommand(&.{ "python3", "scripts/parity_fields.py", "--skip-zig" });
    rg_vectors_fields.step.dependOn(&rg_deep.step);
    const rg_vectors_constraint = b.addSystemCommand(&.{
        "python3",
        "scripts/parity_constraint_expr.py",
        "--skip-zig",
    });
    rg_vectors_constraint.step.dependOn(&rg_vectors_fields.step);
    const rg_vectors_air_derive = b.addSystemCommand(&.{
        "python3",
        "scripts/parity_air_derive.py",
        "--skip-zig",
    });
    rg_vectors_air_derive.step.dependOn(&rg_vectors_constraint.step);
    const rg_interop = b.addSystemCommand(&.{ "python3", "scripts/e2e_interop.py" });
    rg_interop.step.dependOn(&rg_vectors_air_derive.step);
    const rg_bench = b.addSystemCommand(&.{ "python3", "scripts/benchmark_smoke.py" });
    rg_bench.step.dependOn(&rg_interop.step);
    const rg_profile = b.addSystemCommand(&.{ "python3", "scripts/profile_smoke.py" });
    rg_profile.step.dependOn(&rg_bench.step);

    const release_gate_step = b.step(
        "release-gate",
        "Run release gate sequence (fmt -> upstream-pins -> source-conformance -> test -> api-parity -> deep-gate -> vectors -> interop -> bench-smoke -> profile-smoke)",
    );
    release_gate_step.dependOn(&rg_profile.step);

    // Strict release gate sequence:
    // fmt -> upstream-pins -> source-conformance -> test -> api-parity -> deep-gate -> vectors -> interop -> prove-checkpoints -> bench-strict -> profile-smoke -> std-shims-smoke -> std-shims-behavior
    const rgs_fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "tools" });
    const rgs_upstream_pins = b.addSystemCommand(&.{ "python3", "scripts/check_upstream_pins.py" });
    rgs_upstream_pins.step.dependOn(&rgs_fmt.step);
    const rgs_source_conformance = b.addSystemCommand(&.{
        "python3",
        "scripts/check_source_conformance.py",
    });
    rgs_source_conformance.step.dependOn(&rgs_upstream_pins.step);
    const rgs_test = b.addSystemCommand(&.{ "zig", "build", "test", optimize_arg });
    rgs_test.step.dependOn(&rgs_source_conformance.step);
    const rgs_api_parity = b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" });
    rgs_api_parity.step.dependOn(&rgs_test.step);
    const rgs_deep = b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig", zig_optimize_arg });
    rgs_deep.step.dependOn(&rgs_api_parity.step);
    const rgs_vectors_fields = b.addSystemCommand(&.{ "python3", "scripts/parity_fields.py", "--skip-zig" });
    rgs_vectors_fields.step.dependOn(&rgs_deep.step);
    const rgs_vectors_constraint = b.addSystemCommand(&.{
        "python3",
        "scripts/parity_constraint_expr.py",
        "--skip-zig",
    });
    rgs_vectors_constraint.step.dependOn(&rgs_vectors_fields.step);
    const rgs_vectors_air_derive = b.addSystemCommand(&.{
        "python3",
        "scripts/parity_air_derive.py",
        "--skip-zig",
    });
    rgs_vectors_air_derive.step.dependOn(&rgs_vectors_constraint.step);
    const rgs_interop = b.addSystemCommand(&.{ "python3", "scripts/e2e_interop.py" });
    rgs_interop.step.dependOn(&rgs_vectors_air_derive.step);
    const rgs_prove_checkpoints = b.addSystemCommand(&.{ "python3", "scripts/prove_checkpoints.py" });
    rgs_prove_checkpoints.step.dependOn(&rgs_interop.step);
    const rgs_bench = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_smoke.py",
        "--include-medium",
        "--warmups",
        "3",
        "--repeats",
        "11",
    });
    rgs_bench.step.dependOn(&rgs_prove_checkpoints.step);
    const rgs_profile = b.addSystemCommand(&.{ "python3", "scripts/profile_smoke.py" });
    rgs_profile.step.dependOn(&rgs_bench.step);
    const rgs_std_shims = b.addSystemCommand(&.{
        "zig",
        "build-lib",
        "src/std_shims_freestanding.zig",
        "-target",
        "wasm32-freestanding",
        "-O",
        "ReleaseSmall",
        "-femit-bin=/tmp/stwo-zig-std-shims-verifier.wasm",
    });
    rgs_std_shims.step.dependOn(&rgs_profile.step);
    const rgs_std_shims_behavior = b.addSystemCommand(&.{ "python3", "scripts/std_shims_behavior.py" });
    rgs_std_shims_behavior.step.dependOn(&rgs_std_shims.step);
    const rgs_evidence = b.addSystemCommand(&.{
        "python3",
        "scripts/release_evidence.py",
        "--gate-mode",
        "strict",
    });
    rgs_evidence.step.dependOn(&rgs_std_shims_behavior.step);

    const release_gate_strict_step = b.step(
        "release-gate-strict",
        "Run strict release gate sequence (fmt -> upstream-pins -> source-conformance -> test -> api-parity -> deep-gate -> vectors -> interop -> prove-checkpoints -> bench-strict -> profile-smoke -> std-shims-smoke -> std-shims-behavior -> release-evidence)",
    );
    release_gate_strict_step.dependOn(&rgs_evidence.step);

    const roadmap_audit_cmd = b.addSystemCommand(&.{ "python3", "scripts/roadmap_audit.py" });
    roadmap_audit_cmd.step.dependOn(&rgs_evidence.step);
    const roadmap_audit_step = b.step(
        "roadmap-audit",
        "Audit CONFORMANCE section-15 closure status (requires all rows Complete)",
    );
    roadmap_audit_step.dependOn(&roadmap_audit_cmd.step);
}
