const std = @import("std");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    stwo_module: *std.Build.Module,
    native_proof_runner_module: *std.Build.Module,
    test_step: *std.Build.Step,
};

pub fn addProducts(context: Context) void {
    const b = context.b;
    const target = context.target;
    const optimize = context.optimize;
    const stwo_module = context.stwo_module;
    const native_proof_runner_module = context.native_proof_runner_module;
    const test_step = context.test_step;

    const native_proof_metal_module = b.createModule(.{
        .root_source_file = b.path("src/tools/native_proof_bench/metal.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_proof_metal_module.addImport("stwo", stwo_module);
    native_proof_metal_module.addImport("native_proof_runner", native_proof_runner_module);
    const native_proof_metal = b.addExecutable(.{
        .name = "native-proof-bench-metal",
        .root_module = native_proof_metal_module,
    });
    linkRuntime(b, native_proof_metal);
    const install_native_proof_metal = b.addInstallArtifact(native_proof_metal, .{});
    const native_proof_metal_step = b.step(
        "native-proof-bench-metal",
        "Build the machine-readable hybrid Metal full-proof benchmark",
    );
    native_proof_metal_step.dependOn(&install_native_proof_metal.step);

    const metal_arena_plan_module = b.createModule(.{
        .root_source_file = b.path("src/metal_arena_plan_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_arena_plan_module.addImport("stwo", stwo_module);
    const metal_arena_plan = b.addExecutable(.{
        .name = "metal-arena-plan",
        .root_module = metal_arena_plan_module,
    });
    linkRuntime(b, metal_arena_plan);
    const install_metal_arena_plan = b.addInstallArtifact(metal_arena_plan, .{});
    b.getInstallStep().dependOn(&install_metal_arena_plan.step);
    const metal_arena_plan_step = b.step("metal-arena-plan", "Build sparse Metal arena planner");
    metal_arena_plan_step.dependOn(&install_metal_arena_plan.step);

    const metal_arena_session_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_prover_session/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_arena_session_module.addImport("stwo", stwo_module);
    metal_arena_session_module.addImport("one_shot", metal_arena_plan_module);
    const metal_arena_session = b.addExecutable(.{
        .name = "metal-arena-session",
        .root_module = metal_arena_session_module,
    });
    linkFrameworks(metal_arena_session);
    const install_metal_arena_session = b.addInstallArtifact(metal_arena_session, .{});
    b.getInstallStep().dependOn(&install_metal_arena_session.step);
    const metal_arena_session_step = b.step(
        "metal-arena-session",
        "Build persistent Metal SN PIE prover session",
    );
    metal_arena_session_step.dependOn(&install_metal_arena_session.step);

    const metal_arena_session_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_prover_session/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_arena_session_test_module.addImport("stwo", stwo_module);
    metal_arena_session_test_module.addImport("one_shot", metal_arena_plan_module);
    const metal_arena_session_tests = b.addTest(.{
        .root_module = metal_arena_session_test_module,
    });
    linkFrameworks(metal_arena_session_tests);
    const run_metal_arena_session_tests = b.addRunArtifact(metal_arena_session_tests);
    const metal_arena_session_test_step = b.step(
        "metal-prover-session-test",
        "Run persistent Metal prover-session unit tests",
    );
    metal_arena_session_test_step.dependOn(&run_metal_arena_session_tests.step);
    test_step.dependOn(&run_metal_arena_session_tests.step);

    const metal_recovery_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench/metal/recovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_recovery_bench_module.addImport("stwo", stwo_module);
    const metal_recovery_bench = b.addExecutable(.{
        .name = "metal-recovery-bench",
        .root_module = metal_recovery_bench_module,
    });
    b.installArtifact(metal_recovery_bench);
    const metal_recovery_bench_step = b.step("metal-recovery-bench", "Build Metal recovery storage benchmark");
    metal_recovery_bench_step.dependOn(&metal_recovery_bench.step);

    const metal_ec_op_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench/metal/ec_op.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_ec_op_bench_module.addImport("stwo", stwo_module);
    const metal_ec_op_bench = b.addExecutable(.{
        .name = "metal-ec-op-bench",
        .root_module = metal_ec_op_bench_module,
    });
    linkRuntime(b, metal_ec_op_bench);
    b.installArtifact(metal_ec_op_bench);
    const metal_ec_op_bench_step = b.step("metal-ec-op-bench", "Build resident Metal EC-op benchmark");
    metal_ec_op_bench_step.dependOn(&metal_ec_op_bench.step);

    const metal_compact_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench/metal/compaction.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_compact_bench_module.addImport("stwo", stwo_module);
    const metal_compact_bench = b.addExecutable(.{
        .name = "metal-compact-bench",
        .root_module = metal_compact_bench_module,
    });
    linkRuntime(b, metal_compact_bench);
    b.installArtifact(metal_compact_bench);
    const metal_compact_bench_step = b.step("metal-compact-bench", "Build resident Metal compaction benchmark");
    metal_compact_bench_step.dependOn(&metal_compact_bench.step);

    const cairo_streaming_commitment_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench/cairo_metal/streaming_commitment.zig"),
        .target = target,
        .optimize = optimize,
    });
    cairo_streaming_commitment_bench_module.addImport("stwo", stwo_module);
    const cairo_streaming_commitment_bench = b.addExecutable(.{
        .name = "cairo-streaming-commitment-bench",
        .root_module = cairo_streaming_commitment_bench_module,
    });
    linkRuntime(b, cairo_streaming_commitment_bench);
    const install_cairo_streaming_commitment_bench = b.addInstallArtifact(cairo_streaming_commitment_bench, .{});
    const cairo_streaming_commitment_bench_step = b.step(
        "cairo-streaming-commitment-bench",
        "Build bounded production-callsite Cairo Metal commitment benchmark",
    );
    cairo_streaming_commitment_bench_step.dependOn(&install_cairo_streaming_commitment_bench.step);

    const cairo_streaming_commitment_test_module = b.createModule(.{
        .root_source_file = b.path("src/bench/cairo_metal/streaming_commitment.zig"),
        .target = target,
        .optimize = optimize,
    });
    cairo_streaming_commitment_test_module.addImport("stwo", stwo_module);
    const cairo_streaming_commitment_tests = b.addTest(.{ .root_module = cairo_streaming_commitment_test_module });
    linkRuntime(b, cairo_streaming_commitment_tests);
    const run_cairo_streaming_commitment_tests = b.addRunArtifact(cairo_streaming_commitment_tests);
    const cairo_streaming_commitment_test_step = b.step(
        "cairo-streaming-commitment-test",
        "Run bounded production-callsite Cairo Metal commitment parity test",
    );
    cairo_streaming_commitment_test_step.dependOn(&run_cairo_streaming_commitment_tests.step);

    const metal_eval_prepare_module = b.createModule(.{
        .root_source_file = b.path("src/tools/cairo_metal_codegen/eval_prepare.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_eval_prepare_module.addImport("stwo", stwo_module);
    const metal_eval_prepare = b.addExecutable(.{
        .name = "metal-eval-prepare",
        .root_module = metal_eval_prepare_module,
    });
    linkRuntime(b, metal_eval_prepare);
    b.installArtifact(metal_eval_prepare);
    const metal_eval_prepare_step = b.step("metal-eval-prepare", "Compile exact SN Cairo AIR programs for Metal");
    metal_eval_prepare_step.dependOn(&metal_eval_prepare.step);

    const metal_eval_source_module = b.createModule(.{
        .root_source_file = b.path("src/tools/cairo_metal_codegen/eval_source.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_eval_source_module.addImport("stwo", stwo_module);
    const metal_eval_source = b.addExecutable(.{
        .name = "metal-eval-source",
        .root_module = metal_eval_source_module,
    });
    b.installArtifact(metal_eval_source);

    const metal_witness_source_module = b.createModule(.{
        .root_source_file = b.path("src/tools/cairo_metal_codegen/witness_source.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_witness_source_module.addImport("stwo", stwo_module);
    const metal_witness_source = b.addExecutable(.{
        .name = "metal-witness-source",
        .root_module = metal_witness_source_module,
    });
    b.installArtifact(metal_witness_source);

    const metal_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const metal_test_options = b.addOptions();
    metal_test_options.addOption(bool, "riscv_only", false);
    metal_test_options.addOption(bool, "metal_only", true);
    metal_test_module.addOptions("test_options", metal_test_options);
    const metal_tests = b.addTest(.{
        .root_module = metal_test_module,
        .filters = &.{"metal:"},
    });
    linkRuntime(b, metal_tests);
    const run_metal_tests = b.addRunArtifact(metal_tests);
    const metal_test_step = b.step("metal-test", "Run resident Metal backend parity tests");
    metal_test_step.dependOn(&run_metal_tests.step);
    const metal_check_step = b.step(
        "metal-check",
        "Compile and link resident Metal backend tests without executing them",
    );
    metal_check_step.dependOn(&metal_tests.step);

    const metal_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench/metal/commitment.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_bench_module.addImport("stwo", stwo_module);
    const metal_bench = b.addExecutable(.{
        .name = "metal-bench",
        .root_module = metal_bench_module,
    });
    linkRuntime(b, metal_bench);
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
    linkRuntime(b, riscv_metal_bench);
    const install_riscv_metal_bench = b.addInstallArtifact(riscv_metal_bench, .{});
    b.getInstallStep().dependOn(&install_riscv_metal_bench.step);
    const riscv_metal_step = b.step("riscv-metal-bench", "Build RISC-V prover with Metal commitments");
    riscv_metal_step.dependOn(&install_riscv_metal_bench.step);
}

pub fn linkRuntime(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addCSourceFile(.{
        .file = b.path("src/backends/metal/runtime.m"),
        .flags = &.{ "-fobjc-arc", "-fblocks" },
    });
    linkFrameworks(artifact);
}

fn linkFrameworks(artifact: *std.Build.Step.Compile) void {
    artifact.linkLibC();
    artifact.linkFramework("Foundation");
    artifact.linkFramework("Metal");
    artifact.linkSystemLibrary("objc");
}
