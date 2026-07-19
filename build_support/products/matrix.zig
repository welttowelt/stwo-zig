//! Authoritative accelerated and deferred composition matrix.

const std = @import("std");
const product_policy = @import("../graph/product.zig");
const cairo_cpu = @import("cairo_cpu.zig");
const cairo_metal = @import("cairo_metal.zig");
const riscv_metal = @import("riscv_metal.zig");
const native_cuda = @import("native_cuda.zig");
const native_metal = @import("native_metal.zig");
const cairo_cuda = @import("cairo_cuda.zig");
const riscv_cuda = @import("riscv_cuda.zig");

pub const descriptors = [_]product_policy.Descriptor{
    native_metal.descriptor(.cli),
    cairo_cpu.descriptor,
    cairo_metal.descriptor,
    riscv_metal.descriptor,
    native_cuda.descriptor,
    cairo_cuda.descriptor,
    riscv_cuda.descriptor,
};

pub fn find(name: []const u8) ?product_policy.Descriptor {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.product.name, name)) return descriptor;
    }
    return null;
}

pub fn addDeferredProducts(b: *std.Build, target: std.Build.ResolvedTarget) void {
    inline for (descriptors) |descriptor| {
        if (!descriptor.isConstructible())
            product_policy.registerUnavailable(b, descriptor, target.result.os.tag);
    }
}
