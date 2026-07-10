const std = @import("std");
const m31 = @import("../fields/m31.zig");
const vcs_hash = @import("../vcs/hash.zig");
const lifted_merkle_hasher = @import("merkle_hasher.zig");

const M31 = m31.M31;

pub const MerkleVerificationError = error{
    WitnessTooShort,
    WitnessTooLong,
    RootMismatch,
    InvalidQueryShape,
    DuplicateQueryMismatch,
};

pub fn MerkleDecommitmentLifted(comptime H: type) type {
    return struct {
        hash_witness: []H.Hash,

        const Self = @This();

        pub fn empty(allocator: std.mem.Allocator) !Self {
            return .{ .hash_witness = try allocator.alloc(H.Hash, 0) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.hash_witness);
            self.* = undefined;
        }
    };
}

pub fn MerkleDecommitmentLiftedAux(comptime H: type) type {
    return struct {
        all_node_values: [][]NodeValue,

        pub const NodeValue = struct {
            index: usize,
            hash: H.Hash,
        };

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.all_node_values) |layer_values| allocator.free(layer_values);
            allocator.free(self.all_node_values);
            self.* = undefined;
        }
    };
}

pub fn ExtendedMerkleDecommitmentLifted(comptime H: type) type {
    return struct {
        decommitment: MerkleDecommitmentLifted(H),
        aux: MerkleDecommitmentLiftedAux(H),

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.decommitment.deinit(allocator);
            self.aux.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub fn MerkleVerifierLifted(comptime H: type) type {
    comptime lifted_merkle_hasher.assertMerkleHasherLifted(H);
    return struct {
        root: H.Hash,
        column_log_sizes: []u32,

        const Self = @This();
        const Decommitment = MerkleDecommitmentLifted(H);

        pub fn init(
            allocator: std.mem.Allocator,
            root: H.Hash,
            column_log_sizes: []const u32,
        ) !Self {
            return .{
                .root = root,
                .column_log_sizes = try allocator.dupe(u32, column_log_sizes),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.column_log_sizes);
            self.* = undefined;
        }

        /// `queried_values` is indexed by column, then query index.
        pub fn verify(
            self: Self,
            allocator: std.mem.Allocator,
            query_positions: []const usize,
            queried_values: []const []const M31,
            decommitment: Decommitment,
        ) (std.mem.Allocator.Error || MerkleVerificationError)!void {
            if (self.column_log_sizes.len == 0) return;

            for (queried_values) |column| {
                if (column.len != query_positions.len) return MerkleVerificationError.InvalidQueryShape;
            }

            const QueryOrder = struct {
                positions: []const usize,

                fn lessThan(context: @This(), lhs: usize, rhs: usize) bool {
                    const lhs_position = context.positions[lhs];
                    const rhs_position = context.positions[rhs];
                    return lhs_position < rhs_position or
                        (lhs_position == rhs_position and lhs < rhs);
                }
            };
            const query_order = try allocator.alloc(usize, query_positions.len);
            defer allocator.free(query_order);
            for (query_order, 0..) |*index, j| index.* = j;
            std.sort.heap(
                usize,
                query_order,
                QueryOrder{ .positions = query_positions },
                QueryOrder.lessThan,
            );

            var unique_positions = std.ArrayList(usize).empty;
            defer unique_positions.deinit(allocator);
            for (query_order) |original_index| {
                const position = query_positions[original_index];
                if (unique_positions.items.len == 0 or
                    unique_positions.items[unique_positions.items.len - 1] != position)
                {
                    try unique_positions.append(allocator, position);
                }
            }

            // Sort columns by log size.
            const n_cols = queried_values.len;
            const col_indices = try allocator.alloc(usize, n_cols);
            defer allocator.free(col_indices);
            for (col_indices, 0..) |*idx, j| idx.* = j;
            std.sort.heap(usize, col_indices, self.column_log_sizes, lessByLogSize);

            // Sort query values into Merkle order and deduplicate folded
            // positions. The proof keeps its original order for FRI answers.
            var dedup_cols = try allocator.alloc([]M31, n_cols);
            defer {
                for (dedup_cols) |col| allocator.free(col);
                allocator.free(dedup_cols);
            }
            for (col_indices, 0..) |col_idx, j| {
                const col = queried_values[col_idx];
                var dedup = std.ArrayList(M31).empty;
                defer dedup.deinit(allocator);
                for (query_order, 0..) |original_index, sorted_index| {
                    const position = query_positions[original_index];
                    if (sorted_index == 0 or position != query_positions[query_order[sorted_index - 1]]) {
                        try dedup.append(allocator, col[original_index]);
                    } else if (!dedup.items[dedup.items.len - 1].eql(col[original_index])) {
                        return MerkleVerificationError.DuplicateQueryMismatch;
                    }
                }
                dedup_cols[j] = try dedup.toOwnedSlice(allocator);
            }

            const Pair = struct { idx: usize, hash: H.Hash };
            var prev_layer = std.ArrayList(Pair).empty;
            defer prev_layer.deinit(allocator);

            var col_pos = try allocator.alloc(usize, n_cols);
            defer allocator.free(col_pos);
            @memset(col_pos, 0);

            for (unique_positions.items) |pos| {
                var row = std.ArrayList(M31).empty;
                defer row.deinit(allocator);
                for (dedup_cols, 0..) |col, col_i| {
                    if (col_pos[col_i] >= col.len) return MerkleVerificationError.WitnessTooShort;
                    try row.append(allocator, col[col_pos[col_i]]);
                    col_pos[col_i] += 1;
                }
                var hasher = H.defaultWithInitialState();
                hasher.updateLeaf(row.items);
                try prev_layer.append(allocator, .{ .idx = pos, .hash = hasher.finalize() });
            }

            // Verify all dedup values were consumed.
            for (dedup_cols, 0..) |col, col_i| {
                if (col_pos[col_i] != col.len) return MerkleVerificationError.WitnessTooLong;
            }

            var witness_idx: usize = 0;
            const max_log_size = maxLogSize(self.column_log_sizes);
            var layer: u32 = 0;
            while (layer < max_log_size) : (layer += 1) {
                var curr = std.ArrayList(Pair).empty;
                defer curr.deinit(allocator);

                var p: usize = 0;
                while (p < prev_layer.items.len) {
                    const first = prev_layer.items[p];
                    var chunk_len: usize = 1;
                    var left_hash: H.Hash = undefined;
                    var right_hash: H.Hash = undefined;
                    if (p + 1 < prev_layer.items.len and (first.idx ^ 1) == prev_layer.items[p + 1].idx) {
                        const second = prev_layer.items[p + 1];
                        left_hash = first.hash;
                        right_hash = second.hash;
                        chunk_len = 2;
                    } else {
                        if (witness_idx >= decommitment.hash_witness.len) {
                            return MerkleVerificationError.WitnessTooShort;
                        }
                        const witness = decommitment.hash_witness[witness_idx];
                        witness_idx += 1;
                        if ((first.idx & 1) == 0) {
                            left_hash = first.hash;
                            right_hash = witness;
                        } else {
                            left_hash = witness;
                            right_hash = first.hash;
                        }
                    }
                    try curr.append(allocator, .{
                        .idx = first.idx >> 1,
                        .hash = H.hashChildren(.{ .left = left_hash, .right = right_hash }),
                    });
                    p += chunk_len;
                }

                prev_layer.clearRetainingCapacity();
                try prev_layer.appendSlice(allocator, curr.items);
            }

            if (witness_idx != decommitment.hash_witness.len) {
                return MerkleVerificationError.WitnessTooLong;
            }
            if (prev_layer.items.len != 1) return MerkleVerificationError.RootMismatch;
            if (!vcs_hash.eql(prev_layer.items[0].hash, self.root)) {
                return MerkleVerificationError.RootMismatch;
            }
        }
    };
}

fn lessByLogSize(log_sizes: []const u32, lhs: usize, rhs: usize) bool {
    const lhs_size = log_sizes[lhs];
    const rhs_size = log_sizes[rhs];
    if (lhs_size == rhs_size) return lhs < rhs;
    return lhs_size < rhs_size;
}

fn maxLogSize(values: []const u32) u32 {
    var max_value: u32 = 0;
    for (values) |v| max_value = @max(max_value, v);
    return max_value;
}

test "vcs_lifted verifier: verifies simple proof" {
    const Hasher = @import("blake2_merkle.zig").Blake2sMerkleHasher;
    const Decommitment = MerkleDecommitmentLifted(Hasher);
    const Verifier = MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const query_positions = [_]usize{ 1, 3 };
    const queried_values = [_][]const M31{
        &[_]M31{ M31.fromCanonical(10), M31.fromCanonical(30) },
        &[_]M31{ M31.fromCanonical(20), M31.fromCanonical(40) },
    };

    // Build leaf hashes.
    var row0 = [_]M31{ queried_values[0][0], queried_values[1][0] };
    var row1 = [_]M31{ queried_values[0][1], queried_values[1][1] };
    var h0s = Hasher.defaultWithInitialState();
    h0s.updateLeaf(row0[0..]);
    const h0 = h0s.finalize();
    var h1s = Hasher.defaultWithInitialState();
    h1s.updateLeaf(row1[0..]);
    const h1 = h1s.finalize();

    // Sibling witnesses for positions 1 and 3.
    var leaf0s = Hasher.defaultWithInitialState();
    leaf0s.updateLeaf(&[_]M31{ M31.fromCanonical(9), M31.fromCanonical(19) });
    const leaf0 = leaf0s.finalize();
    var leaf2s = Hasher.defaultWithInitialState();
    leaf2s.updateLeaf(&[_]M31{ M31.fromCanonical(29), M31.fromCanonical(39) });
    const leaf2 = leaf2s.finalize();

    const parent0 = Hasher.hashChildren(.{ .left = leaf0, .right = h0 });
    const parent1 = Hasher.hashChildren(.{ .left = leaf2, .right = h1 });
    const root = Hasher.hashChildren(.{ .left = parent0, .right = parent1 });

    var verifier = try Verifier.init(alloc, root, &[_]u32{ 2, 2 });
    defer verifier.deinit(alloc);

    var decommitment = Decommitment{ .hash_witness = try alloc.dupe(Hasher.Hash, &[_]Hasher.Hash{ leaf0, leaf2 }) };
    defer decommitment.deinit(alloc);

    try verifier.verify(alloc, query_positions[0..], queried_values[0..], decommitment);
}
