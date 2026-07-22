//! Borrowed trace views and query-position geometry for a PCS scheme.

const std = @import("std");
const pcs = @import("stwo_core").pcs;
const pcs_utils = pcs.utils;
const verifier_types = @import("stwo_core").verifier_types;
const component_prover = @import("../air/component_prover.zig");
const prover_circle = @import("../poly/circle/mod.zig");

const TreeVec = pcs.TreeVec;

pub fn roots(comptime H: type, scheme: anytype, allocator: std.mem.Allocator) !TreeVec(H.Hash) {
    const out = try allocator.alloc(H.Hash, scheme.trees.items.len);
    for (scheme.trees.items, 0..) |tree, index| out[index] = tree.root();
    return TreeVec(H.Hash).initOwned(out);
}

pub fn polynomials(scheme: anytype, allocator: std.mem.Allocator) !TreeVec([]const component_prover.Poly) {
    const out = try allocator.alloc([]const component_prover.Poly, scheme.trees.items.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |tree_polys| allocator.free(tree_polys);

    for (scheme.trees.items, 0..) |tree, tree_index| {
        const polys = try allocator.alloc(component_prover.Poly, tree.columns.len);
        out[tree_index] = polys;
        initialized += 1;
        for (tree.columns, 0..) |column, column_index| {
            polys[column_index] = .{
                .log_size = column.log_size,
                .values = column.values,
                .coefficients = if (tree.coefficients) |coefficients|
                    try prover_circle.CircleCoefficients.initBorrowed(
                        coefficients[column_index].coefficients(),
                    )
                else
                    null,
            };
        }
    }
    return TreeVec([]const component_prover.Poly).initOwned(out);
}

pub fn trace(scheme: anytype, allocator: std.mem.Allocator) !component_prover.Trace {
    return .{ .polys = try polynomials(scheme, allocator) };
}

pub fn columnLogSizes(scheme: anytype, allocator: std.mem.Allocator) !TreeVec([]u32) {
    const out = try allocator.alloc([]u32, scheme.trees.items.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |tree_sizes| allocator.free(tree_sizes);
    for (scheme.trees.items, 0..) |tree, index| {
        out[index] = try tree.columnLogSizes(allocator);
        initialized += 1;
    }
    return TreeVec([]u32).initOwned(out);
}

pub fn buildQueryPositionsTree(
    scheme: anytype,
    allocator: std.mem.Allocator,
    query_positions: []const usize,
    lifting_log_size: u32,
) !TreeVec([]usize) {
    const out = try allocator.alloc([]usize, scheme.trees.items.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |positions| allocator.free(positions);

    const preprocessed_index = verifier_types.PREPROCESSED_TRACE_IDX;
    if (scheme.trees.items.len <= preprocessed_index) return error.InvalidPreprocessedTree;
    var preprocessed_log_size: u32 = 0;
    for (scheme.trees.items[preprocessed_index].columns) |column|
        preprocessed_log_size = @max(preprocessed_log_size, column.log_size);
    const preprocessed_positions = try pcs_utils.preparePreprocessedQueryPositions(
        allocator,
        query_positions,
        lifting_log_size,
        preprocessed_log_size,
    );
    defer allocator.free(preprocessed_positions);

    for (0..scheme.trees.items.len) |tree_index| {
        out[tree_index] = try allocator.dupe(
            usize,
            if (tree_index == preprocessed_index) preprocessed_positions else query_positions,
        );
        initialized += 1;
    }
    return TreeVec([]usize).initOwned(out);
}
