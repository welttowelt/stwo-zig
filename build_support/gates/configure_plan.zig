const std = @import("std");
const configure_manifest = @import("../graph/configure_manifest.zig");
const product = @import("../graph/product.zig");
const aggregate = @import("../products/aggregate.zig");
const core = @import("../products/core.zig");
const native_cpu = @import("../products/native_cpu.zig");
const native_metal = @import("../products/native_metal.zig");
const prover = @import("../products/prover.zig");
const riscv_cpu = @import("../products/riscv_cpu.zig");

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
        .aggregate => .{
            .b = b,
            .scope = "aggregate",
            .product_ids = &.{"stwo-zig"},
            .module_roots = aggregate.descriptor.dependencies.module_roots,
            .constructors = &.{
                "products/aggregate_cli.addProduct",
                "products/matrix.addIdentity",
            },
        },
        .architecture => gate(
            b,
            "architecture",
            &.{"python3"},
            &.{ "gates/architecture_receipts.addGates", "gates/baseline.addGate" },
        ),
        .core => fromProduct(b, "core", core.descriptor, "products/core.addProduct"),
        .prover => fromProduct(b, "prover", prover.descriptor, "products/prover.addProduct"),
        .native_cpu => fromProduct(
            b,
            "native_cpu",
            native_cpu.descriptor(.cli),
            "products/native_cpu.addProduct",
        ),
        .native_metal => .{
            .b = b,
            .scope = "native_metal",
            .product_ids = &.{"stwo-native-metal"},
            .module_roots = native_metal.descriptor(.cli).dependencies.module_roots,
            .external_tools = &.{"xcrun"},
            .runtime_probes = &.{ "Metal.framework", "Foundation.framework", "libobjc" },
            .constructors = &.{"products/native_metal.addProduct"},
        },
        .riscv_cpu => fromProduct(
            b,
            "riscv_cpu",
            riscv_cpu.descriptor,
            "products/riscv_cpu.addProduct",
        ),
        .riscv_cpu_compat => .{
            .b = b,
            .scope = "riscv_cpu_compat",
            .product_ids = &.{"stwo-riscv-cpu"},
            .module_roots = riscv_cpu.descriptor.dependencies.module_roots,
            .constructors = &.{ "products/riscv_cpu.addProduct", "compatibility aliases" },
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
            .product_ids = &.{
                "stwo-cairo-cpu",
                "stwo-cairo-metal",
                "stwo-riscv-metal",
                "stwo-native-cuda",
                "stwo-cairo-cuda",
                "stwo-riscv-cuda",
            },
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
            &.{ "python3", "zig fmt" },
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
    descriptor: product.Descriptor,
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
