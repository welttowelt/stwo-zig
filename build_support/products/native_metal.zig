//! Build ownership for Native example AIRs on the Metal backend.

const std = @import("std");
const metal = @import("../backends/metal.zig");
const build_identity = @import("../build_identity.zig");
const graph_identity = @import("../graph/identity.zig");
const graph_install = @import("../graph/install.zig");
const graph = @import("../graph/modules.zig");
const product_policy = @import("../graph/product.zig");

const protocol_features = "native-examples-v1+lifted-pcs-v1+metal-runtime-v1";

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    identity: build_identity.Identity,
    protocol: graph.ProtocolModules,
};

pub fn descriptor(role: graph.Role) product_policy.Descriptor {
    return .{
        .product = product(role),
        .state = .parity_gated,
        .target_support = .macos,
        .unsupported_target_reason = "the Metal backend requires a macOS target and Apple Metal SDK",
        .build_step = "stwo-native-metal",
        .test_step = "test-native-metal",
        .executable = "stwo-zig-native-metal",
        .installed_artifacts = &.{"stwo-zig-native-metal"},
        .compatibility_aliases = &.{"native-proof-bench-metal"},
        .release_gates = &.{ "metal-test", "metal-core-aot-acceptance" },
        .benchmark_step = "native-proof-bench-metal",
        .profiler_step = "native-proof-profile",
        .dependencies = .{
            .module_roots = &.{
                "src/products/native_metal/main.zig",
                "src/stwo_native_metal.zig",
                "src/prover/native/runner.zig",
                metal.runtime_source,
                metal.shader_manifest_source,
            },
            .external_dependencies = &.{ "Foundation.framework", "Metal.framework", "libobjc" },
        },
    };
}

pub fn addProduct(context: Context) void {
    const policy = descriptor(.cli);
    policy.validate() catch |err| std.debug.panic(
        "invalid Native Metal descriptor: {s}",
        .{@errorName(err)},
    );
    if (!policy.isAvailableOn(context.target.result.os.tag)) {
        product_policy.registerUnavailable(context.b, policy, context.target.result.os.tag);
        return;
    }

    const stwo = createStwoModule(context, .library);
    const runner = createRunnerModule(context, stwo, .library);
    const root = createProductModule(context, policy.product, stwo, runner);
    const installed = graph_install.executable(
        context.b,
        policy.executable.?,
        root,
        policy.build_step,
        "Build the focused Native Metal proof CLI",
    );
    metal.linkRuntime(context.b, installed.executable);

    const compatibility_root = createProductModule(context, product(.benchmark), stwo, runner);
    const compatibility = graph_install.executable(
        context.b,
        "native-proof-bench-metal",
        compatibility_root,
        policy.benchmark_step.?,
        "Build the compatible machine-readable Native Metal proof benchmark",
    );
    metal.linkRuntime(context.b, compatibility.executable);

    const tests = context.b.addTest(.{
        .root_module = createProductModule(context, product(.@"test"), stwo, runner),
    });
    metal.linkRuntime(context.b, tests);
    const facade_tests = context.b.addTest(.{
        .root_module = createStwoModule(context, .@"test"),
    });
    metal.linkRuntime(context.b, facade_tests);
    const runner_test_stwo = createStwoModule(context, .@"test");
    const runner_tests = context.b.addTest(.{
        .root_module = createRunnerModule(context, runner_test_stwo, .@"test"),
    });
    metal.linkRuntime(context.b, runner_tests);
    const test_step = context.b.step(
        policy.test_step.?,
        "Test Native Metal ownership, linkage, and visible capabilities",
    );
    test_step.dependOn(&context.b.addRunArtifact(tests).step);
    test_step.dependOn(&context.b.addRunArtifact(facade_tests).step);
    test_step.dependOn(&context.b.addRunArtifact(runner_tests).step);
    const policy_tests = context.b.addTest(.{
        .root_module = context.b.createModule(.{
            .root_source_file = context.b.path("build_support/product_policy_test.zig"),
            .target = context.target,
            .optimize = context.optimize,
        }),
    });
    test_step.dependOn(&context.b.addRunArtifact(policy_tests).step);

    const help = context.b.addRunArtifact(installed.executable);
    help.addArg("--help");
    test_step.dependOn(&help.step);
    const applications = context.b.addRunArtifact(installed.executable);
    applications.addArg("applications");
    test_step.dependOn(&applications.step);

    const closure_check = context.b.addSystemCommand(&.{
        "python3",
        "scripts/check_native_metal_product.py",
    });
    closure_check.addArg("--binary");
    closure_check.addArtifactArg(installed.executable);
    test_step.dependOn(&closure_check.step);
}

fn createStwoModule(context: Context, role: graph.Role) *std.Build.Module {
    const module = graph.create(context.b, .{
        .product = product(role),
        .root_source_file = "src/stwo_native_metal.zig",
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
    logical_product: graph.Product,
    stwo: *std.Build.Module,
    runner: *std.Build.Module,
) *std.Build.Module {
    const root = graph.create(context.b, .{
        .product = logical_product,
        .root_source_file = "src/products/native_metal/main.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    context.protocol.addImports(root);
    root.addImport("stwo", stwo);
    root.addImport("stwo_native_metal", stwo);
    root.addImport("native_proof_runner", runner);
    root.addOptions("build_identity", graph_identity.buildOptions(context.b, context.identity));
    root.addOptions(
        "product_identity",
        graph_identity.productOptions(
            context.b,
            context.identity,
            logical_product,
            context.target,
            context.optimize,
        ),
    );
    return root;
}

fn product(role: graph.Role) graph.Product {
    return .{
        .name = "stwo-native-metal",
        .frontend = .native,
        .backend = .metal,
        .role = role,
        .protocol_features = protocol_features,
    };
}

test "descriptor binds runtime identity and explicit target policy" {
    const policy = descriptor(.cli);
    try policy.validate();
    try std.testing.expectEqual(product_policy.State.parity_gated, policy.state);
    try std.testing.expectEqualStrings("stwo-zig-native-metal", policy.executable.?);
    try std.testing.expect(std.mem.indexOf(u8, policy.product.protocol_features, "metal-runtime-v1") != null);
    try std.testing.expectEqualStrings("source-jit+authenticated-aot", metal.runtime_modes);
}
