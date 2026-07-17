//! Schedule JSON selection and binding-order reconstruction for Cairo proofs.

const std = @import("std");
const arena_plan = @import("../../backend/arena_plan.zig");
const fri_geometry = @import("../../core/fri/geometry.zig");

pub const Error = error{
    InvalidSchedule,
    DuplicateBinding,
    MissingBinding,
    InvalidCardinality,
    InvalidBindingSize,
};

pub const Sn2Counts = struct {
    pub const composition_coefficients = 8;
    pub const fri_challenges = 8;
    pub const fri_retained_evaluations = 7;
    pub const decommit_trace_trees = 4;
    pub const decommit_trace_groups = 370;
    pub const decommit_trace_coefficient_groups = 370;
    pub const decommit_fri_trees = 8;
    pub const decommit_trace_groups_by_tree = [decommit_trace_trees]usize{ 11, 216, 142, 1 };
    pub const decommit_trace_columns_by_tree = [decommit_trace_trees]u32{ 161, 3449, 2268, 8 };
};

pub const DecommitTraceCoefficientBindings = struct {
    pointers: arena_plan.Binding,
    sizes: arena_plan.Binding,
    lde_output_pointers: arena_plan.Binding,
};

/// One at-most-16-column trace group. Coefficient workspaces are absent for
/// groups whose evaluations remain resident and do not need decommit-time LDE.
pub const DecommitTraceGroupBindings = struct {
    tree_index: u32,
    group_index: u32,
    column_count: u32,
    evaluation_pointers: arena_plan.Binding,
    evaluation_logs: arena_plan.Binding,
    coefficients: ?DecommitTraceCoefficientBindings,
};

pub const DecommitTraceTreeBindings = struct {
    tree_index: u32,
    source_log: u32,
    tree_log: u32,
    leaf_log: u32,
    unretained: u32,
    column_count: u32,
    groups: []const DecommitTraceGroupBindings,
    retained_pointers: arena_plan.Binding,
    sparse_offsets: arena_plan.Binding,
};

pub const DecommitFriTreeBindings = struct {
    round: u32,
    tree_index: u32,
    leaf_log: u32,
    coordinate_pointers: arena_plan.Binding,
    retained_pointers: arena_plan.Binding,
};

pub const OwnedSn2DecommitBindings = struct {
    trace_groups: []DecommitTraceGroupBindings,
    trace_trees: [Sn2Counts.decommit_trace_trees]DecommitTraceTreeBindings,
    fri_trees: [Sn2Counts.decommit_fri_trees]DecommitFriTreeBindings,

    pub fn deinit(self: *OwnedSn2DecommitBindings, allocator: std.mem.Allocator) void {
        allocator.free(self.trace_groups);
        self.* = undefined;
    }
};

pub const OrdinalBinding = struct {
    ordinal: u32,
    binding: arena_plan.Binding,
};

pub const NamedBinding = struct {
    component: []const u8,
    ordinal: u32,
    binding: arena_plan.Binding,
};

pub const NamedGroupRange = struct { start: usize, len: usize };

const OrderedBinding = struct { ordinal: u32, binding: arena_plan.Binding };

pub fn purpose(entry: std.json.Value) ![]const u8 {
    if (entry != .object) return Error.InvalidSchedule;
    const value = entry.object.get("purpose") orelse return Error.InvalidSchedule;
    if (value != .string) return Error.InvalidSchedule;
    return value.string;
}

pub fn logicalId(entry: std.json.Value) !u32 {
    const value = entry.object.get("id") orelse return Error.InvalidSchedule;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32))
        return Error.InvalidSchedule;
    return @intCast(value.integer);
}

pub fn ordinal(entry: std.json.Value) !u32 {
    const value = entry.object.get("ordinal") orelse return 0;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32))
        return Error.InvalidSchedule;
    return @intCast(value.integer);
}

pub fn componentName(entry: std.json.Value) ![]const u8 {
    if (entry != .object) return Error.InvalidSchedule;
    const value = entry.object.get("component") orelse return Error.InvalidSchedule;
    if (value != .string or value.string.len == 0) return Error.InvalidSchedule;
    return value.string;
}

