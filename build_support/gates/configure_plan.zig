const std = @import("std");
const configure_manifest = @import("../graph/configure_manifest.zig");
const matrix = @import("../products/matrix.zig");

pub const Scope = enum {
    aggregate,
    architecture,
    compatibility_tools,
    core,
    deferred,
    metal_tools,
    native_cpu,
    native_metal,
    package,
    policy,
    prover,
    release,
    riscv_cpu,
    riscv_cpu_compat,
    verification,
};

pub fn add(b: *std.Build, scope: Scope) void {
    const inputs: configure_manifest.Inputs = switch (scope) {
        .aggregate => fromCatalog(b, "aggregate"),
        .architecture => gate(
            b,
            "architecture",
            &.{"python3"},
            &.{ "gates/architecture_receipts.addGates", "gates/baseline.addGate" },
        ),
        .core => fromCatalog(b, "core"),
        .prover => fromCatalog(b, "prover"),
        .native_cpu => fromCatalog(b, "native_cpu"),
        .native_metal => fromCatalog(b, "native_metal"),
        .riscv_cpu => fromCatalog(b, "riscv_cpu"),
        .riscv_cpu_compat => .{
            .b = b,
            .scope = "riscv_cpu_compat",
            .product_ids = fromCatalog(b, "riscv_cpu").product_ids,
            .module_roots = fromCatalog(b, "riscv_cpu").module_roots,
            .external_tools = fromCatalog(b, "riscv_cpu").external_tools,
            .runtime_probes = fromCatalog(b, "riscv_cpu").runtime_probes,
            .constructors = &.{ "products/matrix.construct.riscv_cpu", "compatibility aliases" },
        },
        .package => .{
            .b = b,
            .scope = "package",
            .product_ids = &.{ "stwo-core", "stwo-prover", "stwo" },
            .module_roots = &.{ "src/core/mod.zig", "src/products/prover/root.zig", "src/stwo.zig" },
            .external_tools = &.{"python3"},
            .constructors = &.{"products/libraries.addProducts"},
        },
        .metal_tools => .{
            .b = b,
            .scope = "metal_tools",
            .product_ids = &.{"stwo-native-metal-tools"},
            .module_roots = &.{ "src/stwo.zig", "src/backends/metal/shader_manifest.zig" },
            .external_tools = &.{ "xcrun", "metal", "metallib" },
            .runtime_probes = &.{ "Metal.framework", "Foundation.framework", "libobjc" },
            .constructors = &.{
                "backends/metal_aot.addProducts",
                "benchmarks/metal.addProducts",
            },
        },
        .compatibility_tools => .{
            .b = b,
            .scope = "compatibility_tools",
            .product_ids = &.{"stwo-compatibility-tools"},
            .module_roots = &.{
                "src/tools/interop/main.zig",
                "src/tools/cairo/input_inspector.zig",
                "src/tools/riscv_opcode_manifest/main.zig",
                "src/riscv_bench_cli.zig",
                "src/tools/native_proof_bench/cpu.zig",
            },
            .constructors = &.{"products/compatibility_tools.addProducts"},
        },
        .deferred => .{
            .b = b,
            .scope = "deferred",
            .product_ids = matrix.productIdsForScope(b, "deferred"),
            .module_roots = &.{},
            .constructors = &.{"products/matrix.addDeferredProducts"},
        },
        .verification => gate(
            b,
            "verification",
            &.{ "python3", "zig" },
            &.{
                "gates/riscv.addGates",
                "gates/native.addGates",
                "benchmarks/native.addProducts",
                "gates/release_evidence.addGates",
            },
        ),
        .policy => gate(
            b,
            "policy",
            &.{ "python3", "zig" },
            &.{"internal_build.addPolicyGates"},
        ),
        .release => .{
            .b = b,
            .scope = "release",
            .product_ids = &.{"stwo-zig-release"},
            .module_roots = &.{},
            .external_tools = &.{ "python3", "zig" },
            .constructors = &.{"gates/release.addGates"},
        },
    };
    configure_manifest.add(inputs);
}

fn gate(
    b: *std.Build,
    scope: []const u8,
    external_tools: []const []const u8,
    constructors: []const []const u8,
) configure_manifest.Inputs {
    return .{
        .b = b,
        .scope = scope,
        .product_ids = &.{},
        .module_roots = &.{},
        .external_tools = external_tools,
        .constructors = constructors,
    };
}

fn fromProduct(
    b: *std.Build,
    scope: []const u8,
    descriptor: @import("../graph/product.zig").Descriptor,
    constructor: []const u8,
) configure_manifest.Inputs {
    const product_ids = b.allocator.alloc([]const u8, 1) catch @panic("out of memory");
    product_ids[0] = descriptor.product.name;
    const constructors = b.allocator.alloc([]const u8, 1) catch @panic("out of memory");
    constructors[0] = constructor;
    return .{
        .b = b,
        .scope = scope,
        .product_ids = product_ids,
        .module_roots = descriptor.dependencies.module_roots,
        .external_tools = descriptor.dependencies.external_dependencies,
        .constructors = constructors,
    };
}

fn fromCatalog(b: *std.Build, scope: []const u8) configure_manifest.Inputs {
    const spec = matrix.findByScope(scope) orelse
        std.debug.panic("configure scope absent from product catalog: {s}", .{scope});
    const constructor = b.fmt("products/matrix.construct.{s}", .{@tagName(spec.constructor)});
    var inputs = fromProduct(b, scope, spec.descriptor, constructor);
    inputs.external_tools = spec.configure_tools;
    inputs.runtime_probes = spec.runtime_probes;
    if (spec.constructor == .aggregate) inputs.constructors = &.{
        "products/matrix.construct.aggregate",
        "products/matrix.addIdentity",
    };
    return inputs;
}
