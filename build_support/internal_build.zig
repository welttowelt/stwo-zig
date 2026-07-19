//! Internal entry point for one delegated product graph.

const std = @import("std");
const build_identity = @import("build_identity.zig");
const architecture_receipts = @import("gates/architecture_receipts.zig");
const baseline = @import("gates/baseline.zig");
const graph = @import("graph/modules.zig");
const metal_core_aot = @import("metal_core_aot.zig");
const metal_products = @import("metal_products.zig");
const verification = @import("verification_products.zig");
const aggregate = @import("products/aggregate_cli.zig");
const core = @import("products/core.zig");
const deferred = @import("products/matrix.zig");
const native_cpu = @import("products/native_cpu.zig");
const native_metal = @import("products/native_metal.zig");
const prover = @import("products/prover.zig");
const riscv_cpu = @import("products/riscv_cpu.zig");

const Scope = enum {
    aggregate,
    architecture,
    core,
    deferred,
    metal_tools,
    native_cpu,
    native_metal,
    policy,
    prover,
    riscv_cpu,
    verification,
};

pub fn build(b: *std.Build) void {
    const repository_root = b.option(
        []const u8,
        "repository-root",
        "Absolute stwo-zig repository root",
    ) orelse @panic("missing internal -Drepository-root");
    setRepositoryRoot(b, repository_root);

    const scope_name = b.option(
        []const u8,
        "product-scope",
        "Internal focused product scope",
    ) orelse @panic("missing internal -Dproduct-scope");
    const scope = std.meta.stringToEnum(Scope, scope_name) orelse
        std.debug.panic("unknown internal product scope: {s}", .{scope_name});

    if (scope == .aggregate) {
        aggregate.addProduct(b);
        return;
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = SharedOptions.read(b);
    switch (scope) {
        .aggregate => unreachable,
        .architecture => {
            architecture_receipts.addGates(b);
            baseline.addGate(b);
        },
        .core => _ = core.addProduct(.{
            .b = b,
            .target = target,
            .optimize = optimize,
        }),
        .prover => {
            const core_result = core.addProduct(.{
                .b = b,
                .target = target,
                .optimize = optimize,
            });
            _ = prover.addProduct(.{
                .b = b,
                .target = target,
                .optimize = optimize,
                .core = core_result.module,
            });
        },
        .native_cpu => native_cpu.addProduct(.{
            .b = b,
            .target = target,
            .optimize = optimize,
            .identity = resolveIdentity(b, repository_root, shared),
            .protocol = graph.createPrivateProtocolModules(b, target, optimize),
        }),
        .native_metal => native_metal.addProduct(.{
            .b = b,
            .target = target,
            .optimize = optimize,
            .identity = resolveIdentity(b, repository_root, shared),
            .protocol = graph.createPrivateProtocolModules(b, target, optimize),
        }),
        .riscv_cpu => riscv_cpu.addProduct(.{
            .b = b,
            .target = target,
            .optimize = optimize,
            .identity = resolveIdentity(b, repository_root, shared),
            .protocol = graph.createPrivateProtocolModules(b, target, optimize),
        }),
        .metal_tools => addMetalTools(b, target, optimize),
        .deferred => {
            deferred.addDeferredProducts(b, target);
            const cuda_test = b.step(
                "cuda-test",
                "Unavailable compatibility alias; CUDA now requires an explicit product toolchain",
            );
            cuda_test.dependOn(&b.addFail(
                "cuda-test is unavailable: select an explicit CUDA product with complete library and runtime paths",
            ).step);
        },
        .verification => verification.addProducts(.{
            .b = b,
            .zig_optimize_arg = b.fmt("-O{s}", .{@tagName(optimize)}),
            .riscv_release_phase = shared.riscv_release_phase,
            .riscv_evidence_dir = shared.riscv_evidence_dir,
        }),
        .policy => addPolicyGates(b),
    }
}

fn setRepositoryRoot(b: *std.Build, repository_root: []const u8) void {
    b.build_root = .{
        .path = repository_root,
        .handle = std.fs.openDirAbsolute(repository_root, .{}) catch
            @panic("invalid internal repository root"),
    };
}

const SharedOptions = struct {
    riscv_release_phase: []const u8,
    riscv_evidence_dir: []const u8,
    implementation_commit: ?[]const u8,
    implementation_dirty: ?bool,

    fn read(b: *std.Build) SharedOptions {
        _ = b.option(bool, "aggregate-metal", "Explicit aggregate Metal linkage");
        return .{
            .riscv_release_phase = b.option([]const u8, "riscv-release-phase", "CP-13 phase: candidate or promoted") orelse "candidate",
            .riscv_evidence_dir = b.option([]const u8, "riscv-evidence-dir", "Fresh CP-13 evidence directory") orelse "zig-out/release-evidence/riscv",
            .implementation_commit = b.option([]const u8, "implementation-commit", "Exact lowercase 40-hex source commit embedded in the product"),
            .implementation_dirty = b.option(bool, "implementation-dirty", "Whether the source embedded in the product has local modifications"),
        };
    }
};

fn resolveIdentity(
    b: *std.Build,
    repository_root: []const u8,
    shared: SharedOptions,
) build_identity.Identity {
    return build_identity.resolve(
        b.allocator,
        repository_root,
        shared.implementation_commit,
        shared.implementation_dirty,
    ) catch |err| std.debug.panic("cannot resolve product build identity: {s}", .{@errorName(err)});
}

fn addMetalTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const protocol = graph.createPrivateProtocolModules(b, target, optimize);
    const stwo = graph.create(b, .{
        .product = .{
            .name = "stwo-native-metal-tools",
            .frontend = .native,
            .backend = .metal,
            .role = .library,
        },
        .root_source_file = "src/stwo.zig",
        .target = target,
        .optimize = optimize,
    });
    protocol.addImports(stwo);
    const shader_manifest = graph.create(b, .{
        .product = .{
            .name = "stwo-native-metal-tools",
            .frontend = .native,
            .backend = .metal,
            .role = .library,
        },
        .root_source_file = "src/backends/metal/shader_manifest.zig",
        .target = target,
        .optimize = optimize,
    });
    protocol.addImports(shader_manifest);
    const internal_tests = b.addSystemCommand(&.{"true"});
    metal_core_aot.addProducts(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .shader_manifest_module = shader_manifest,
        .test_step = &internal_tests.step,
    });
    metal_products.addProducts(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .stwo_module = stwo,
        .protocol = protocol,
        .test_step = null,
    });
}

fn addPolicyGates(b: *std.Build) void {
    inline for (.{
        .{ "fmt", "Check formatting (zig fmt --check)", &.{ "zig", "fmt", "--check", "build.zig", "src", "tools" } },
        .{ "api-parity", "Validate API parity ledger coverage", &.{ "python3", "scripts/check_api_parity.py" } },
        .{ "upstream-pins", "Validate Native and Cairo pin carriers against the upstream ledger", &.{ "python3", "scripts/check_upstream_pins.py" } },
        .{ "source-conformance", "Reject new source layout, dependency direction, and file-size violations", &.{ "python3", "scripts/check_source_conformance.py" } },
        .{ "upstream-surface", "Validate API parity rust_path entries against pinned upstream commit", &.{ "python3", "scripts/check_upstream_surface.py" } },
    }) |gate| {
        const command = b.addSystemCommand(gate[2]);
        b.step(gate[0], gate[1]).dependOn(&command.step);
    }
    const closure = b.addSystemCommand(&.{
        "python3",
        "scripts/check_build_configure_closure.py",
    });
    b.step(
        "build-configure-closure",
        "Verify focused configure closure and the default install manifest",
    ).dependOn(&closure.step);
}
