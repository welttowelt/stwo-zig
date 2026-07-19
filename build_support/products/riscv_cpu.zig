//! Build ownership for the focused Stark-V RV32IM + CPU/SIMD product.

const std = @import("std");
const build_identity = @import("../build_identity.zig");

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
    const root = b.createModule(.{
        .root_source_file = b.path("src/riscv_trace_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_identity", buildIdentityOptions(b, context.identity));
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
    const root = b.createModule(.{
        .root_source_file = b.path("src/riscv_cpu_product.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("stwo", stwo);
    root.addImport("stwo_riscv_cpu", stwo);
    root.addOptions("build_identity", buildIdentityOptions(b, context.identity));
    root.addOptions("product_identity", productIdentityOptions(b, target, optimize));
    return b.addExecutable(.{ .name = name, .root_module = root });
}

fn addTests(context: Context) *std.Build.Step.Compile {
    const b = context.b;
    const stwo = createStwoModule(b, context.target, context.optimize);
    const root = b.createModule(.{
        .root_source_file = b.path("src/riscv_cpu_product.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    root.addImport("stwo", stwo);
    root.addImport("stwo_riscv_cpu", stwo);
    root.addOptions("build_identity", buildIdentityOptions(b, context.identity));
    root.addOptions(
        "product_identity",
        productIdentityOptions(b, context.target, context.optimize),
    );
    return b.addTest(.{ .root_module = root });
}

fn createStwoModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/stwo_riscv_cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn buildIdentityOptions(
    b: *std.Build,
    identity: build_identity.Identity,
) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "implementation_commit", &identity.implementation_commit);
    options.addOption(bool, "implementation_dirty", identity.implementation_dirty);
    return options;
}

fn productIdentityOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(u32, "schema_version", 1);
    options.addOption([]const u8, "product", "stwo-zig-riscv-cpu");
    options.addOption([]const u8, "frontend", "stark-v-rv32im");
    options.addOption([]const u8, "backend", "cpu");
    options.addOption([]const u8, "target_arch", @tagName(target.result.cpu.arch));
    options.addOption([]const u8, "target_os", @tagName(target.result.os.tag));
    options.addOption([]const u8, "target_abi", @tagName(target.result.abi));
    options.addOption([]const u8, "cpu_model", target.result.cpu.model.name);
    options.addOption([]const u8, "optimize", @tagName(optimize));
    return options;
}
