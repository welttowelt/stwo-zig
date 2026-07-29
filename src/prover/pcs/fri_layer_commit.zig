//! Inner-FRI coordinate materialization and Merkle commitment dispatch.

const std = @import("std");
const m31 = @import("stwo_core").fields.m31;
const secure_column = @import("../secure_column.zig");

const M31 = m31.M31;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;

pub fn Result(comptime B: type, comptime H: type) type {
    return struct {
        column: SecureColumnByCoords,
        tree: B.MerkleTree(H),
    };
}

pub fn materializeAndCommit(
    comptime B: type,
    comptime H: type,
    allocator: std.mem.Allocator,
    evaluation: anytype,
    pending_column: *?SecureColumnByCoords,
    pending_tree: *?B.MerkleTree(H),
) !Result(B, H) {
    if (pending_column.* == null and pending_tree.* == null and
        comptime @hasDecl(B, "materializeSecureColumnAndCommit"))
    {
        const fused = try B.materializeSecureColumnAndCommit(
            H,
            allocator,
            evaluation,
        );
        return .{ .column = fused.column, .tree = fused.tree };
    }

    const column_was_pending = pending_column.* != null;
    var column = pending_column.* orelse if (comptime @hasDecl(B, "secureColumnForMerkle"))
        try B.secureColumnForMerkle(allocator, evaluation)
    else if (comptime @hasDecl(B, "secureColumnFromLine"))
        try B.secureColumnFromLine(evaluation)
    else
        try secure_column.SecureColumnByCoords.fromSecureSlice(
            allocator,
            evaluation.values,
        );
    errdefer if (!column_was_pending) column.deinit(allocator);

    const coordinate_refs = [_][]const M31{
        column.columns[0],
        column.columns[1],
        column.columns[2],
        column.columns[3],
    };
    const tree = pending_tree.* orelse
        try B.commitMerkle(H, allocator, coordinate_refs[0..]);
    pending_column.* = null;
    pending_tree.* = null;
    return .{ .column = column, .tree = tree };
}
