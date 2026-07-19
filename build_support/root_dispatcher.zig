//! Public build-step registry and focused delegation boundary.

const std = @import("std");
const libraries = @import("products/libraries.zig");

const StepSpec = struct {
    name: []const u8,
    description: []const u8,
    scope: []const u8,
};

const steps = [_]StepSpec{
    .{ .name = "architecture-gate", .description = "Produce one host-local BG-15 architecture receipt", .scope = "architecture" },
    .{ .name = "architecture-verify", .description = "Verify Linux and macOS BG-15 receipts in the trusted workflow", .scope = "architecture" },
    .{ .name = "build-monorepo-baseline", .description = "Validate the immutable pre-migration build and performance baseline", .scope = "architecture" },
    .{ .name = "stwo-core", .description = "Build the focused Stwo core library", .scope = "core" },
    .{ .name = "test-stwo-core", .description = "Test the focused Stwo core library and purity boundary", .scope = "core" },
    .{ .name = "stwo-prover", .description = "Build the focused backend-generic Stwo prover library", .scope = "prover" },
    .{ .name = "test-stwo-prover", .description = "Test the focused generic prover, backend contracts, and purity boundary", .scope = "prover" },
    .{ .name = "test-downstream-modules", .description = "Compile and run a clean external consumer of stwo_core, stwo_prover, and stwo", .scope = "aggregate" },
    .{ .name = "interop-cli", .description = "Build the proof interoperability CLI", .scope = "aggregate" },
    .{ .name = "test", .description = "Run unit tests", .scope = "aggregate" },
    .{ .name = "metal-core-aot", .description = "Build the deterministic, fail-closed core Metal AOT tool", .scope = "metal_tools" },
    .{ .name = "test-metal-core-aot", .description = "Run deterministic core Metal AOT tooling tests without compiling shaders", .scope = "metal_tools" },
    .{ .name = "metal-core-aot-probe", .description = "Build the authenticated Native core metallib acceptance probe", .scope = "metal_tools" },
    .{ .name = "test-metal-core-aot-probe", .description = "Run Native core metallib probe contract tests without compiling shaders", .scope = "metal_tools" },
    .{ .name = "metal-core-aot-acceptance", .description = "Build, authenticate, and inspect the linked Native core metallib", .scope = "metal_tools" },
    .{ .name = "cairo-input", .description = "Build adapted Cairo input inspector", .scope = "aggregate" },
    .{ .name = "riscv-opcode-manifest", .description = "Dump the canonical Stark-V opcode and proof-family policy as JSON", .scope = "aggregate" },
    .{ .name = "riscv-opcode-manifest-check", .description = "Validate exact Stark-V opcode IDs and execution-only classifications", .scope = "aggregate" },
    .{ .name = "test-riscv", .description = "Run RISC-V runner tests (trace_dump)", .scope = "aggregate" },
    .{ .name = "test-riscv-prover", .description = "Run RISC-V prover tests (prove+verify)", .scope = "aggregate" },
    .{ .name = "riscv-bench", .description = "Build RISC-V benchmark CLI", .scope = "aggregate" },
    .{ .name = "native-proof-bench-cpu", .description = "Build the machine-readable native CPU full-proof benchmark with SIMD hot paths", .scope = "aggregate" },
    .{ .name = "stwo-zig", .description = "Build the production proof CLI", .scope = "aggregate" },
    .{ .name = "stwo-native-cpu", .description = "Build the focused Native CPU/SIMD proof CLI", .scope = "native_cpu" },
    .{ .name = "benchmark-native-cpu", .description = "Build the focused Native CPU/SIMD benchmark", .scope = "native_cpu" },
    .{ .name = "test-native-cpu-product", .description = "Test Native CPU product behavior, imports, and visible capabilities", .scope = "native_cpu" },
    .{ .name = "stwo-native-metal", .description = "Build the focused Native Metal proof CLI", .scope = "native_metal" },
    .{ .name = "native-proof-bench-metal", .description = "Build the compatible machine-readable Native Metal proof benchmark", .scope = "native_metal" },
    .{ .name = "test-native-metal", .description = "Test Native Metal ownership, linkage, and visible capabilities", .scope = "native_metal" },
    .{ .name = "riscv-trace-dump", .description = "Build RISC-V trace dumper CLI", .scope = "riscv_cpu" },
    .{ .name = "stwo-zig-riscv-cpu", .description = "Build the focused Stark-V RV32IM CPU/SIMD proof CLI", .scope = "riscv_cpu" },
    .{ .name = "stwo-zig-riscv-cpu-static", .description = "Build the static x86_64-linux-musl RISC-V CPU challenge executable", .scope = "riscv_cpu" },
    .{ .name = "test-riscv-cpu-product", .description = "Test the focused RISC-V CPU product shell and capability surface", .scope = "riscv_cpu" },
    .{ .name = "metal-arena-plan", .description = "Build sparse Metal arena planner", .scope = "metal_tools" },
    .{ .name = "metal-arena-session", .description = "Build persistent Metal SN PIE prover session", .scope = "metal_tools" },
    .{ .name = "metal-prover-session-test", .description = "Run persistent Metal prover-session unit tests", .scope = "metal_tools" },
    .{ .name = "metal-recovery-bench", .description = "Build Metal recovery storage benchmark", .scope = "metal_tools" },
    .{ .name = "metal-ec-op-bench", .description = "Build resident Metal EC-op benchmark", .scope = "metal_tools" },
    .{ .name = "metal-compact-bench", .description = "Build resident Metal compaction benchmark", .scope = "metal_tools" },
    .{ .name = "cairo-streaming-commitment-bench", .description = "Build bounded production-callsite Cairo Metal commitment benchmark", .scope = "metal_tools" },
    .{ .name = "cairo-streaming-commitment-test", .description = "Run bounded production-callsite Cairo Metal commitment parity test", .scope = "metal_tools" },
    .{ .name = "metal-eval-prepare", .description = "Compile exact SN Cairo AIR programs for Metal", .scope = "metal_tools" },
    .{ .name = "metal-eval-source", .description = "Build the exact Cairo AIR Metal source generator", .scope = "metal_tools" },
    .{ .name = "metal-witness-source", .description = "Build the exact Cairo witness Metal source generator", .scope = "metal_tools" },
    .{ .name = "metal-test", .description = "Run resident Metal backend parity tests", .scope = "metal_tools" },
    .{ .name = "metal-check", .description = "Compile and link resident Metal backend tests without executing them", .scope = "metal_tools" },
    .{ .name = "metal-bench", .description = "Build resident Metal commitment benchmark", .scope = "metal_tools" },
    .{ .name = "riscv-metal-bench", .description = "Build RISC-V prover with Metal commitments", .scope = "metal_tools" },
    .{ .name = "stwo-cairo-cpu", .description = "Cairo proving remains disabled until its separate Rust-oracle semantic release goal passes", .scope = "deferred" },
    .{ .name = "stwo-cairo-metal", .description = "Cairo Metal proving is disabled until Cairo CPU semantics pass their separate Rust-oracle release goal", .scope = "deferred" },
    .{ .name = "stwo-riscv-metal", .description = "the RISC-V Metal integration has no parity-gated product implementation", .scope = "deferred" },
    .{ .name = "stwo-native-cuda", .description = "the experimental Native CUDA product requires an explicit toolchain contract and a separately parity-gated kernel implementation", .scope = "deferred" },
    .{ .name = "stwo-cairo-cuda", .description = "Cairo CUDA proving is disabled until Cairo CPU semantics pass their separate Rust-oracle release goal", .scope = "deferred" },
    .{ .name = "stwo-riscv-cuda", .description = "the RISC-V CUDA integration has no parity-gated product implementation", .scope = "deferred" },
    .{ .name = "cuda-test", .description = "Unavailable compatibility alias; CUDA now requires an explicit product toolchain", .scope = "deferred" },
    .{ .name = "riscv-release-gate", .description = "Run the staged CLI and validate complete candidate-bound CP-11 evidence", .scope = "verification" },
    .{ .name = "deep-gate", .description = "Run expanded deep graph coverage", .scope = "verification" },
    .{ .name = "vectors", .description = "Validate committed parity vectors", .scope = "verification" },
    .{ .name = "interop", .description = "Run interoperability harness (Rust <-> Zig proof exchange)", .scope = "verification" },
    .{ .name = "prove-checkpoints", .description = "Run prove/prove_ex checkpoint harness (Rust -> Zig/Rust verification)", .scope = "verification" },
    .{ .name = "bench-smoke", .description = "Run benchmark smoke harness and emit report", .scope = "verification" },
    .{ .name = "bench-kernels", .description = "Run targeted kernel benchmark harness", .scope = "verification" },
    .{ .name = "bench-strict", .description = "Run strict benchmark harness (base + medium workloads, stabilized samples)", .scope = "verification" },
    .{ .name = "bench-opt", .description = "Run optimization-track benchmark harness (native CPU)", .scope = "verification" },
    .{ .name = "bench-opt-binary-codec", .description = "Run optimization-track benchmark with binary internal proof codec (non-default)", .scope = "verification" },
    .{ .name = "bench-contrast", .description = "Run heavy contrast benchmark harness (wide_fibonacci fib100/fib500/fib1000 + plonk_large)", .scope = "verification" },
    .{ .name = "bench-contrast-long", .description = "Run long contrast benchmark harness (fib2000/fib5000 + deep poseidon/blake)", .scope = "verification" },
    .{ .name = "bench-targeted-families", .description = "Run full benchmark and block regressions on eval_at_point/eval_at_point_by_folding/fft", .scope = "verification" },
    .{ .name = "bench-pages", .description = "Render static benchmark pages assets from family+example benchmark reports (includes RAM metrics)", .scope = "verification" },
    .{ .name = "bench-full", .description = "Run full benchmark suite (11 families + long example matrix) and publish static pages data", .scope = "verification" },
    .{ .name = "bench-pages-validate", .description = "Validate static benchmark pages assets are current", .scope = "verification" },
    .{ .name = "profile-smoke", .description = "Run profiling smoke harness and emit report", .scope = "verification" },
    .{ .name = "profile-opt", .description = "Run optimization-track profile harness (native CPU)", .scope = "verification" },
    .{ .name = "profile-contrast", .description = "Run larger contrast profile harness (adds fib500/plonk_deep hotspots)", .scope = "verification" },
    .{ .name = "profile-contrast-long", .description = "Run long contrast profile harness (adds fib2000/fib5000 + deep poseidon/blake hotspots)", .scope = "verification" },
    .{ .name = "merkle-worker-stress", .description = "Run deterministic deep workload stress checks for opt-in Merkle pool reuse (2/4/8 workers)", .scope = "verification" },
    .{ .name = "opt-gate", .description = "Run optimization acceptance gate (bench/profile + baseline comparator)", .scope = "verification" },
    .{ .name = "std-shims-smoke", .description = "Build freestanding verifier profile shim (wasm32-freestanding)", .scope = "verification" },
    .{ .name = "std-shims-behavior", .description = "Validate std-shims verifier behavior parity against standard verifier", .scope = "verification" },
    .{ .name = "release-evidence", .description = "Generate canonical release evidence manifest (vectors/reports/release_evidence.json)", .scope = "verification" },
    .{ .name = "fmt", .description = "Check formatting (zig fmt --check)", .scope = "policy" },
    .{ .name = "api-parity", .description = "Validate API parity ledger coverage", .scope = "policy" },
    .{ .name = "upstream-pins", .description = "Validate Native and Cairo pin carriers against the upstream ledger", .scope = "policy" },
    .{ .name = "source-conformance", .description = "Reject new source layout, dependency direction, and file-size violations", .scope = "policy" },
    .{ .name = "upstream-surface", .description = "Validate API parity rust_path entries against pinned upstream commit", .scope = "policy" },
    .{ .name = "build-configure-closure", .description = "Verify focused configure closure and the default install manifest", .scope = "policy" },
    .{ .name = "release-gate", .description = "Run release gate sequence (fmt -> upstream-pins -> source-conformance -> test -> test-riscv -> test-riscv-prover -> api-parity -> deep-gate -> vectors -> interop -> bench-smoke -> profile-smoke)", .scope = "aggregate" },
    .{ .name = "release-gate-strict", .description = "Run strict release gate sequence (fmt -> upstream-pins -> source-conformance -> test -> test-riscv -> test-riscv-prover -> api-parity -> deep-gate -> vectors -> interop -> prove-checkpoints -> bench-strict -> profile-smoke -> std-shims-smoke -> std-shims-behavior -> release-evidence)", .scope = "aggregate" },
};