pub fn one(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

pub fn oneOrdinal(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    wanted_ordinal: u32,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            try ordinal(entry) != wanted_ordinal) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

pub fn oneComponent(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

pub fn oneComponentOrdinal(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
    wanted_ordinal: u32,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component) or
            try ordinal(entry) != wanted_ordinal) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

pub fn collect(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]arena_plan.Binding {
    var ordered = std.ArrayList(OrderedBinding).empty;
    defer ordered.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        try ordered.append(allocator, .{
            .ordinal = try ordinal(entry),
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (ordered.items.len == 0) return Error.MissingBinding;
    std.mem.sortUnstable(OrderedBinding, ordered.items, {}, struct {
        fn lessThan(_: void, lhs: OrderedBinding, rhs: OrderedBinding) bool {
            if (lhs.ordinal != rhs.ordinal) return lhs.ordinal < rhs.ordinal;
            return lhs.binding.logical_id < rhs.binding.logical_id;
        }
    }.lessThan);
    for (ordered.items[1..], ordered.items[0 .. ordered.items.len - 1]) |current, previous| {
        if (current.ordinal == previous.ordinal) return Error.DuplicateBinding;
    }
    const result = try allocator.alloc(arena_plan.Binding, ordered.items.len);
    for (ordered.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

pub fn collectOrdinals(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]OrdinalBinding {
    const bindings = try collect(allocator, schedule, plan, name);
    errdefer allocator.free(bindings);
    var ordinals = std.ArrayList(u32).empty;
    defer ordinals.deinit(allocator);
    for (schedule) |entry| if (std.mem.eql(u8, try purpose(entry), name))
        try ordinals.append(allocator, try ordinal(entry));
    std.mem.sortUnstable(u32, ordinals.items, {}, std.sort.asc(u32));
    if (ordinals.items.len != bindings.len) return Error.InvalidCardinality;
    const result = try allocator.alloc(OrdinalBinding, bindings.len);
    for (bindings, ordinals.items, result) |binding, binding_ordinal, *item|
        item.* = .{ .ordinal = binding_ordinal, .binding = binding };
    allocator.free(bindings);
    return result;
}

pub fn collectScheduleOrder(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]arena_plan.Binding {
    var result = std.ArrayList(arena_plan.Binding).empty;
    errdefer result.deinit(allocator);
    for (schedule) |entry| {
        if (std.mem.eql(u8, try purpose(entry), name))
            try result.append(allocator, plan.binding(try logicalId(entry)) catch return Error.MissingBinding);
    }
    if (result.items.len == 0) return Error.MissingBinding;
    return result.toOwnedSlice(allocator);
}

pub fn collectComponent(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
) ![]arena_plan.Binding {
    var ordered = std.ArrayList(OrderedBinding).empty;
    defer ordered.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        try ordered.append(allocator, .{
            .ordinal = try ordinal(entry),
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (ordered.items.len == 0) return Error.MissingBinding;
    std.mem.sortUnstable(OrderedBinding, ordered.items, {}, struct {
        fn lessThan(_: void, lhs: OrderedBinding, rhs: OrderedBinding) bool {
            return lhs.ordinal < rhs.ordinal;
        }
    }.lessThan);
    for (ordered.items, 0..) |item, index| if (item.ordinal != index)
        return Error.InvalidSchedule;
    const result = try allocator.alloc(arena_plan.Binding, ordered.items.len);
    for (ordered.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

pub fn collectComponentBindingGroups(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
) ![][]arena_plan.Binding {
    var groups = std.ArrayList([]arena_plan.Binding).empty;
    errdefer {
        for (groups.items) |group| allocator.free(group);
        groups.deinit(allocator);
    }
    var current = std.ArrayList(arena_plan.Binding).empty;
    defer current.deinit(allocator);
    var expected_ordinal: u32 = 0;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        const entry_ordinal = try ordinal(entry);
        if (entry_ordinal == 0 and current.items.len != 0) {
            try groups.append(allocator, try current.toOwnedSlice(allocator));
            expected_ordinal = 0;
        }
        if (entry_ordinal != expected_ordinal) return Error.InvalidSchedule;
        try current.append(
            allocator,
            plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        );
        expected_ordinal += 1;
    }
    if (current.items.len != 0) try groups.append(allocator, try current.toOwnedSlice(allocator));
    if (groups.items.len == 0) return Error.MissingBinding;
    return groups.toOwnedSlice(allocator);
}

/// Preserve capture order because component-instance column ordinals restart at zero.
pub fn collectNamed(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]NamedBinding {
    var result = std.ArrayList(NamedBinding).empty;
    errdefer result.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        try result.append(allocator, .{
            .component = try componentName(entry),
            .ordinal = try ordinal(entry),
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (result.items.len == 0) return Error.MissingBinding;
    return result.toOwnedSlice(allocator);
}

pub fn namedGroupRanges(
    allocator: std.mem.Allocator,
    items: []const NamedBinding,
) ![]NamedGroupRange {
    if (items.len == 0) return allocator.alloc(NamedGroupRange, 0);
    var groups = std.ArrayList(NamedGroupRange).empty;
    errdefer groups.deinit(allocator);
    var start: usize = 0;
    while (start < items.len) {
        if (items[start].ordinal != 0) return Error.InvalidSchedule;
        var end = start + 1;
        while (end < items.len and items[end].ordinal != 0) : (end += 1) {}
        for (items[start..end], 0..) |item, expected| if (item.ordinal != expected)
            return Error.InvalidSchedule;
        try groups.append(allocator, .{ .start = start, .len = end - start });
        start = end;
    }
    return groups.toOwnedSlice(allocator);
}

pub fn collectSn2DecommitBindings(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) !OwnedSn2DecommitBindings {
    const fri_start_log = try friStartLog(try one(schedule, plan, "QuotientTile"));
    const geometry = fri_geometry.FriGeometry.init(fri_start_log) catch return Error.InvalidBindingSize;
    const evaluation_pointers = try collectOrdinals(allocator, schedule, plan, "DecommitTraceEvaluationPointers");
    defer allocator.free(evaluation_pointers);
    const evaluation_logs = try collectOrdinals(allocator, schedule, plan, "DecommitTraceEvaluationLogs");
    defer allocator.free(evaluation_logs);
    const coefficient_pointers = try collectOrdinals(allocator, schedule, plan, "DecommitTraceCoefficientPointers");
    defer allocator.free(coefficient_pointers);
    const coefficient_sizes = try collectOrdinals(allocator, schedule, plan, "DecommitTraceCoefficientSizes");
    defer allocator.free(coefficient_sizes);
    const lde_output_pointers = try collectOrdinals(allocator, schedule, plan, "DecommitTraceLdeOutputPointers");
    defer allocator.free(lde_output_pointers);
    const trace_retained_pointers = try collectOrdinals(allocator, schedule, plan, "DecommitTraceRetainedPointers");
    defer allocator.free(trace_retained_pointers);
    const trace_sparse_offsets = try collectOrdinals(allocator, schedule, plan, "DecommitTraceSparseOffsets");
    defer allocator.free(trace_sparse_offsets);
    const fri_coordinate_pointers = try collectOrdinals(allocator, schedule, plan, "DecommitFriCoordinatePointers");
    defer allocator.free(fri_coordinate_pointers);
    const fri_retained_pointers = try collectOrdinals(allocator, schedule, plan, "DecommitFriRetainedPointers");
    defer allocator.free(fri_retained_pointers);

    if (evaluation_pointers.len != Sn2Counts.decommit_trace_groups or
        evaluation_logs.len != evaluation_pointers.len or
        coefficient_pointers.len == 0 or
        coefficient_pointers.len > Sn2Counts.decommit_trace_coefficient_groups or
        coefficient_sizes.len != coefficient_pointers.len or
        lde_output_pointers.len != coefficient_pointers.len or
        trace_retained_pointers.len != Sn2Counts.decommit_trace_trees or
        trace_sparse_offsets.len != Sn2Counts.decommit_trace_trees or
        fri_coordinate_pointers.len != Sn2Counts.decommit_fri_trees or
        fri_retained_pointers.len != Sn2Counts.decommit_fri_trees)
        return Error.InvalidCardinality;

    for (coefficient_pointers, coefficient_sizes, lde_output_pointers) |pointers, sizes, outputs| {
        if (pointers.ordinal != sizes.ordinal or pointers.ordinal != outputs.ordinal)
            return Error.InvalidSchedule;
    }

    const groups = try allocator.alloc(DecommitTraceGroupBindings, evaluation_pointers.len);
    errdefer allocator.free(groups);
    const trace_tree_logs = [Sn2Counts.decommit_trace_trees]u32{ 26, fri_start_log, fri_start_log, fri_start_log };
    const trace_leaf_logs = trace_tree_logs;
    var trace_trees: [Sn2Counts.decommit_trace_trees]DecommitTraceTreeBindings = undefined;
    var group_cursor: usize = 0;
    var coefficient_cursor: usize = 0;
    for (0..Sn2Counts.decommit_trace_trees) |tree_index| {
        const group_start = group_cursor;
        var column_count: u32 = 0;
        for (0..Sn2Counts.decommit_trace_groups_by_tree[tree_index]) |group_index| {
            const pointers = evaluation_pointers[group_cursor];
            const logs = evaluation_logs[group_cursor];
            const expected_ordinal = (@as(u32, @intCast(tree_index)) << 16) | @as(u32, @intCast(group_index));
            if (pointers.ordinal != expected_ordinal or logs.ordinal != expected_ordinal or
                logs.binding.size_bytes == 0 or logs.binding.size_bytes % 4 != 0 or
                pointers.binding.size_bytes != logs.binding.size_bytes * 2)
                return Error.InvalidBindingSize;
            const group_columns = std.math.cast(u32, logs.binding.size_bytes / 4) orelse return Error.InvalidBindingSize;
            if (group_columns == 0 or group_columns > 16) return Error.InvalidBindingSize;

            var coefficients: ?DecommitTraceCoefficientBindings = null;
            if (coefficient_cursor < coefficient_pointers.len) {
                const coefficient_ordinal = coefficient_pointers[coefficient_cursor].ordinal;
                if (coefficient_ordinal < expected_ordinal) return Error.InvalidSchedule;
                if (coefficient_ordinal == expected_ordinal) {
                    const coefficient_size_binding = coefficient_sizes[coefficient_cursor].binding;
                    if (coefficient_size_binding.size_bytes != logs.binding.size_bytes or
                        coefficient_pointers[coefficient_cursor].binding.size_bytes != logs.binding.size_bytes * 2 or
                        lde_output_pointers[coefficient_cursor].binding.size_bytes != logs.binding.size_bytes * 2)
                        return Error.InvalidBindingSize;
                    coefficients = .{
                        .pointers = coefficient_pointers[coefficient_cursor].binding,
                        .sizes = coefficient_size_binding,
                        .lde_output_pointers = lde_output_pointers[coefficient_cursor].binding,
                    };
                    coefficient_cursor += 1;
                }
            }
            groups[group_cursor] = .{
                .tree_index = @intCast(tree_index),
                .group_index = @intCast(group_index),
                .column_count = group_columns,
                .evaluation_pointers = pointers.binding,
                .evaluation_logs = logs.binding,
                .coefficients = coefficients,
            };
            column_count += group_columns;
            group_cursor += 1;
        }
        if (column_count != Sn2Counts.decommit_trace_columns_by_tree[tree_index]) return Error.InvalidCardinality;
        const retained = trace_retained_pointers[tree_index];
        const sparse = trace_sparse_offsets[tree_index];
        const tree_ordinal = @as(u32, @intCast(tree_index)) << 16;
        if (retained.ordinal != tree_ordinal or sparse.ordinal != tree_ordinal or
            retained.binding.size_bytes != @as(u64, trace_leaf_logs[tree_index] + 1) * 2 * 4 or
            sparse.binding.size_bytes != 4 * 4)
            return Error.InvalidBindingSize;
        trace_trees[tree_index] = .{
            .tree_index = @intCast(tree_index),
            .source_log = fri_start_log,
            .tree_log = trace_tree_logs[tree_index],
            .leaf_log = trace_leaf_logs[tree_index],
            .unretained = 4,
            .column_count = column_count,
            .groups = groups[group_start..group_cursor],
            .retained_pointers = retained.binding,
            .sparse_offsets = sparse.binding,
        };
    }
    if (group_cursor != groups.len or coefficient_cursor != coefficient_pointers.len)
        return Error.InvalidCardinality;

    var fri_trees: [Sn2Counts.decommit_fri_trees]DecommitFriTreeBindings = undefined;
    for (0..Sn2Counts.decommit_fri_trees) |round| {
        const fri_leaf_log = try geometry.leafLog(round);
        const tree_index = round + Sn2Counts.decommit_trace_trees;
        const expected_ordinal = @as(u32, @intCast(tree_index)) << 16;
        const coordinates = fri_coordinate_pointers[round];
        const retained = fri_retained_pointers[round];
        if (coordinates.ordinal != expected_ordinal or retained.ordinal != expected_ordinal or
            coordinates.binding.size_bytes != 4 * 2 * 4 or
            retained.binding.size_bytes != @as(u64, fri_leaf_log + 1) * 2 * 4)
            return Error.InvalidBindingSize;
        fri_trees[round] = .{
            .round = @intCast(round),
            .tree_index = @intCast(tree_index),
            .leaf_log = fri_leaf_log,
            .coordinate_pointers = coordinates.binding,
            .retained_pointers = retained.binding,
        };
    }
    return .{ .trace_groups = groups, .trace_trees = trace_trees, .fri_trees = fri_trees };
}

pub fn friStartLog(quotient: arena_plan.Binding) !u32 {
    if (quotient.size_bytes < 16 or quotient.size_bytes % 16 != 0 or
        !std.math.isPowerOfTwo(quotient.size_bytes / 16))
        return Error.InvalidBindingSize;
    return std.math.log2_int(u64, quotient.size_bytes / 16);
}

test "Cairo zero-retention decommit bindings cover every trace group" {
    const allocator = std.testing.allocator;
    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);
    var plan_bindings = std.ArrayList(arena_plan.Binding).empty;
    defer plan_bindings.deinit(allocator);
    try encoded.append(allocator, '[');
    var word_cursor: u64 = 0;
    try appendDecommitFixtureEntry(
        allocator,
        &encoded,
        &plan_bindings,
        &word_cursor,
        "QuotientTile",
        0,
        (@as(u32, 1) << 24) * 4,
    );

    for (Sn2Counts.decommit_trace_groups_by_tree, Sn2Counts.decommit_trace_columns_by_tree, 0..) |group_count, column_count, tree_index| {
        var remaining = column_count;
        for (0..group_count) |group_index| {
            const columns: u32 = @min(remaining, 16);
            remaining -= columns;
            const binding_ordinal = (@as(u32, @intCast(tree_index)) << 16) | @as(u32, @intCast(group_index));
            try appendDecommitFixtureEntry(
                allocator,
                &encoded,
                &plan_bindings,
                &word_cursor,
                "DecommitTraceEvaluationPointers",
                binding_ordinal,
                columns * 2,
            );
            try appendDecommitFixtureEntry(
                allocator,
                &encoded,
                &plan_bindings,
                &word_cursor,
                "DecommitTraceEvaluationLogs",
                binding_ordinal,
                columns,
            );
        }
        try std.testing.expectEqual(@as(u32, 0), remaining);
    }

    for (0..Sn2Counts.decommit_trace_trees) |tree_index| {
        const coefficient_group_count = Sn2Counts.decommit_trace_groups_by_tree[tree_index];
        for (0..coefficient_group_count) |group_index| {
            const binding_ordinal = (@as(u32, @intCast(tree_index)) << 16) | @as(u32, @intCast(group_index));
            const columns: u32 = if (group_index + 1 == coefficient_group_count)
                Sn2Counts.decommit_trace_columns_by_tree[tree_index] - @as(u32, @intCast(group_index)) * 16
            else
                16;
            inline for (.{
                "DecommitTraceCoefficientPointers",
                "DecommitTraceCoefficientSizes",
                "DecommitTraceLdeOutputPointers",
            }, 0..) |name, kind| {
                try appendDecommitFixtureEntry(
                    allocator,
                    &encoded,
                    &plan_bindings,
                    &word_cursor,
                    name,
                    binding_ordinal,
                    if (kind == 1) columns else columns * 2,
                );
            }
        }
    }

    const trace_leaf_logs = [_]u32{ 26, 24, 24, 24 };
    for (trace_leaf_logs, 0..) |leaf_log, tree_index| {
        const binding_ordinal = @as(u32, @intCast(tree_index)) << 16;
        try appendDecommitFixtureEntry(
            allocator,
            &encoded,
            &plan_bindings,
            &word_cursor,
            "DecommitTraceRetainedPointers",
            binding_ordinal,
            (leaf_log + 1) * 2,
        );
        try appendDecommitFixtureEntry(
            allocator,
            &encoded,
            &plan_bindings,
            &word_cursor,
            "DecommitTraceSparseOffsets",
            binding_ordinal,
            4,
        );
    }

    const fri_leaf_logs = [_]u32{ 22, 19, 16, 13, 10, 7, 4, 1 };
    for (fri_leaf_logs, 0..) |leaf_log, round| {
        const binding_ordinal = @as(u32, @intCast(round + Sn2Counts.decommit_trace_trees)) << 16;
        try appendDecommitFixtureEntry(
            allocator,
            &encoded,
            &plan_bindings,
            &word_cursor,
            "DecommitFriCoordinatePointers",
            binding_ordinal,
            8,
        );
        try appendDecommitFixtureEntry(
            allocator,
            &encoded,
            &plan_bindings,
            &word_cursor,
            "DecommitFriRetainedPointers",
            binding_ordinal,
            (leaf_log + 1) * 2,
        );
    }
    try encoded.append(allocator, ']');

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    var empty_slots: [0]arena_plan.Slot = .{};
    var empty_actions: [0]arena_plan.Action = .{};
    var empty_offsets: [0]usize = .{};
    const plan = arena_plan.Plan{
        .allocator = allocator,
        .bindings = plan_bindings.items,
        .slots = &empty_slots,
        .actions = &empty_actions,
        .action_offsets = &empty_offsets,
        .total_bytes = word_cursor * 4,
        .peak_live_bytes = word_cursor * 4,
        .plan_hash = 0,
    };
    var decommit = try collectSn2DecommitBindings(allocator, parsed.value.array.items, plan);
    defer decommit.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 370), decommit.trace_groups.len);
    try std.testing.expectEqualSlices(usize, &.{ 11, 216, 142, 1 }, &Sn2Counts.decommit_trace_groups_by_tree);
    for (decommit.trace_trees, Sn2Counts.decommit_trace_columns_by_tree, 0..) |tree, column_count, tree_index| {
        try std.testing.expectEqual(@as(u32, @intCast(tree_index)), tree.tree_index);
        try std.testing.expectEqual(column_count, tree.column_count);
    }
    for (decommit.trace_groups) |group| try std.testing.expect(group.coefficients != null);
    for (decommit.fri_trees, fri_leaf_logs, 0..) |tree, leaf_log, round| {
        try std.testing.expectEqual(@as(u32, @intCast(round + 4)), tree.tree_index);
        try std.testing.expectEqual(leaf_log, tree.leaf_log);
    }

    try std.testing.expectError(
        Error.InvalidCardinality,
        collectSn2DecommitBindings(allocator, parsed.value.array.items[0 .. parsed.value.array.items.len - 1], plan),
    );
}

fn appendDecommitFixtureEntry(
    allocator: std.mem.Allocator,
    encoded: *std.ArrayList(u8),
    bindings: *std.ArrayList(arena_plan.Binding),
    word_cursor: *u64,
    name: []const u8,
    binding_ordinal: u32,
    word_count: u32,
) !void {
    const logical_id = std.math.cast(u32, bindings.items.len + 1) orelse return Error.InvalidCardinality;
    try encoded.writer(allocator).print(
        "{s}{{\"purpose\":\"{s}\",\"ordinal\":{},\"id\":{}}}",
        .{ if (bindings.items.len == 0) "" else ",", name, binding_ordinal, logical_id },
    );
    try bindings.append(allocator, .{
        .logical_id = logical_id,
        .slot = logical_id,
        .offset_bytes = word_cursor.* * 4,
        .size_bytes = @as(u64, word_count) * 4,
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    });
    word_cursor.* += word_count;
}

test "named binding ranges preserve repeated component instances" {
    const bindings = [_]NamedBinding{
        .{ .component = "memory", .ordinal = 0, .binding = undefined },
        .{ .component = "memory", .ordinal = 1, .binding = undefined },
        .{ .component = "memory", .ordinal = 0, .binding = undefined },
    };
    const ranges = try namedGroupRanges(std.testing.allocator, &bindings);
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqualSlices(
        NamedGroupRange,
        &.{ .{ .start = 0, .len = 2 }, .{ .start = 2, .len = 1 } },
        ranges,
    );
}

test "schedule field selectors reject malformed values" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\[{"purpose":"Trace","component":"cpu","ordinal":3,"id":7}]
    ,
        .{},
    );
    defer parsed.deinit();
    const entry = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("Trace", try purpose(entry));
    try std.testing.expectEqualStrings("cpu", try componentName(entry));
    try std.testing.expectEqual(@as(u32, 3), try ordinal(entry));
    try std.testing.expectEqual(@as(u32, 7), try logicalId(entry));
    try std.testing.expectError(Error.InvalidSchedule, purpose(.null));
}

test "schedule bindings preserve each declared ordering contract" {
    var plan_bindings = [_]arena_plan.Binding{
        testBinding(40, 0),
        testBinding(41, 1),
        testBinding(42, 2),
        testBinding(43, 3),
    };
    var empty_slots: [0]arena_plan.Slot = .{};
    var empty_actions: [0]arena_plan.Action = .{};
    var empty_offsets: [0]usize = .{};
    const plan = arena_plan.Plan{
        .allocator = std.testing.allocator,
        .bindings = &plan_bindings,
        .slots = &empty_slots,
        .actions = &empty_actions,
        .action_offsets = &empty_offsets,
        .total_bytes = 64,
        .peak_live_bytes = 64,
        .plan_hash = 0,
    };
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\[
        \\  {"purpose":"Ordered","component":"cpu","ordinal":1,"id":41},
        \\  {"purpose":"Ordered","component":"cpu","ordinal":0,"id":40},
        \\  {"purpose":"Grouped","component":"memory","ordinal":0,"id":40},
        \\  {"purpose":"Grouped","component":"memory","ordinal":1,"id":41},
        \\  {"purpose":"Grouped","component":"memory","ordinal":0,"id":42},
        \\  {"purpose":"Single","component":"cpu","id":43}
        \\]
    ,
        .{},
    );
    defer parsed.deinit();
    const schedule = parsed.value.array.items;

    try std.testing.expectEqual(@as(u32, 43), (try one(schedule, plan, "Single")).logical_id);
    try std.testing.expectEqual(
        @as(u32, 41),
        (try oneComponentOrdinal(schedule, plan, "Ordered", "cpu", 1)).logical_id,
    );

    const ordered = try collect(std.testing.allocator, schedule, plan, "Ordered");
    defer std.testing.allocator.free(ordered);
    try expectLogicalIds(&.{ 40, 41 }, ordered);

    const captured = try collectScheduleOrder(std.testing.allocator, schedule, plan, "Ordered");
    defer std.testing.allocator.free(captured);
    try expectLogicalIds(&.{ 41, 40 }, captured);

    const component = try collectComponent(
        std.testing.allocator,
        schedule,
        plan,
        "Ordered",
        "cpu",
    );
    defer std.testing.allocator.free(component);
    try expectLogicalIds(&.{ 40, 41 }, component);

    const groups = try collectComponentBindingGroups(
        std.testing.allocator,
        schedule,
        plan,
        "Grouped",
        "memory",
    );
    defer {
        for (groups) |group| std.testing.allocator.free(group);
        std.testing.allocator.free(groups);
    }
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try expectLogicalIds(&.{ 40, 41 }, groups[0]);
    try expectLogicalIds(&.{42}, groups[1]);
}

fn testBinding(logical_id: u32, slot: u32) arena_plan.Binding {
    return .{
        .logical_id = logical_id,
        .slot = slot,
        .offset_bytes = @as(u64, slot) * 16,
        .size_bytes = 16,
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };
}

fn expectLogicalIds(expected: []const u32, bindings: []const arena_plan.Binding) !void {
    try std.testing.expectEqual(expected.len, bindings.len);
    for (expected, bindings) |expected_id, binding|
        try std.testing.expectEqual(expected_id, binding.logical_id);
}
