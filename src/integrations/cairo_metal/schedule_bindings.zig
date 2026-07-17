//! Schedule JSON selection and binding-order reconstruction for Cairo proofs.

const std = @import("std");
const arena_plan = @import("../../backend/arena_plan.zig");

pub const Error = error{
    InvalidSchedule,
    DuplicateBinding,
    MissingBinding,
    InvalidCardinality,
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