pub fn add(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = libraries.addPublicModules(.{ .b = b, .target = target, .optimize = optimize });

    const options = ForwardedOptions.read(b);
    for (steps) |spec| addProxy(b, target, optimize, options, spec);
    addInstallProxy(b, target, optimize, options);
}

const ForwardedOptions = struct {
    aggregate_metal: bool,
    riscv_release_phase: []const u8,
    riscv_evidence_dir: []const u8,
    implementation_commit: ?[]const u8,
    implementation_dirty: ?bool,

    fn read(b: *std.Build) ForwardedOptions {
        return .{
            .aggregate_metal = b.option(bool, "aggregate-metal", "Explicitly link Metal into aggregate test roots") orelse false,
            .riscv_release_phase = b.option([]const u8, "riscv-release-phase", "CP-13 phase: candidate or promoted") orelse "candidate",
            .riscv_evidence_dir = b.option([]const u8, "riscv-evidence-dir", "Fresh CP-13 evidence directory") orelse "zig-out/release-evidence/riscv",
            .implementation_commit = b.option([]const u8, "implementation-commit", "Exact lowercase 40-hex source commit embedded in the production CLI"),
            .implementation_dirty = b.option(bool, "implementation-dirty", "Whether the source embedded in the production CLI has local modifications"),
        };
    }
};

