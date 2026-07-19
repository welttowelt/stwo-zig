//! Stable descriptor for the opt-in aggregate compatibility CLI.

const graph = @import("../graph/modules.zig");
const policy = @import("../graph/product.zig");

const source_closure = policy.SourceClosure{
    .entry_roots = &.{
        "src/tools/prove/main.zig",
        "src/stwo.zig",
        "src/prover/native/runner.zig",
    },
    .named_imports = &.{
        .{ .name = "stwo", .source = "src/stwo.zig" },
        .{ .name = "stwo_backend_contracts", .source = "src/backend/mod.zig" },
        .{ .name = "stwo_core", .source = "src/core/mod.zig" },
        .{ .name = "stwo_prover_impl", .source = "src/prover/mod.zig" },
        .{ .name = "native_proof_runner", .source = "src/prover/native/runner.zig" },
        .{ .name = "native_transaction", .source = "src/integrations/native/transaction.zig" },
        .{ .name = "native_product_identity", .source = "src/integrations/native/product_identity.zig" },
        .{ .name = "native_cpu_capabilities", .source = "src/products/native_cpu/capabilities.zig" },
        .{ .name = "riscv_cpu_capabilities", .source = "src/products/riscv_cpu/capabilities.zig" },
        .{ .name = "starkv_adapter", .source = "src/integrations/riscv_cpu/proof_adapter.zig" },
    },
    .generated_imports = &.{"aggregate_capabilities"},
    .allowed_files = &.{
        "src/stwo.zig",
        "src/products/native_cpu/capabilities.zig",
        "src/products/riscv_cpu/capabilities.zig",
    },
    .allowed_prefixes = &.{
        "src/backend",
        "src/backends",
        "src/core",
        "src/examples",
        "src/frontends",
        "src/integrations",
        "src/interop",
        "src/prover",
        "src/std_shims",
        "src/tools/metal_session",
        "src/tools/prove",
        "src/tracing",
    },
    .forbidden_dynamic_dependencies = &.{
        "Metal.framework",
        "Foundation.framework",
        "libobjc",
        "cuda",
    },
};

pub const descriptor = policy.Descriptor{
    .product = product(false),
    .state = .released,
    .target_support = .any,
    .build_step = "stwo-zig",
    .test_step = "test",
    .executable = "stwo-zig",
    .installed_artifacts = &.{"stwo-zig"},
    .release_gates = &.{ "test", "vectors", "interop" },
    .dependencies = .{ .module_roots = source_closure.entry_roots },
    .source_closure = source_closure,
};

pub fn product(metal: bool) graph.Product {
    return .{
        .name = "stwo-zig",
        .frontend = .aggregate,
        .backend = if (metal) .metal else .cpu,
        .role = .cli,
        .protocol_features = if (metal)
            "aggregate-compat-v1+cpu+metal"
        else
            "aggregate-compat-v1+cpu",
    };
}

pub fn descriptorFor(metal: bool) policy.Descriptor {
    var result = descriptor;
    result.product = product(metal);
    if (metal) {
        var closure = source_closure;
        closure.required_dynamic_dependencies = &.{
            "Metal.framework",
            "Foundation.framework",
            "libobjc",
        };
        closure.forbidden_dynamic_dependencies = &.{"cuda"};
        result.source_closure = closure;
    }
    return result;
}
