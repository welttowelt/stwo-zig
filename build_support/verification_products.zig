const std = @import("std");

pub const Context = struct {
    b: *std.Build,
    zig_optimize_arg: []const u8,
    riscv_release_phase: []const u8,
    riscv_evidence_dir: []const u8,
};

pub fn addProducts(context: Context) void {
    const b = context.b;
    const zig_optimize_arg = context.zig_optimize_arg;
    const riscv_release_phase = context.riscv_release_phase;
    const riscv_receipt = b.fmt("{s}/oracle-receipt.json", .{context.riscv_evidence_dir});

    // CP-13 remains independent of the ordinary release chains until RF-01.
    // The final candidate-bound evidence check intentionally fails while any
    // CP-11 boundary or provenance field is unavailable.
    const riscv_contract = b.addSystemCommand(&.{
        "python3", "scripts/check_riscv_release_contract.py", "--all", "--phase", riscv_release_phase,
    });
    const riscv_vectors = b.addSystemCommand(&.{ "python3", "scripts/riscv_trace_vectors.py" });
    riscv_vectors.step.dependOn(&riscv_contract.step);
    const riscv_smoke = b.addSystemCommand(&.{
        "python3", "scripts/riscv_staged_smoke.py", "--phase", riscv_release_phase,
    });
    riscv_smoke.step.dependOn(&riscv_vectors.step);
    const riscv_evidence = b.addSystemCommand(&.{
        "python3",          "scripts/riscv_release_evidence.py",
        "--receipt",        riscv_receipt,
        "--candidate-head",
    });
    riscv_evidence.step.dependOn(&riscv_smoke.step);
    const riscv_release_gate = b.step(
        "riscv-release-gate",
        "Run the staged CLI and validate complete candidate-bound CP-11 evidence",
    );
    riscv_release_gate.dependOn(&riscv_evidence.step);

    // Expanded compile/test graph gate.
    const deep_gate_cmd = b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig", zig_optimize_arg });
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
}
