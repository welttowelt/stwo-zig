//! Backend-scoped secure-composition dispatch for the Metal backend.

const std = @import("std");
const core = @import("stwo_core");
const prover = @import("stwo_prover_impl");
const secure_composition = @import("secure_composition.zig");

pub fn computeCompositionEvaluation(
    allocator: std.mem.Allocator,
    components: []const prover.air.component_prover.ComponentProver,
    random_coeff: core.fields.qm31.QM31,
    trace: *const prover.air.component_prover.Trace,
) !?prover.secure_column.SecureColumnByCoords {
    return secure_composition.evaluateLargeRecurrenceComposition(
        allocator,
        components,
        random_coeff,
        trace,
    );
}

pub fn interpolateSecureComposition(
    allocator: std.mem.Allocator,
    values: []const []core.fields.m31.M31,
    domain: core.poly.circle.domain.CircleDomain,
    twiddle_tree: prover.poly.twiddles.TwiddleTree([]const core.fields.m31.M31),
) !bool {
    return secure_composition.interpolateLargeSecureComposition(
        allocator,
        values,
        domain,
        twiddle_tree,
    );
}
