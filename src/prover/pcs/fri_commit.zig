const std = @import("std");
const m31 = @import("stwo_core").fields.m31;
const secure_column = @import("../secure_column.zig");

const M31 = m31.M31;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;

fn CommitResult(comptime B: type, comptime H: type) type {
    return struct {
        column: SecureColumnByCoords,
        tree: B.MerkleTree(H),
    };
}

pub fn commitSecureValues(
    comptime B: type,
    comptime H: type,
    allocator: std.mem.Allocator,
    evaluation: anytype,
) !CommitResult(B, H) {
    var column = if (comptime @hasDecl(B, "secureColumnForMerkle"))
        try B.secureColumnForMerkle(allocator, evaluation)
    else if (comptime @hasDecl(B, "secureColumnFromLine"))
        try B.secureColumnFromLine(evaluation)
    else
        try SecureColumnByCoords.fromSecureSlice(allocator, evaluation.values);
    errdefer column.deinit(allocator);

    const coord_refs = [_][]const M31{
        column.columns[0],
        column.columns[1],
        column.columns[2],
        column.columns[3],
    };
    return .{
        .column = column,
        .tree = try B.commitMerkle(H, allocator, coord_refs[0..]),
    };
}
