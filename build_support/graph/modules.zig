//! Typed product declarations and focused Zig module construction.

const std = @import("std");

pub const Frontend = enum { none, native, riscv, cairo, aggregate };
pub const Backend = enum { none, cpu, metal, cuda };
pub const Role = enum { library, cli, benchmark, @"test", gate };

pub const Product = struct {
    name: []const u8,
    frontend: Frontend,
    backend: Backend,
    role: Role,
    protocol_features: []const u8 = "default",

    pub fn validate(self: Product) !void {
        if (self.name.len == 0 or self.protocol_features.len == 0)
            return error.InvalidProductIdentity;
        switch (self.role) {
            .cli, .benchmark, .gate => {
                if (self.frontend == .none or self.backend == .none)
                    return error.IncompleteProductCapabilities;
            },
            .library, .@"test" => {},
        }
        if (self.frontend == .aggregate and self.role == .library)
            return error.InvalidAggregateLibrary;
    }

    pub fn frontendManifest(self: Product) []const u8 {
        return switch (self.frontend) {
            .none => "none",
            .native => "native-examples",
            .riscv => "stark-v-rv32im",
            .cairo => "cairo",
            .aggregate => "aggregate",
        };
    }

    pub fn backendManifest(self: Product) []const u8 {
        return @tagName(self.backend);
    }
};

pub const ModuleSpec = struct {
    product: Product,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn create(b: *std.Build, spec: ModuleSpec) *std.Build.Module {
    spec.product.validate() catch |err| std.debug.panic(
        "invalid build product {s}: {s}",
        .{ spec.product.name, @errorName(err) },
    );
    return b.createModule(.{
        .root_source_file = b.path(spec.root_source_file),
        .target = spec.target,
        .optimize = spec.optimize,
    });
}

test "executable products require explicit capabilities" {
    try std.testing.expectError(error.IncompleteProductCapabilities, (Product{
        .name = "invalid",
        .frontend = .native,
        .backend = .none,
        .role = .cli,
    }).validate());
    try (Product{
        .name = "stwo-native-cpu",
        .frontend = .native,
        .backend = .cpu,
        .role = .cli,
    }).validate();
}

test "capability manifests have stable public names" {
    const riscv = Product{
        .name = "stwo-riscv-cpu",
        .frontend = .riscv,
        .backend = .cpu,
        .role = .gate,
    };
    try std.testing.expectEqualStrings("stark-v-rv32im", riscv.frontendManifest());
    try std.testing.expectEqualStrings("cpu", riscv.backendManifest());
}
