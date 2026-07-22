//! Large secure-composition transforms installed at Metal runtime startup.

const std = @import("std");
const m31 = @import("stwo_core").fields.m31;
const domain_mod = @import("stwo_core").poly.circle.domain;
const prover_poly = @import("stwo_prover_impl").poly;
const shared_runtime = @import("shared_runtime.zig");
const telemetry = @import("telemetry.zig");

const M31 = m31.M31;
const CircleDomain = domain_mod.CircleDomain;
const TwiddleTree = prover_poly.twiddles.TwiddleTree([]const M31);
const min_log_size: u32 = 19;

pub fn install() void {
    prover_poly.circle.secure_poly.installBackendCircleIfftHook(
        interpolateLargeSecureComposition,
        min_log_size,
    );
}

fn interpolateLargeSecureComposition(
    allocator: std.mem.Allocator,
    values: []const []M31,
    domain: CircleDomain,
    twiddle_tree: TwiddleTree,
) !bool {
    if (domain.logSize() < min_log_size) return false;
    var lease = shared_runtime.acquireExisting() catch return false;
    defer lease.deinit();
    _ = try lease.runtime.transformCircle(
        allocator,
        values,
        twiddle_tree.itwiddles,
        domain.logSize(),
        true,
    );
    telemetry.record(.metal_circle_transform_dispatch);
    return true;
}
