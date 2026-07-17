//! Authenticated runtime trace and FRI tree geometry.

const std = @import("std");

pub const Error = error{
    InvalidSchedule,
    InvalidCardinality,
    InvalidBindingSize,
};

pub const TraceTreeRole = enum(u32) {
    preprocessed = 0,
    base = 1,
    interaction = 2,
    composition = 3,
};

/// Runtime tree metadata authenticated by the compact proof bundle. Roles and
/// indices deliberately mirror `proof_bundle.TreeMeta`; schedule ordinals are
/// accepted only when they describe this exact geometry.
pub const TraceTreeGeometry = struct {
    role: TraceTreeRole,
    tree_index: u32,
    source_log: u32,
    tree_log: u32,
    leaf_log: u32,
    unretained: u32,
    column_count: u32,

    pub fn groupCount(self: TraceTreeGeometry) usize {
        return (@as(usize, self.column_count) + 15) / 16;
    }
};

pub const FriTreeGeometry = struct {
    role: u32,
    round: u32,
    tree_index: u32,
    leaf_log: u32,
};

pub const ProofDecommitGeometry = struct {
    trace_trees: []const TraceTreeGeometry,
    fri_trees: []const FriTreeGeometry,

    pub fn validate(self: ProofDecommitGeometry) Error!void {
        if (self.trace_trees.len == 0 or self.trace_trees.len > 4 or self.fri_trees.len == 0)
            return Error.InvalidCardinality;
        const tree_count = std.math.add(usize, self.trace_trees.len, self.fri_trees.len) catch
            return Error.InvalidCardinality;
        if (tree_count > (@as(usize, 1) << 16)) return Error.InvalidCardinality;

        for (self.trace_trees, 0..) |tree, tree_index| {
            if (tree.tree_index != tree_index or @intFromEnum(tree.role) != tree_index)
                return Error.InvalidSchedule;
            if (tree.source_log == 0 or tree.source_log > 31 or
                tree.tree_log == 0 or tree.tree_log > 31 or tree.leaf_log == 0 or tree.leaf_log > 31 or
                tree.tree_log < tree.leaf_log or tree.unretained == 0 or
                tree.unretained > tree.leaf_log or tree.column_count == 0 or
                tree.groupCount() > (@as(usize, 1) << 16))
                return Error.InvalidBindingSize;
        }
        for (self.fri_trees, 0..) |tree, round| {
            const tree_index = self.trace_trees.len + round;
            if (tree.round != round or tree.tree_index != tree_index or tree.role != tree_index)
                return Error.InvalidSchedule;
            if (tree.leaf_log == 0 or tree.leaf_log > 31 or
                (round != 0 and tree.leaf_log >= self.fri_trees[round - 1].leaf_log))
                return Error.InvalidBindingSize;
        }
    }

    pub fn traceGroupCount(self: ProofDecommitGeometry) Error!usize {
        try self.validate();
        var count: usize = 0;
        for (self.trace_trees) |tree| count = std.math.add(usize, count, tree.groupCount()) catch
            return Error.InvalidCardinality;
        return count;
    }

    pub fn friLayerCount(self: ProofDecommitGeometry) Error!usize {
        try self.validate();
        var count: usize = 0;
        for (self.fri_trees) |tree| count = std.math.add(usize, count, tree.leaf_log + 1) catch
            return Error.InvalidCardinality;
        return count;
    }
};
