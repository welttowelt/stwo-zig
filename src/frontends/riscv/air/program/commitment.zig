//! Oracle-exact sparse program commitment rows.

const std = @import("std");
const M31 = @import("../../../../core/fields/m31.zig").M31;
const infra = @import("../../infra_trace.zig");
const memory_state = @import("../../runner/memory_state.zig");
const sparse_merkle = @import("../memory_commitment/sparse_merkle.zig");
const decode = @import("decode.zig");
const table = @import("table.zig");

pub const N_MAIN_COLUMNS: usize = 8;

pub const Row = struct {
    addr: u32,
    values: decode.ProgramValues,
    multiplicity: u32,
    root: u32,
};

pub const Commitment = struct {
    rows: []Row,
    tree: sparse_merkle.Tree,

    pub fn deinit(self: *Commitment, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.tree.deinit(allocator);
        self.* = undefined;
    }

    pub fn validate(self: Commitment, allocator: std.mem.Allocator) !void {
        try self.tree.validate(allocator);
        if (self.rows.len * 4 != self.tree.leaves.len) return error.InvalidProgramCommitment;
        for (self.rows, 0..) |row, index| {
            if (row.root != self.tree.root) return error.InvalidProgramCommitment;
            for (row.values, 0..) |value, limb| {
                const leaf = self.tree.leaves[4 * index + limb];
                if (leaf.index != row.addr + limb or leaf.value != value)
                    return error.InvalidProgramCommitment;
            }
        }
    }
};

pub const Columns = struct {
    values: [N_MAIN_COLUMNS][]M31,

    pub fn deinit(self: *Columns, allocator: std.mem.Allocator) void {
        for (&self.values) |column| allocator.free(column);
        self.* = undefined;
    }
};

/// Prefer the declared program-memory union. The fetch-only fallback exists
/// for synthetic proof tests that do not execute through the ELF loader.
pub fn build(
    allocator: std.mem.Allocator,
    fetches: []const table.Fetch,
    program_words: []const memory_state.WordState,
) !Commitment {
    var fetch_table = try table.generate(allocator, fetches);
    defer fetch_table.deinit();
    var fetch_by_addr = std.AutoHashMap(u32, table.Row).init(allocator);
    defer fetch_by_addr.deinit();
    for (fetch_table.rows) |row| try fetch_by_addr.put(row.pc, row);

    var pending: std.ArrayList(Row) = .{};
    defer pending.deinit(allocator);
    if (program_words.len != 0) {
        for (program_words) |word| {
            if ((word.addr & 3) != 0) return error.MisalignedProgramWord;
            const values = try decode.decodeProgramWord(word.initial_word);
            const multiplicity = if (fetch_by_addr.fetchRemove(word.addr)) |entry| blk: {
                if (!std.meta.eql(entry.value.values, values)) return error.ProgramWordChanged;
                break :blk entry.value.multiplicity;
            } else 0;
            try pending.append(allocator, .{
                .addr = word.addr,
                .values = values,
                .multiplicity = multiplicity,
                .root = 0,
            });
        }
        if (fetch_by_addr.count() != 0) return error.FetchedProgramWordMissing;
    } else {
        for (fetch_table.rows) |row| try pending.append(allocator, .{
            .addr = row.pc,
            .values = row.values,
            .multiplicity = row.multiplicity,
            .root = 0,
        });
    }
    if (pending.items.len == 0) return error.EmptyProgramCommitment;
    std.mem.sort(Row, pending.items, {}, lessRow);

    var leaves: std.ArrayList(sparse_merkle.Leaf) = .{};
    defer leaves.deinit(allocator);
    for (pending.items) |row| {
        for (row.values, 0..) |value, limb| try leaves.append(allocator, .{
            .index = row.addr + @as(u32, @intCast(limb)),
            .value = value,
        });
    }
    var tree = try sparse_merkle.build(allocator, leaves.items);
    errdefer tree.deinit(allocator);
    for (pending.items) |*row| row.root = tree.root;
    const result = Commitment{
        .rows = try pending.toOwnedSlice(allocator),
        .tree = tree,
    };
    try result.validate(allocator);
    return result;
}

pub fn generateMain(
    allocator: std.mem.Allocator,
    rows: []const Row,
    log_size: u32,
) !Columns {
    const size = @as(usize, 1) << @intCast(log_size);
    if (rows.len > size) return error.InvalidTraceShape;
    var columns: [N_MAIN_COLUMNS][]M31 = undefined;
    var initialized: usize = 0;
    errdefer for (columns[0..initialized]) |column| allocator.free(column);
    for (&columns) |*column| {
        column.* = try allocator.alloc(M31, size);
        @memset(column.*, M31.zero());
        initialized += 1;
    }
    const placement = try infra.BitReversalTable.init(allocator, log_size);
    defer placement.deinit(allocator);
    for (rows, 0..) |row, index| {
        const dst = placement.map(index);
        columns[0][dst] = M31.one();
        columns[1][dst] = M31.fromU64(row.addr);
        for (row.values, 0..) |value, limb| columns[2 + limb][dst] = M31.fromU64(value);
        columns[6][dst] = M31.fromU64(row.multiplicity);
        columns[7][dst] = M31.fromU64(row.root);
    }
    return .{ .values = columns };
}

fn lessRow(_: void, lhs: Row, rhs: Row) bool {
    return lhs.addr < rhs.addr;
}

test "program commitment: declared but unfetched instructions remain root-bound" {
    const words = [_]memory_state.WordState{
        .{ .addr = 0x1000, .initial_word = 0x00100093, .final_word = 0x00100093, .final_clock = 0 },
        .{ .addr = 0x1004, .initial_word = 0x002081b3, .final_word = 0x002081b3, .final_clock = 0 },
    };
    const fetches = [_]table.Fetch{.{ .pc = 0x1000, .word = 0x00100093 }};
    var commitment = try build(std.testing.allocator, &fetches, &words);
    defer commitment.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), commitment.rows.len);
    try std.testing.expectEqual(@as(u32, 1), commitment.rows[0].multiplicity);
    try std.testing.expectEqual(@as(u32, 0), commitment.rows[1].multiplicity);
    try std.testing.expectEqual(commitment.tree.root, commitment.rows[1].root);
}

test "program commitment: fetched word must belong to declared program" {
    const words = [_]memory_state.WordState{
        .{ .addr = 0x1000, .initial_word = 0x00100093, .final_word = 0x00100093, .final_clock = 0 },
    };
    const fetches = [_]table.Fetch{.{ .pc = 0x1004, .word = 0x002081b3 }};
    try std.testing.expectError(
        error.FetchedProgramWordMissing,
        build(std.testing.allocator, &fetches, &words),
    );
}
