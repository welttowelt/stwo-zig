//! Coefficient-form polynomial commitment orchestration.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const prover_circle = @import("../poly/circle/mod.zig");
const circle_transforms = @import("columns/circle_transforms.zig");
const column_storage = @import("columns/storage.zig");
const commit_dispatch = @import("commit_dispatch.zig");

pub fn commit(
    comptime B: type,
    comptime H: type,
    comptime BackendCommitmentTree: type,
    self: anytype,
    allocator: std.mem.Allocator,
    polys: []const prover_circle.CircleCoefficients,
    channel: anytype,
) !void {
    const blowup = self.config.fri_config.log_blowup_factor;
    if (try commit_dispatch.tryPrecommittedPolys(
        B,
        H,
        allocator,
        polys,
        blowup,
        self.coefficient_retention_policy,
        &self.twiddle_source,
    )) |committed| {
        var tree = committed;
        errdefer tree.deinit(allocator);
        return self.appendCommittedTree(allocator, tree, channel);
    }
    const columns = try circle_transforms.extendCoefficientColumnsByGroupForBackend(
        B,
        allocator,
        polys,
        blowup,
        &self.twiddle_source,
    );
    errdefer column_storage.freeOwnedColumnEvaluations(allocator, columns);

    var stored_coefficients: ?[]prover_circle.CircleCoefficients = null;
    if (column_storage.shouldRetainPolynomialCoefficients(polys, self.coefficient_retention_policy)) {
        const coeffs = try allocator.alloc(prover_circle.CircleCoefficients, polys.len);
        errdefer allocator.free(coeffs);
        var initialized_coeffs: usize = 0;
        errdefer {
            for (coeffs[0..initialized_coeffs]) |*coeff| coeff.deinit(allocator);
            allocator.free(coeffs);
        }
        for (polys, 0..) |poly, index| {
            coeffs[index] = try prover_circle.CircleCoefficients.initOwned(
                try allocator.dupe(M31, poly.coefficients()),
            );
            initialized_coeffs += 1;
        }
        stored_coefficients = coeffs;
    }

    var tree = try BackendCommitmentTree.initOwnedWithCoefficients(
        allocator,
        columns,
        stored_coefficients,
    );
    errdefer tree.deinit(allocator);
    try self.appendCommittedTree(allocator, tree, channel);
}
