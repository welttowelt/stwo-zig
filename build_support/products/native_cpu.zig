//! Build ownership for Native example AIRs on CPU scalar/SIMD.

const std = @import("std");
const build_identity = @import("../build_identity.zig");
const graph_identity = @import("../graph/identity.zig");
const graph_install = @import("../graph/install.zig");
const graph = @import("../graph/modules.zig");

const protocol_features = "native-examples-v1+lifted-pcs-v1";

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    identity: build_identity.Identity,
    protocol: graph.ProtocolModules,
};

pub fn addProduct(context: Context) void {
    const cli_product = product(.cli);
    const stwo = createStwoModule(context, .library);
    const runner = createRunnerModule(context, stwo, .library);
    const root = createProductModule(context, cli_product, stwo, runner, "src/native_cpu_product.zig");
    const installed = graph_install.executable(
        context.b,
        "stwo-zig-native-cpu",
        root,
        "stwo-native-cpu",
        "Build the focused Native CPU/SIMD proof CLI",
    );

    const benchmark_product = product(.benchmark);
    const benchmark_root = createProductModule(
        context,
        benchmark_product,
        stwo,
        runner,
        "src/products/native_cpu/benchmark.zig",
    );
    _ = graph_install.executable(
        context.b,
        "stwo-zig-native-cpu-bench",
        benchmark_root,
        "benchmark-native-cpu",
        "Build the focused Native CPU/SIMD benchmark",
    );

    const tests = addProductTests(context);
    const facade_tests = context.b.addTest(.{
        .root_module = createStwoModule(context, .@"test"),
    });
    const runner_test_stwo = createStwoModule(context, .@"test");
    const runner_tests = context.b.addTest(.{
        .root_module = createRunnerModule(context, runner_test_stwo, .@"test"),
    });
    const test_step = context.b.step(
        "test-native-cpu-product",
        "Test Native CPU product behavior, imports, and visible capabilities",
    );
    test_step.dependOn(&context.b.addRunArtifact(tests).step);
    test_step.dependOn(&context.b.addRunArtifact(facade_tests).step);
    test_step.dependOn(&context.b.addRunArtifact(runner_tests).step);

    const help = context.b.addRunArtifact(installed.executable);
    help.addArg("--help");
    test_step.dependOn(&help.step);
    const applications = context.b.addRunArtifact(installed.executable);
    applications.addArg("applications");
    test_step.dependOn(&applications.step);

    const closure_check = context.b.addSystemCommand(&.{
        "python3",
        "scripts/check_native_cpu_product.py",
    });
    closure_check.addArg("--binary");
    closure_check.addArtifactArg(installed.executable);
    test_step.dependOn(&closure_check.step);
}

fn addProductTests(context: Context) *std.Build.Step.Compile {
    const stwo = createStwoModule(context, .@"test");
    const runner = createRunnerModule(context, stwo, .@"test");
    const root = createProductModule(
        context,
        product(.@"test"),
        stwo,
        runner,
        "src/native_cpu_product.zig",
    );
    return context.b.addTest(.{ .root_module = root });
}

fn createStwoModule(context: Context, role: graph.Role) *std.Build.Module {
    const module = graph.create(context.b, .{
        .product = product(role),
        .root_source_file = "src/stwo_native_cpu.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    context.protocol.addImports(module);
    return module;
}

fn createRunnerModule(
    context: Context,
    stwo: *std.Build.Module,
    role: graph.Role,
) *std.Build.Module {
    const runner = graph.create(context.b, .{
        .product = product(role),
        .root_source_file = "src/prover/native/runner.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    context.protocol.addImports(runner);
    runner.addImport("stwo", stwo);
    return runner;
}

fn createProductModule(
    context: Context,
    descriptor: graph.Product,
    stwo: *std.Build.Module,
    runner: *std.Build.Module,
    root_source_file: []const u8,
) *std.Build.Module {
    const root = graph.create(context.b, .{
        .product = descriptor,
        .root_source_file = root_source_file,
        .target = context.target,
        .optimize = context.optimize,
    });
    context.protocol.addImports(root);
    root.addImport("stwo", stwo);
    root.addImport("stwo_native_cpu", stwo);
    root.addImport("native_proof_runner", runner);
    root.addOptions("build_identity", graph_identity.buildOptions(context.b, context.identity));
    root.addOptions(
        "product_identity",
        graph_identity.productOptions(
            context.b,
            context.identity,
            descriptor,
            context.target,
            context.optimize,
        ),
    );
    return root;
}

fn product(role: graph.Role) graph.Product {
    return .{
        .name = "stwo-native-cpu",
        .frontend = .native,
        .backend = .cpu,
        .role = role,
        .protocol_features = protocol_features,
    };
}
