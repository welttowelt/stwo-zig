const std = @import("std");
const arena_plan = @import("../../backend/arena_plan.zig");
const bindings_mod = @import("schedule_bindings.zig");

test "runtime decommit geometry binds Fib-like 4 trace and 7 FRI trees fail closed" {
    const allocator = std.testing.allocator;
    const trace_trees = [_]bindings_mod.TraceTreeGeometry{
        .{ .role = .preprocessed, .tree_index = 0, .source_log = 21, .tree_log = 21, .leaf_log = 21, .unretained = 3, .column_count = 17 },
        .{ .role = .base, .tree_index = 1, .source_log = 21, .tree_log = 21, .leaf_log = 21, .unretained = 3, .column_count = 31 },
        .{ .role = .interaction, .tree_index = 2, .source_log = 21, .tree_log = 21, .leaf_log = 21, .unretained = 3, .column_count = 1 },
        .{ .role = .composition, .tree_index = 3, .source_log = 21, .tree_log = 21, .leaf_log = 21, .unretained = 3, .column_count = 8 },
    };
    const fri_trees = [_]bindings_mod.FriTreeGeometry{
        .{ .role = 4, .round = 0, .tree_index = 4, .leaf_log = 19 },
        .{ .role = 5, .round = 1, .tree_index = 5, .leaf_log = 16 },
        .{ .role = 6, .round = 2, .tree_index = 6, .leaf_log = 13 },
        .{ .role = 7, .round = 3, .tree_index = 7, .leaf_log = 10 },
        .{ .role = 8, .round = 4, .tree_index = 8, .leaf_log = 7 },
        .{ .role = 9, .round = 5, .tree_index = 9, .leaf_log = 4 },
        .{ .role = 10, .round = 6, .tree_index = 10, .leaf_log = 1 },
    };
    const geometry = bindings_mod.ProofDecommitGeometry{ .trace_trees = &trace_trees, .fri_trees = &fri_trees };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);
    var plan_bindings = std.ArrayList(arena_plan.Binding).empty;
    defer plan_bindings.deinit(allocator);
    try encoded.append(allocator, '[');
    var word_cursor: u64 = 0;
    for (trace_trees) |tree| {
        var remaining = tree.column_count;
        for (0..tree.groupCount()) |group_index| {
            const columns: u32 = @min(remaining, 16);
            remaining -= columns;
            const binding_ordinal = (tree.tree_index << 16) | @as(u32, @intCast(group_index));
            inline for (.{
                .{ "DecommitTraceEvaluationPointers", 2 },
                .{ "DecommitTraceEvaluationLogs", 1 },
                .{ "DecommitTraceCoefficientPointers", 2 },
                .{ "DecommitTraceCoefficientSizes", 1 },
                .{ "DecommitTraceLdeOutputPointers", 2 },
            }) |entry| try appendEntry(
                allocator,
                &encoded,
                &plan_bindings,
                &word_cursor,
                entry[0],
                binding_ordinal,
                columns * entry[1],
            );
        }
        const tree_ordinal = tree.tree_index << 16;
        try appendEntry(allocator, &encoded, &plan_bindings, &word_cursor, "DecommitTraceRetainedPointers", tree_ordinal, (tree.leaf_log + 1) * 2);
        try appendEntry(allocator, &encoded, &plan_bindings, &word_cursor, "DecommitTraceSparseOffsets", tree_ordinal, tree.unretained);
    }
    for (fri_trees) |tree| {
        const tree_ordinal = tree.tree_index << 16;
        try appendEntry(allocator, &encoded, &plan_bindings, &word_cursor, "DecommitFriCoordinatePointers", tree_ordinal, 8);
        try appendEntry(allocator, &encoded, &plan_bindings, &word_cursor, "DecommitFriRetainedPointers", tree_ordinal, (tree.leaf_log + 1) * 2);
    }
    try encoded.append(allocator, ']');

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded.items, .{});
    defer parsed.deinit();
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
    var bindings = try bindings_mod.collectDecommitBindings(allocator, parsed.value.array.items, plan, geometry);
    defer bindings.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), bindings.trace_trees.len);
    try std.testing.expectEqual(@as(usize, 7), bindings.fri_trees.len);
    try std.testing.expectEqual(@as(usize, 6), bindings.trace_groups.len);
    try std.testing.expectEqual(@as(u32, 10), bindings.fri_trees[6].role);
    try std.testing.expectEqual(@as(usize, 77), try geometry.friLayerCount());

    var role_drift = trace_trees;
    role_drift[2].role = .base;
    try std.testing.expectError(
        bindings_mod.Error.InvalidSchedule,
        bindings_mod.collectDecommitBindings(allocator, parsed.value.array.items, plan, .{
            .trace_trees = &role_drift,
            .fri_trees = &fri_trees,
        }),
    );
    try std.testing.expectError(
        bindings_mod.Error.InvalidCardinality,
        bindings_mod.collectDecommitBindings(allocator, parsed.value.array.items, plan, .{
            .trace_trees = &trace_trees,
            .fri_trees = fri_trees[0..6],
        }),
    );
}

fn appendEntry(
    allocator: std.mem.Allocator,
    encoded: *std.ArrayList(u8),
    bindings: *std.ArrayList(arena_plan.Binding),
    word_cursor: *u64,
    name: []const u8,
    binding_ordinal: u32,
    word_count: u32,
) !void {
    const logical_id = std.math.cast(u32, bindings.items.len + 1) orelse return error.InvalidCardinality;
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
