//! Build ownership for the focused Stark-V RV32IM + CPU/SIMD product.

const std = @import("std");
const build_identity = @import("../build_identity.zig");
const graph_identity = @import("../graph/identity.zig");
const graph = @import("../graph/modules.zig");

const product = graph.Product{
    .name = "stwo-zig-riscv-cpu",
    .frontend = .riscv,
    .backend = .cpu,
    .role = .cli,
    .protocol_features = "stark-v-rv32im+logup-v1",
};

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    identity: build_identity.Identity,
};

pub fn addProduct(context: Context) void {
    const host = addExecutable(
        context,
        context.target,
        context.optimize,
        "stwo-zig-riscv-cpu",
    );
    const install_host = context.b.addInstallArtifact(host, .{});
    const host_trace = addTraceExecutable(context, context.target, context.optimize);
    const install_host_trace = context.b.addInstallArtifact(host_trace, .{});
    context.b.getInstallStep().dependOn(&install_host_trace.step);
    const trace_step = context.b.step("riscv-trace-dump", "Build RISC-V trace dumper CLI");
    trace_step.dependOn(&install_host_trace.step);
    const host_step = context.b.step(
        "stwo-zig-riscv-cpu",
        "Build the focused Stark-V RV32IM CPU/SIMD proof CLI",
    );
    host_step.dependOn(&install_host.step);
    host_step.dependOn(&install_host_trace.step);

    const static_target = context.b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const static = addExecutable(
        context,
        static_target,
        .ReleaseFast,
        "stwo-zig-riscv-cpu-x86_64-linux-musl",
    );
    static.linkage = .static;
    const install_static = context.b.addInstallArtifact(static, .{});
    const static_trace = addTraceExecutable(context, static_target, .ReleaseFast);
    static_trace.linkage = .static;
    const install_static_trace = context.b.addInstallArtifact(static_trace, .{});
    const static_step = context.b.step(
        "stwo-zig-riscv-cpu-static",
        "Build the static x86_64-linux-musl RISC-V CPU challenge executable",
    );
    static_step.dependOn(&install_static.step);
    static_step.dependOn(&install_static_trace.step);

    const tests = addTests(context);
    const test_step = context.b.step(
        "test-riscv-cpu-product",
        "Test the focused RISC-V CPU product shell and capability surface",
    );
    test_step.dependOn(&context.b.addRunArtifact(tests).step);

    const closure_check = context.b.addSystemCommand(&.{
        "python3",
        "scripts/check_riscv_cpu_product.py",
    });
    test_step.dependOn(&closure_check.step);
}

fn addTraceExecutable(
    context: Context,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const b = context.b;
    const root = graph.create(b, .{
        .product = product,
        .root_source_file = "src/riscv_trace_cli.zig",
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_identity", graph_identity.buildOptions(b, context.identity));
    return b.addExecutable(.{ .name = "riscv-trace-dump", .root_module = root });
}

fn addExecutable(
    context: Context,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const b = context.b;
    const stwo = createStwoModule(b, target, optimize);
    const root = graph.create(b, .{
        .product = product,
        .root_source_file = "src/riscv_cpu_product.zig",
        .target = target,
        .optimize = optimize,
    });
    root.addImport("stwo", stwo);
    root.addImport("stwo_riscv_cpu", stwo);
    root.addOptions("build_identity", graph_identity.buildOptions(b, context.identity));
    root.addOptions(
        "product_identity",
        graph_identity.productOptions(b, context.identity, product, target, optimize),
    );
    return b.addExecutable(.{ .name = name, .root_module = root });
}

fn addTests(context: Context) *std.Build.Step.Compile {
    const b = context.b;
    const stwo = createStwoModule(b, context.target, context.optimize);
    const test_product = graph.Product{
        .name = product.name,
        .frontend = product.frontend,
        .backend = product.backend,
        .role = .@"test",
        .protocol_features = product.protocol_features,
    };
    const root = graph.create(b, .{
        .product = test_product,
        .root_source_file = "src/riscv_cpu_product.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    root.addImport("stwo", stwo);
    root.addImport("stwo_riscv_cpu", stwo);
    root.addOptions("build_identity", graph_identity.buildOptions(b, context.identity));
    root.addOptions(
        "product_identity",
        graph_identity.productOptions(
            b,
            context.identity,
            test_product,
            context.target,
            context.optimize,
        ),
    );
    return b.addTest(.{ .root_module = root });
}

fn createStwoModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return graph.create(b, .{
        .product = .{
            .name = product.name,
            .frontend = product.frontend,
            .backend = product.backend,
            .role = .library,
            .protocol_features = product.protocol_features,
        },
        .root_source_file = "src/stwo_riscv_cpu.zig",
        .target = target,
        .optimize = optimize,
    });
}
