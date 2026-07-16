//! Backend-neutral lifted Merkle decommitment traversal.
//!
//! A tree reader owns storage and must expose only its maximum log size and
//! selective hash reads. Host layers and device-resident trees therefore share
//! one proof-construction algorithm without erased handles or callbacks here.

const std = @import("std");
const m31 = @import("../../core/fields/m31.zig");
const vcs_lifted_verifier = @import("../../core/vcs_lifted/verifier.zig");

const M31 = m31.M31;

pub fn DecommitmentResult(comptime H: type) type {
    return struct {
        queried_values: [][]M31,
        decommitment: vcs_lifted_verifier.ExtendedMerkleDecommitmentLifted(H),

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.queried_values) |column| allocator.free(column);
            allocator.free(self.queried_values);
            self.decommitment.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub fn decommit(
    comptime H: type,
    reader: anytype,
    allocator: std.mem.Allocator,
    query_positions: []const usize,
    columns: []const []const M31,
) !DecommitmentResult(H) {
    comptime assertReader(@TypeOf(reader));

    const NodeValue = vcs_lifted_verifier.MerkleDecommitmentLiftedAux(H).NodeValue;
    const Decommitment = vcs_lifted_verifier.MerkleDecommitmentLifted(H);
    const max_log_size = reader.maxLogSize();

    const queried_values = try allocator.alloc([]M31, columns.len);
    var queried_values_initialized: usize = 0;
    errdefer {
        for (queried_values[0..queried_values_initialized]) |column| allocator.free(column);
        allocator.free(queried_values);
    }

    for (columns, 0..) |column, i| {
        if (!std.math.isPowerOfTwo(column.len) or column.len < 2) {
            return error.InvalidColumnSize;
        }
        const log_size: u32 = @intCast(std.math.log2_int(usize, column.len));
        if (log_size > max_log_size) return error.InvalidColumnSize;
        const shift = max_log_size - log_size;
        const shift_amt: std.math.Log2Int(usize) = @intCast(shift + 1);

        queried_values[i] = try allocator.alloc(M31, query_positions.len);
        queried_values_initialized += 1;
        for (query_positions, 0..) |position, j| {
            const column_index = ((position >> shift_amt) << 1) + (position & 1);
            queried_values[i][j] = column[column_index];
        }
    }

    var hash_witness = std.ArrayList(H.Hash).empty;
    defer hash_witness.deinit(allocator);

    var all_node_values = std.ArrayList([]NodeValue).empty;
    defer {
        for (all_node_values.items) |layer| allocator.free(layer);
        all_node_values.deinit(allocator);
    }

    var previous_queries = std.ArrayList(usize).empty;
    defer previous_queries.deinit(allocator);
    for (query_positions, 0..) |position, i| {
        if (i == 0 or query_positions[i - 1] != position) {
            try previous_queries.append(allocator, position);
        }
    }

    var layer_log_size: i64 = @intCast(max_log_size);
    layer_log_size -= 1;
    while (layer_log_size >= 0) : (layer_log_size -= 1) {
        var current_queries = std.ArrayList(usize).empty;
        defer current_queries.deinit(allocator);

        var layer_node_values = std.ArrayList(NodeValue).empty;
        defer layer_node_values.deinit(allocator);

        const child_indices = try allocator.alloc(u32, previous_queries.items.len * 2);
        defer allocator.free(child_indices);
        var child_pair_count: usize = 0;
        var scan: usize = 0;
        while (scan < previous_queries.items.len) {
            const first = previous_queries.items[scan];
            const has_sibling = scan + 1 < previous_queries.items.len and
                ((first ^ 1) == previous_queries.items[scan + 1]);
            const current_index = first >> 1;
            child_indices[2 * child_pair_count] = @intCast(2 * current_index);
            child_indices[2 * child_pair_count + 1] = @intCast(2 * current_index + 1);
            child_pair_count += 1;
            scan += if (has_sibling) 2 else 1;
        }
        const child_hashes = try reader.readHashes(
            allocator,
            @intCast(layer_log_size + 1),
            child_indices[0 .. child_pair_count * 2],
        );
        defer allocator.free(child_hashes);

        var query_at: usize = 0;
        var pair_index: usize = 0;
        while (query_at < previous_queries.items.len) {
            const first = previous_queries.items[query_at];
            const has_sibling = query_at + 1 < previous_queries.items.len and
                ((first ^ 1) == previous_queries.items[query_at + 1]);

            if (!has_sibling) {
                const sibling_offset: usize = if ((first & 1) == 0) 1 else 0;
                try hash_witness.append(allocator, child_hashes[2 * pair_index + sibling_offset]);
            }

            const current_index = first >> 1;
            try current_queries.append(allocator, current_index);
            try layer_node_values.append(allocator, .{
                .index = 2 * current_index,
                .hash = child_hashes[2 * pair_index],
            });
            try layer_node_values.append(allocator, .{
                .index = 2 * current_index + 1,
                .hash = child_hashes[2 * pair_index + 1],
            });
            query_at += if (has_sibling) 2 else 1;
            pair_index += 1;
        }

        previous_queries.clearRetainingCapacity();
        try previous_queries.appendSlice(allocator, current_queries.items);
        try all_node_values.append(allocator, try layer_node_values.toOwnedSlice(allocator));
    }

    const hash_witness_owned = try hash_witness.toOwnedSlice(allocator);
    errdefer allocator.free(hash_witness_owned);

    const all_node_values_owned = try all_node_values.toOwnedSlice(allocator);
    errdefer {
        for (all_node_values_owned) |layer| allocator.free(layer);
        allocator.free(all_node_values_owned);
    }

    return .{
        .queried_values = queried_values,
        .decommitment = .{
            .decommitment = Decommitment{ .hash_witness = hash_witness_owned },
            .aux = .{ .all_node_values = all_node_values_owned },
        },
    };
}

fn assertReader(comptime Reader: type) void {
    if (!@hasDecl(Reader, "maxLogSize")) {
        @compileError("Merkle tree reader must declare `maxLogSize`.");
    }
    if (!@hasDecl(Reader, "readHashes")) {
        @compileError("Merkle tree reader must declare `readHashes`.");
    }
}