fn addProxy(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: ForwardedOptions,
    spec: StepSpec,
) void {
    const command = delegatedCommand(b, target, optimize, options, spec.scope, spec.name);
    b.step(spec.name, spec.description).dependOn(&command.step);
}

fn addInstallProxy(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: ForwardedOptions,
) void {
    const command = delegatedCommand(b, target, optimize, options, "aggregate", "stwo-zig");
    b.getInstallStep().dependOn(&command.step);
}

fn delegatedCommand(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: ForwardedOptions,
    scope: []const u8,
    step_name: []const u8,
) *std.Build.Step.Run {
    const repository_root = b.pathFromRoot(".");
    const build_file = b.pathFromRoot("build_support/internal_build.zig");
    const cache_dir = b.pathFromRoot(".zig-cache");
    const triple = target.result.zigTriple(b.allocator) catch @panic("cannot format build target");
    const command = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        step_name,
        "--build-file",
        build_file,
        "--cache-dir",
        cache_dir,
        "-p",
        b.install_path,
        b.fmt("-Drepository-root={s}", .{repository_root}),
        b.fmt("-Dproduct-scope={s}", .{scope}),
        b.fmt("-Dtarget={s}", .{triple}),
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Daggregate-metal={s}", .{if (options.aggregate_metal) "true" else "false"}),
        b.fmt("-Driscv-release-phase={s}", .{options.riscv_release_phase}),
        b.fmt("-Driscv-evidence-dir={s}", .{options.riscv_evidence_dir}),
    });
    if (options.implementation_commit) |value|
        command.addArg(b.fmt("-Dimplementation-commit={s}", .{value}));
    if (options.implementation_dirty) |value|
        command.addArg(b.fmt("-Dimplementation-dirty={s}", .{if (value) "true" else "false"}));
    return command;
}
