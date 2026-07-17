const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (importable by downstream packages).
    _ = b.addModule("stwo", .{
        .root_source_file = b.path("src/stwo.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/stwo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

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
    cross_module_test_module.addOptions("test_options", cross_module_test_options);
    const cross_module_tests = b.addTest(.{ .root_module = cross_module_test_module });
    const run_cross_module_tests = b.addRunArtifact(cross_module_tests);
    test_step.dependOn(&run_cross_module_tests.step);

    const metal_session_protocol_test_module = b.createModule(.{
        .root_source_file = b.path("src/metal_prover_session_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const metal_session_protocol_tests = b.addTest(.{ .root_module = metal_session_protocol_test_module });
    const run_metal_session_protocol_tests = b.addRunArtifact(metal_session_protocol_tests);
    test_step.dependOn(&run_metal_session_protocol_tests.step);

    const metal_eval_test_module = b.createModule(.{
        .root_source_file = b.path("src/metal_eval_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const metal_eval_tests = b.addTest(.{ .root_module = metal_eval_test_module });
    const run_metal_eval_tests = b.addRunArtifact(metal_eval_tests);
    test_step.dependOn(&run_metal_eval_tests.step);

    const cairo_input_module = b.createModule(.{
        .root_source_file = b.path("src/cairo_input_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cairo_input_cli = b.addExecutable(.{
        .name = "cairo-input",
        .root_module = cairo_input_module,
    });
    b.installArtifact(cairo_input_cli);
    const cairo_input_step = b.step("cairo-input", "Build adapted Cairo input inspector");
    cairo_input_step.dependOn(&cairo_input_cli.step);

    // -----------------------------------------------------------------
    // RISC-V trace dumper CLI for cross-verification
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // RISC-V benchmark CLI (execute, prove, verify, hosted mode)
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // Metal resident backend (macOS)
    // -----------------------------------------------------------------
    if (target.result.os.tag == .macos) {
        const metal_arena_plan_module = b.createModule(.{
            .root_source_file = b.path("src/metal_arena_plan_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_arena_plan = b.addExecutable(.{
            .name = "metal-arena-plan",
            .root_module = metal_arena_plan_module,
        });
        metal_arena_plan.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_arena_plan.linkLibC();
        metal_arena_plan.linkFramework("Foundation");
        metal_arena_plan.linkFramework("Metal");
        metal_arena_plan.linkSystemLibrary("objc");
        const install_metal_arena_plan = b.addInstallArtifact(metal_arena_plan, .{});
        b.getInstallStep().dependOn(&install_metal_arena_plan.step);
        const metal_arena_plan_step = b.step("metal-arena-plan", "Build sparse Metal arena planner");
        metal_arena_plan_step.dependOn(&install_metal_arena_plan.step);

        const metal_arena_session_module = b.createModule(.{
            .root_source_file = b.path("src/metal_prover_session_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_arena_session = b.addExecutable(.{
            .name = "metal-arena-session",
            .root_module = metal_arena_session_module,
        });
        metal_arena_session.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_arena_session.linkLibC();
        metal_arena_session.linkFramework("Foundation");
        metal_arena_session.linkFramework("Metal");
        metal_arena_session.linkSystemLibrary("objc");
        const install_metal_arena_session = b.addInstallArtifact(metal_arena_session, .{});
        b.getInstallStep().dependOn(&install_metal_arena_session.step);
        const metal_arena_session_step = b.step(
            "metal-arena-session",
            "Build persistent Metal SN PIE prover session",
        );
        metal_arena_session_step.dependOn(&install_metal_arena_session.step);

        const metal_recovery_bench_module = b.createModule(.{
            .root_source_file = b.path("src/metal_recovery_bench_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_recovery_bench = b.addExecutable(.{
            .name = "metal-recovery-bench",
            .root_module = metal_recovery_bench_module,
        });
        b.installArtifact(metal_recovery_bench);
        const metal_recovery_bench_step = b.step("metal-recovery-bench", "Build Metal recovery storage benchmark");
        metal_recovery_bench_step.dependOn(&metal_recovery_bench.step);

        const metal_ec_op_bench_module = b.createModule(.{
            .root_source_file = b.path("src/metal_ec_op_bench_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_ec_op_bench = b.addExecutable(.{
            .name = "metal-ec-op-bench",
            .root_module = metal_ec_op_bench_module,
        });
        metal_ec_op_bench.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_ec_op_bench.linkLibC();
        metal_ec_op_bench.linkFramework("Foundation");
        metal_ec_op_bench.linkFramework("Metal");
        metal_ec_op_bench.linkSystemLibrary("objc");
        b.installArtifact(metal_ec_op_bench);
        const metal_ec_op_bench_step = b.step("metal-ec-op-bench", "Build resident Metal EC-op benchmark");
        metal_ec_op_bench_step.dependOn(&metal_ec_op_bench.step);

        const metal_compact_bench_module = b.createModule(.{
            .root_source_file = b.path("src/metal_compact_bench_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_compact_bench = b.addExecutable(.{
            .name = "metal-compact-bench",
            .root_module = metal_compact_bench_module,
        });
        metal_compact_bench.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_compact_bench.linkLibC();
        metal_compact_bench.linkFramework("Foundation");
        metal_compact_bench.linkFramework("Metal");
        metal_compact_bench.linkSystemLibrary("objc");
        b.installArtifact(metal_compact_bench);
        const metal_compact_bench_step = b.step("metal-compact-bench", "Build resident Metal compaction benchmark");
        metal_compact_bench_step.dependOn(&metal_compact_bench.step);

        const metal_eval_prepare_module = b.createModule(.{
            .root_source_file = b.path("src/metal_eval_prepare_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_eval_prepare = b.addExecutable(.{
            .name = "metal-eval-prepare",
            .root_module = metal_eval_prepare_module,
        });
        metal_eval_prepare.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_eval_prepare.linkLibC();
        metal_eval_prepare.linkFramework("Foundation");
        metal_eval_prepare.linkFramework("Metal");
        metal_eval_prepare.linkSystemLibrary("objc");
        b.installArtifact(metal_eval_prepare);
        const metal_eval_prepare_step = b.step("metal-eval-prepare", "Compile exact SN Cairo AIR programs for Metal");
        metal_eval_prepare_step.dependOn(&metal_eval_prepare.step);

        const metal_eval_source_module = b.createModule(.{
            .root_source_file = b.path("src/metal_eval_source_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_eval_source = b.addExecutable(.{
            .name = "metal-eval-source",
            .root_module = metal_eval_source_module,
        });
        b.installArtifact(metal_eval_source);

        const metal_witness_source_module = b.createModule(.{
            .root_source_file = b.path("src/metal_witness_source_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_witness_source = b.addExecutable(.{
            .name = "metal-witness-source",
            .root_module = metal_witness_source_module,
        });
        b.installArtifact(metal_witness_source);

        const metal_test_module = b.createModule(.{
            .root_source_file = b.path("src/metal_backend_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_tests = b.addTest(.{
            .root_module = metal_test_module,
            .filters = &.{"metal:"},
        });
        metal_tests.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_tests.linkLibC();
        metal_tests.linkFramework("Foundation");
        metal_tests.linkFramework("Metal");
        metal_tests.linkSystemLibrary("objc");
        const run_metal_tests = b.addRunArtifact(metal_tests);
        const metal_test_step = b.step("metal-test", "Run resident Metal backend parity tests");
        metal_test_step.dependOn(&run_metal_tests.step);

        const metal_bench_module = b.createModule(.{
            .root_source_file = b.path("src/metal_bench_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_bench = b.addExecutable(.{
            .name = "metal-bench",
            .root_module = metal_bench_module,
        });
        metal_bench.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        metal_bench.linkLibC();
        metal_bench.linkFramework("Foundation");
        metal_bench.linkFramework("Metal");
        metal_bench.linkSystemLibrary("objc");
        const install_metal_bench = b.addInstallArtifact(metal_bench, .{});
        b.getInstallStep().dependOn(&install_metal_bench.step);
        const metal_bench_step = b.step("metal-bench", "Build resident Metal commitment benchmark");
        metal_bench_step.dependOn(&install_metal_bench.step);

        const riscv_metal_module = b.createModule(.{
            .root_source_file = b.path("src/riscv_metal_bench_cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const riscv_metal_bench = b.addExecutable(.{
            .name = "riscv-metal-bench",
            .root_module = riscv_metal_module,
        });
        riscv_metal_bench.addCSourceFile(.{
            .file = b.path("src/backends/metal/runtime.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        riscv_metal_bench.linkLibC();
        riscv_metal_bench.linkFramework("Foundation");
        riscv_metal_bench.linkFramework("Metal");
        riscv_metal_bench.linkSystemLibrary("objc");
        const install_riscv_metal_bench = b.addInstallArtifact(riscv_metal_bench, .{});
        b.getInstallStep().dependOn(&install_riscv_metal_bench.step);
        const riscv_metal_step = b.step("riscv-metal-bench", "Build RISC-V prover with Metal commitments");
        riscv_metal_step.dependOn(&install_riscv_metal_bench.step);
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

    // Expanded compile/test graph gate.
    const deep_gate_cmd = b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig" });
    const deep_gate_step = b.step("deep-gate", "Run expanded deep graph coverage");
    deep_gate_step.dependOn(&deep_gate_cmd.step);

    // Deterministic parity vectors gate (Rust upstream -> JSON fixtures).
    const vectors_fields_cmd = b.addSystemCommand(&.{ "python3", "scripts/parity_fields.py", "--skip-zig" });
    const vectors_constraint_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/parity_constraint_expr.py",
        "--skip-zig",
    });
    vectors_constraint_cmd.step.dependOn(&vectors_fields_cmd.step);
    const vectors_air_derive_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/parity_air_derive.py",
        "--skip-zig",
    });
    vectors_air_derive_cmd.step.dependOn(&vectors_constraint_cmd.step);
    const vectors_step = b.step("vectors", "Validate committed parity vectors");
    vectors_step.dependOn(&vectors_air_derive_cmd.step);

    // Cross-language interoperability gate (true Rust<->Zig proof exchange + tamper rejection).
    const interop_cmd = b.addSystemCommand(&.{ "python3", "scripts/e2e_interop.py" });
    const interop_step = b.step("interop", "Run interoperability harness (Rust <-> Zig proof exchange)");
    interop_step.dependOn(&interop_cmd.step);

    // Prove/prove_ex checkpoint parity gate (deterministic proof-byte parity + tamper rejection).
    const prove_checkpoints_cmd = b.addSystemCommand(&.{ "python3", "scripts/prove_checkpoints.py" });
    const prove_checkpoints_step = b.step(
        "prove-checkpoints",
        "Run prove/prove_ex checkpoint harness (Rust -> Zig/Rust verification)",
    );
    prove_checkpoints_step.dependOn(&prove_checkpoints_cmd.step);

    // Benchmark smoke gate with deterministic short workloads.
    const bench_smoke_cmd = b.addSystemCommand(&.{ "python3", "scripts/benchmark_smoke.py" });
    const bench_smoke_step = b.step("bench-smoke", "Run benchmark smoke harness and emit report");
    bench_smoke_step.dependOn(&bench_smoke_cmd.step);

    // Targeted kernel benchmark gate for eval_at_point/folding/fft hotspots.
    const bench_kernels_cmd = b.addSystemCommand(&.{ "python3", "scripts/benchmark_kernels.py" });
    const bench_kernels_step = b.step("bench-kernels", "Run targeted kernel benchmark harness");
    bench_kernels_step.dependOn(&bench_kernels_cmd.step);

    // Benchmark strict gate with medium workloads enabled and stabilized sampling.
    const bench_strict_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_smoke.py",
        "--include-medium",
        "--warmups",
        "3",
        "--repeats",
        "11",
    });
    const bench_strict_step = b.step("bench-strict", "Run strict benchmark harness (base + medium workloads, stabilized samples)");
    bench_strict_step.dependOn(&bench_strict_cmd.step);

    // Optimization-track benchmark gate (native tuned, non-release-authoritative).
    const bench_opt_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_smoke.py",
        "--include-medium",
        "--warmups",
        "3",
        "--repeats",
        "11",
        "--max-zig-over-rust",
        "10.0",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--merkle-workers",
        "12",
        "--report-label",
        "optimization_track",
        "--report-out",
        "vectors/reports/benchmark_opt_report.json",
    });
    const bench_opt_step = b.step("bench-opt", "Run optimization-track benchmark harness (native CPU)");
    bench_opt_step.dependOn(&bench_opt_cmd.step);

    const bench_opt_binary_codec_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_smoke.py",
        "--include-medium",
        "--warmups",
        "3",
        "--repeats",
        "11",
        "--max-zig-over-rust",
        "10.0",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--zig-bench-proof-codec",
        "binary",
        "--merkle-workers",
        "12",
        "--report-label",
        "optimization_track_binary_codec",
        "--report-out",
        "vectors/reports/benchmark_opt_binary_codec_report.json",
    });
    const bench_opt_binary_codec_step = b.step(
        "bench-opt-binary-codec",
        "Run optimization-track benchmark with binary internal proof codec (non-default)",
    );
    bench_opt_binary_codec_step.dependOn(&bench_opt_binary_codec_cmd.step);

    // Large contrast benchmark (adds long-running workload slices).
    const bench_contrast_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_smoke.py",
        "--include-medium",
        "--include-large",
        "--warmups",
        "2",
        "--repeats",
        "7",
        "--max-zig-over-rust",
        "10.0",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--merkle-workers",
        "12",
        "--report-label",
        "benchmark_contrast",
        "--report-out",
        "vectors/reports/benchmark_contrast_report.json",
    });
    const bench_contrast_step = b.step(
        "bench-contrast",
        "Run heavy contrast benchmark harness (wide_fibonacci fib100/fib500/fib1000 + plonk_large)",
    );
    bench_contrast_step.dependOn(&bench_contrast_cmd.step);

    const bench_contrast_long_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_smoke.py",
        "--include-medium",
        "--include-large",
        "--include-long",
        "--warmups",
        "1",
        "--repeats",
        "5",
        "--max-zig-over-rust",
        "10.0",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--merkle-workers",
        "12",
        "--merkle-pool-reuse-workloads",
        "blake_deep,poseidon_deep,wide_fibonacci_fib2000",
        "--report-label",
        "benchmark_contrast_long",
        "--report-out",
        "vectors/reports/benchmark_contrast_long_report.json",
    });
    const bench_contrast_long_step = b.step(
        "bench-contrast-long",
        "Run long contrast benchmark harness (fib2000/fib5000 + deep poseidon/blake)",
    );
    bench_contrast_long_step.dependOn(&bench_contrast_long_cmd.step);

    // Full benchmark matrix gate (11 upstream family labels).
    const bench_full_cmd = b.addSystemCommand(&.{ "python3", "scripts/benchmark_full.py" });
    const bench_targeted_compare_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/compare_optimization.py",
        "--baseline",
        "vectors/reports/optimization_baseline_wave4.json",
        "--benchmark-report",
        "vectors/reports/benchmark_smoke_report.json",
        "--benchmark-full-report",
        "vectors/reports/benchmark_full_report.json",
        "--profile-report",
        "vectors/reports/profile_smoke_report.json",
        "--kernel-report",
        "vectors/reports/benchmark_kernels_report.json",
        "--max-prove-regression-pct",
        "100.0",
        "--max-verify-regression-pct",
        "100.0",
        "--max-rss-regression-pct",
        "100.0",
        "--max-zig-profile-regression-pct",
        "100.0",
        "--max-kernel-regression-pct",
        "100.0",
        "--kernel-min-baseline-seconds",
        "0.01",
        "--kernel-min-absolute-delta-seconds",
        "0.002",
        "--max-target-family-regression-pct",
        "3.0",
        "--max-target-family-rss-regression-pct",
        "3.0",
    });
    bench_targeted_compare_cmd.step.dependOn(&bench_full_cmd.step);
    bench_targeted_compare_cmd.step.dependOn(&bench_strict_cmd.step);
    bench_targeted_compare_cmd.step.dependOn(&bench_kernels_cmd.step);
    const bench_targeted_step = b.step(
        "bench-targeted-families",
        "Run full benchmark and block regressions on eval_at_point/eval_at_point_by_folding/fft",
    );
    bench_targeted_step.dependOn(&bench_targeted_compare_cmd.step);
    const bench_pages_cmd = b.addSystemCommand(&.{ "python3", "scripts/benchmark_pages.py" });
    bench_pages_cmd.step.dependOn(&bench_full_cmd.step);
    bench_pages_cmd.step.dependOn(&bench_contrast_long_cmd.step);
    const bench_pages_step = b.step(
        "bench-pages",
        "Render static benchmark pages assets from family+example benchmark reports (includes RAM metrics)",
    );
    bench_pages_step.dependOn(&bench_pages_cmd.step);
    const bench_full_step = b.step(
        "bench-full",
        "Run full benchmark suite (11 families + long example matrix) and publish static pages data",
    );
    bench_full_step.dependOn(&bench_pages_cmd.step);
    const bench_pages_validate_cmd = b.addSystemCommand(&.{ "python3", "scripts/benchmark_pages.py", "--validate" });
    const bench_pages_validate_step = b.step("bench-pages-validate", "Validate static benchmark pages assets are current");
    bench_pages_validate_step.dependOn(&bench_pages_validate_cmd.step);

    // Profiling smoke gate with coarse wall-clock and peak-RSS collection.
    const profile_smoke_cmd = b.addSystemCommand(&.{ "python3", "scripts/profile_smoke.py" });
    const profile_smoke_step = b.step("profile-smoke", "Run profiling smoke harness and emit report");
    profile_smoke_step.dependOn(&profile_smoke_cmd.step);
    bench_targeted_compare_cmd.step.dependOn(&profile_smoke_cmd.step);

    // Optimization-track profiling gate (native tuned, non-release-authoritative).
    const profile_opt_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/profile_smoke.py",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--merkle-workers",
        "12",
        "--report-label",
        "optimization_track",
        "--report-out",
        "vectors/reports/profile_opt_report.json",
    });
    const profile_opt_step = b.step("profile-opt", "Run optimization-track profile harness (native CPU)");
    profile_opt_step.dependOn(&profile_opt_cmd.step);

    const profile_contrast_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/profile_smoke.py",
        "--include-large",
        "--repeats",
        "1",
        "--sample-duration-seconds",
        "1",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--merkle-workers",
        "12",
        "--report-label",
        "profile_contrast",
        "--report-out",
        "vectors/reports/profile_contrast_report.json",
    });
    const profile_contrast_step = b.step(
        "profile-contrast",
        "Run larger contrast profile harness (adds fib500/plonk_deep hotspots)",
    );
    profile_contrast_step.dependOn(&profile_contrast_cmd.step);

    const profile_contrast_long_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/profile_smoke.py",
        "--include-large",
        "--include-long",
        "--repeats",
        "1",
        "--sample-duration-seconds",
        "2",
        "--zig-opt-mode",
        "ReleaseFast",
        "--zig-cpu",
        "native",
        "--merkle-workers",
        "12",
        "--merkle-pool-reuse-workloads",
        "blake_deep,poseidon_deep,wide_fibonacci_fib2000",
        "--report-label",
        "profile_contrast_long",
        "--report-out",
        "vectors/reports/profile_contrast_long_report.json",
    });
    const profile_contrast_long_step = b.step(
        "profile-contrast-long",
        "Run long contrast profile harness (adds fib2000/fib5000 + deep poseidon/blake hotspots)",
    );
    profile_contrast_long_step.dependOn(&profile_contrast_long_cmd.step);

    // Deterministic deep-workload soak for 2/4/8 Merkle workers with opt-in pool reuse.
    const merkle_worker_stress_cmd = b.addSystemCommand(&.{ "python3", "scripts/merkle_worker_stress.py" });
    const merkle_worker_stress_step = b.step(
        "merkle-worker-stress",
        "Run deterministic deep workload stress checks for opt-in Merkle pool reuse (2/4/8 workers)",
    );
    merkle_worker_stress_step.dependOn(&merkle_worker_stress_cmd.step);

    // Optimization acceptance gate against frozen baseline (additive to strict conformance gate).
    const opt_compare_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/compare_optimization.py",
        "--baseline",
        "vectors/reports/optimization_baseline_wave4.json",
        "--benchmark-report",
        "vectors/reports/benchmark_smoke_report.json",
        "--benchmark-full-report",
        "vectors/reports/benchmark_full_report.json",
        "--profile-report",
        "vectors/reports/profile_smoke_report.json",
        "--kernel-report",
        "vectors/reports/benchmark_kernels_report.json",
        "--max-prove-regression-pct",
        "10.0",
        "--max-verify-regression-pct",
        "12.0",
        "--max-rss-regression-pct",
        "5.0",
        "--max-zig-profile-regression-pct",
        "15.0",
        "--max-kernel-regression-pct",
        "18.0",
        "--kernel-min-baseline-seconds",
        "0.01",
        "--kernel-min-absolute-delta-seconds",
        "0.002",
        "--max-target-family-regression-pct",
        "14.0",
        "--max-target-family-rss-regression-pct",
        "80.0",
    });
    opt_compare_cmd.step.dependOn(&bench_strict_cmd.step);
    opt_compare_cmd.step.dependOn(&profile_smoke_cmd.step);
    opt_compare_cmd.step.dependOn(&bench_kernels_cmd.step);
    opt_compare_cmd.step.dependOn(&bench_full_cmd.step);
    opt_compare_cmd.step.dependOn(&merkle_worker_stress_cmd.step);
    opt_compare_cmd.step.dependOn(&bench_opt_cmd.step);
    opt_compare_cmd.step.dependOn(&profile_opt_cmd.step);
    const opt_gate_step = b.step(
        "opt-gate",
        "Run optimization acceptance gate (bench/profile + baseline comparator)",
    );
    opt_gate_step.dependOn(&opt_compare_cmd.step);

    // Freestanding verifier profile compile check.
    const std_shims_smoke_cmd = b.addSystemCommand(&.{
        "zig",
        "build-lib",
        "src/std_shims_freestanding.zig",
        "-target",
        "wasm32-freestanding",
        "-O",
        "ReleaseSmall",
        "-femit-bin=/tmp/stwo-zig-std-shims-verifier.wasm",
    });
    const std_shims_smoke_step = b.step(
        "std-shims-smoke",
        "Build freestanding verifier profile shim (wasm32-freestanding)",
    );
    std_shims_smoke_step.dependOn(&std_shims_smoke_cmd.step);

    // Std-shims behavior parity against standard verifier over checkpoint artifacts.
    const std_shims_behavior_cmd = b.addSystemCommand(&.{ "python3", "scripts/std_shims_behavior.py" });
    const std_shims_behavior_step = b.step(
        "std-shims-behavior",
        "Validate std-shims verifier behavior parity against standard verifier",
    );
    std_shims_behavior_cmd.step.dependOn(&prove_checkpoints_cmd.step);
    std_shims_behavior_step.dependOn(&std_shims_behavior_cmd.step);

    // Canonical release evidence manifest generator.
    const release_evidence_cmd = b.addSystemCommand(&.{
        "python3",
        "scripts/release_evidence.py",
        "--gate-mode",
        "strict",
    });
    const release_evidence_step = b.step(
        "release-evidence",
        "Generate canonical release evidence manifest (vectors/reports/release_evidence.json)",
    );
    release_evidence_step.dependOn(&release_evidence_cmd.step);

    // Formatting gate.
    const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "tools" });
    const fmt_step = b.step("fmt", "Check formatting (zig fmt --check)");
    fmt_step.dependOn(&fmt_cmd.step);

    // API parity ledger validation.
    const api_parity_cmd = b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" });
    const api_parity_step = b.step("api-parity", "Validate API parity ledger coverage");
    api_parity_step.dependOn(&api_parity_cmd.step);

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
    // fmt -> source-conformance -> test -> api-parity -> vectors -> interop -> bench-smoke -> profile-smoke
    const rg_fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "tools" });
    const rg_source_conformance = b.addSystemCommand(&.{
        "python3",
        "scripts/check_source_conformance.py",
    });
    rg_source_conformance.step.dependOn(&rg_fmt.step);
    const rg_test = b.addSystemCommand(&.{ "zig", "test", "src/stwo.zig" });
    rg_test.step.dependOn(&rg_source_conformance.step);
    const rg_api_parity = b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" });
    rg_api_parity.step.dependOn(&rg_test.step);
    const rg_vectors_fields = b.addSystemCommand(&.{ "python3", "scripts/parity_fields.py", "--skip-zig" });
    rg_vectors_fields.step.dependOn(&rg_api_parity.step);
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
        "Run release gate sequence (fmt -> source-conformance -> test -> api-parity -> vectors -> interop -> bench-smoke -> profile-smoke)",
    );
    release_gate_step.dependOn(&rg_profile.step);

    // Strict release gate sequence:
    // fmt -> source-conformance -> test -> api-parity -> deep-gate -> vectors -> interop -> prove-checkpoints -> bench-strict -> profile-smoke -> std-shims-smoke -> std-shims-behavior
    const rgs_fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "tools" });
    const rgs_source_conformance = b.addSystemCommand(&.{
        "python3",
        "scripts/check_source_conformance.py",
    });
    rgs_source_conformance.step.dependOn(&rgs_fmt.step);
    const rgs_test = b.addSystemCommand(&.{ "zig", "test", "src/stwo.zig" });
    rgs_test.step.dependOn(&rgs_source_conformance.step);
    const rgs_api_parity = b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" });
    rgs_api_parity.step.dependOn(&rgs_test.step);
    const rgs_deep = b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig" });
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
        "Run strict release gate sequence (fmt -> source-conformance -> test -> api-parity -> deep-gate -> vectors -> interop -> prove-checkpoints -> bench-strict -> profile-smoke -> std-shims-smoke -> std-shims-behavior -> release-evidence)",
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
