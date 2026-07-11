const std = @import("std");
const runtime = @import("runtime.zig");

pub const max_ticks = 1024;
const TickSet = [max_ticks / 64]u64;

pub const Materialization = enum {
    resident,
    spill,
    recompute,
};

pub const LiveRange = struct {
    first: u16,
    last: u16,
};

/// One device value and the exact schedule ticks at which a kernel consumes it.
/// A tick may be a whole proof phase or a component-local sub-epoch.
pub const LogicalBuffer = struct {
    id: u32,
    size_bytes: u64,
    alignment: u32 = 16 * 1024,
    live_ranges: []const LiveRange,
    spill_cost_ns: ?u64 = null,
    recompute_cost_ns: ?u64 = null,
};

pub const Binding = struct {
    logical_id: u32,
    slot: u32,
    offset_bytes: u64,
    size_bytes: u64,
    materialization: Materialization,
    occupied: TickSet,
};

pub const Slot = struct {
    offset_bytes: u64,
    capacity_bytes: u64,
    alignment: u32,
    occupied: TickSet,
};

pub const ActionKind = enum { produce, restore, recompute, spill, release };

pub const Action = struct {
    tick: u16,
    logical_id: u32,
    kind: ActionKind,
};

pub const Error = error{
    EmptySchedule,
    DuplicateLogicalId,
    InvalidAlignment,
    InvalidTick,
    InvalidUseOrder,
    SizeOverflow,
    BudgetExceeded,
    AliasOverlap,
    UnknownBinding,
    BindingOutOfBounds,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    bindings: []Binding,
    slots: []Slot,
    actions: []Action,
    action_offsets: []usize,
    total_bytes: u64,
    peak_live_bytes: u64,
    plan_hash: u64,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.bindings);
        self.allocator.free(self.slots);
        self.allocator.free(self.actions);
        self.allocator.free(self.action_offsets);
        self.* = undefined;
    }

    pub fn binding(self: Plan, logical_id: u32) Error!Binding {
        for (self.bindings) |candidate| {
            if (candidate.logical_id == logical_id) return candidate;
        }
        return Error.UnknownBinding;
    }

    pub fn validate(self: Plan, budget_bytes: u64) (std.mem.Allocator.Error || Error)!void {
        if (self.total_bytes > budget_bytes) return Error.BudgetExceeded;
        const occupied_by_slot = try self.allocator.alloc(TickSet, self.slots.len);
        defer self.allocator.free(occupied_by_slot);
        @memset(occupied_by_slot, [_]u64{0} ** (max_ticks / 64));
        for (self.bindings) |first| {
            const first_slot = self.slots[first.slot];
            if (first.offset_bytes != first_slot.offset_bytes or
                first.size_bytes > first_slot.capacity_bytes or
                first.offset_bytes + first.size_bytes > self.total_bytes)
                return Error.BindingOutOfBounds;
            if (intersects(occupied_by_slot[first.slot], first.occupied)) return Error.AliasOverlap;
            unionInto(&occupied_by_slot[first.slot], first.occupied);
        }
    }
};

/// Plans the smallest live range allowed by each buffer's recovery policy.
/// Values with no recovery recipe remain resident from first through last use.
/// Recoverable values occupy only their exact live ranges; the cheaper of restore
/// and recomputation is selected deterministically.
pub fn build(
    allocator: std.mem.Allocator,
    logical: []const LogicalBuffer,
    budget_bytes: u64,
) (std.mem.Allocator.Error || Error)!Plan {
    if (logical.len == 0) return Error.EmptySchedule;

    var work = try allocator.alloc(WorkBuffer, logical.len);
    defer allocator.free(work);
    for (logical, 0..) |buffer, index| {
        try validateBuffer(buffer);
        for (logical[0..index]) |previous| {
            if (previous.id == buffer.id) return Error.DuplicateLogicalId;
        }
        const materialization = chooseMaterialization(buffer);
        work[index] = .{
            .input_index = index,
            .materialization = materialization,
            .occupied = occupancy(buffer, materialization),
        };
    }
    std.mem.sortUnstable(WorkBuffer, work, logical, WorkBuffer.lessThan);

    var slots = std.ArrayList(Slot).empty;
    defer slots.deinit(allocator);
    var unsorted_bindings = std.ArrayList(Binding).empty;
    defer unsorted_bindings.deinit(allocator);

    for (work) |item| {
        const buffer = logical[item.input_index];
        var candidate: ?usize = null;
        var candidate_growth: u64 = std.math.maxInt(u64);
        var candidate_capacity: u64 = std.math.maxInt(u64);
        for (slots.items, 0..) |slot, slot_index| {
            if (intersects(slot.occupied, item.occupied)) continue;
            const capacity = @max(slot.capacity_bytes, buffer.size_bytes);
            const growth = capacity - slot.capacity_bytes;
            if (growth < candidate_growth or
                (growth == candidate_growth and capacity < candidate_capacity))
            {
                candidate = slot_index;
                candidate_growth = growth;
                candidate_capacity = capacity;
            }
        }
        const slot_index = candidate orelse blk: {
            try slots.append(allocator, .{
                .offset_bytes = 0,
                .capacity_bytes = 0,
                .alignment = buffer.alignment,
                .occupied = [_]u64{0} ** (max_ticks / 64),
            });
            break :blk slots.items.len - 1;
        };
        var slot = &slots.items[slot_index];
        slot.capacity_bytes = @max(slot.capacity_bytes, buffer.size_bytes);
        slot.alignment = @max(slot.alignment, buffer.alignment);
        unionInto(&slot.occupied, item.occupied);
        try unsorted_bindings.append(allocator, .{
            .logical_id = buffer.id,
            .slot = @intCast(slot_index),
            .offset_bytes = 0,
            .size_bytes = buffer.size_bytes,
            .materialization = item.materialization,
            .occupied = item.occupied,
        });
    }

    var total_bytes: u64 = 0;
    for (slots.items) |*slot| {
        total_bytes = try alignForward(total_bytes, slot.alignment);
        slot.offset_bytes = total_bytes;
        total_bytes = std.math.add(u64, total_bytes, slot.capacity_bytes) catch return Error.SizeOverflow;
    }
    total_bytes = try alignForward(total_bytes, 16 * 1024);
    if (total_bytes > budget_bytes) return Error.BudgetExceeded;
    for (unsorted_bindings.items) |*binding| binding.offset_bytes = slots.items[binding.slot].offset_bytes;
    std.mem.sortUnstable(Binding, unsorted_bindings.items, {}, bindingLessThan);

    var actions = std.ArrayList(Action).empty;
    defer actions.deinit(allocator);
    for (logical) |buffer| {
        const materialization = chooseMaterialization(buffer);
        try appendActions(allocator, &actions, buffer, materialization);
    }
    std.mem.sortUnstable(Action, actions.items, {}, actionLessThan);

    const owned_bindings = try unsorted_bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    const owned_slots = try slots.toOwnedSlice(allocator);
    errdefer allocator.free(owned_slots);
    const owned_actions = try actions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_actions);
    const action_offsets = try buildActionOffsets(allocator, owned_actions);
    errdefer allocator.free(action_offsets);
    const peak = peakLiveBytes(owned_slots);
    const hash = hashPlan(owned_bindings, owned_slots, owned_actions, total_bytes);
    var result = Plan{
        .allocator = allocator,
        .bindings = owned_bindings,
        .slots = owned_slots,
        .actions = owned_actions,
        .action_offsets = action_offsets,
        .total_bytes = total_bytes,
        .peak_live_bytes = peak,
        .plan_hash = hash,
    };
    try result.validate(budget_bytes);
    return result;
}

const WorkBuffer = struct {
    input_index: usize,
    materialization: Materialization,
    occupied: TickSet,

    fn lessThan(logical: []const LogicalBuffer, a: WorkBuffer, b: WorkBuffer) bool {
        const left = logical[a.input_index];
        const right = logical[b.input_index];
        if (left.size_bytes != right.size_bytes) return left.size_bytes > right.size_bytes;
        return left.id < right.id;
    }
};

fn validateBuffer(buffer: LogicalBuffer) Error!void {
    if (buffer.size_bytes == 0 or buffer.live_ranges.len == 0) return Error.EmptySchedule;
    if (buffer.alignment == 0 or !std.math.isPowerOfTwo(buffer.alignment)) return Error.InvalidAlignment;
    var previous_last: ?u16 = null;
    for (buffer.live_ranges) |range| {
        if (range.first > range.last or range.last >= max_ticks) return Error.InvalidTick;
        if (previous_last) |value| if (range.first <= value) return Error.InvalidUseOrder;
        previous_last = range.last;
    }
}

fn chooseMaterialization(buffer: LogicalBuffer) Materialization {
    if (buffer.live_ranges.len <= 1) return .resident;
    if (buffer.recompute_cost_ns) |recompute| {
        if (buffer.spill_cost_ns) |spill| return if (recompute <= spill) .recompute else .spill;
        return .recompute;
    }
    if (buffer.spill_cost_ns != null) return .spill;
    return .resident;
}

fn occupancy(buffer: LogicalBuffer, materialization: Materialization) TickSet {
    var result = [_]u64{0} ** (max_ticks / 64);
    if (materialization == .resident) {
        var tick = buffer.live_ranges[0].first;
        const last = buffer.live_ranges[buffer.live_ranges.len - 1].last;
        while (tick <= last) : (tick += 1) setTick(&result, tick);
    } else {
        for (buffer.live_ranges) |range| {
            var tick = range.first;
            while (tick <= range.last) : (tick += 1) setTick(&result, tick);
        }
    }
    return result;
}

fn appendActions(allocator: std.mem.Allocator, actions: *std.ArrayList(Action), buffer: LogicalBuffer, materialization: Materialization) !void {
    if (materialization == .resident) {
        try actions.append(allocator, .{ .tick = buffer.live_ranges[0].first, .logical_id = buffer.id, .kind = .produce });
        try actions.append(allocator, .{ .tick = buffer.live_ranges[buffer.live_ranges.len - 1].last, .logical_id = buffer.id, .kind = .release });
        return;
    }
    for (buffer.live_ranges, 0..) |range, index| {
        const enter: ActionKind = if (index == 0) .produce else if (materialization == .spill) .restore else .recompute;
        try actions.append(allocator, .{ .tick = range.first, .logical_id = buffer.id, .kind = enter });
        if (materialization == .spill and index + 1 < buffer.live_ranges.len)
            try actions.append(allocator, .{ .tick = range.last, .logical_id = buffer.id, .kind = .spill });
        try actions.append(allocator, .{ .tick = range.last, .logical_id = buffer.id, .kind = .release });
    }
}

fn peakLiveBytes(slots: []const Slot) u64 {
    var peak: u64 = 0;
    for (0..max_ticks) |tick| {
        var live: u64 = 0;
        for (slots) |slot| {
            if (hasTick(slot.occupied, @intCast(tick))) live += slot.capacity_bytes;
        }
        peak = @max(peak, live);
    }
    return peak;
}

fn buildActionOffsets(allocator: std.mem.Allocator, actions: []const Action) ![]usize {
    const offsets = try allocator.alloc(usize, max_ticks + 1);
    var cursor: usize = 0;
    for (0..max_ticks) |tick| {
        offsets[tick] = cursor;
        while (cursor < actions.len and actions[cursor].tick == tick) cursor += 1;
    }
    offsets[max_ticks] = actions.len;
    return offsets;
}

fn bindingLessThan(_: void, a: Binding, b: Binding) bool {
    return a.logical_id < b.logical_id;
}
fn actionLessThan(_: void, a: Action, b: Action) bool {
    if (a.tick != b.tick) return a.tick < b.tick;
    if (a.logical_id != b.logical_id) return a.logical_id < b.logical_id;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

fn setTick(set: *TickSet, tick: u16) void {
    set[tick / 64] |= @as(u64, 1) << @intCast(tick % 64);
}
fn hasTick(set: TickSet, tick: u16) bool {
    return set[tick / 64] & (@as(u64, 1) << @intCast(tick % 64)) != 0;
}
fn intersects(a: TickSet, b: TickSet) bool {
    for (a, b) |x, y| if (x & y != 0) return true;
    return false;
}
fn unionInto(destination: *TickSet, source: TickSet) void {
    for (destination, source) |*x, y| x.* |= y;
}

fn alignForward(value: u64, alignment: u32) Error!u64 {
    const mask = @as(u64, alignment) - 1;
    const added = std.math.add(u64, value, mask) catch return Error.SizeOverflow;
    return added & ~mask;
}

fn hashPlan(bindings: []const Binding, slots: []const Slot, actions: []const Action, total: u64) u64 {
    var hash = std.hash.Fnv1a_64.init();
    hash.update(std.mem.asBytes(&total));
    for (bindings) |binding| {
        hash.update(std.mem.asBytes(&binding.logical_id));
        hash.update(std.mem.asBytes(&binding.slot));
        hash.update(std.mem.asBytes(&binding.offset_bytes));
        hash.update(std.mem.asBytes(&binding.size_bytes));
        const materialization: u8 = @intFromEnum(binding.materialization);
        hash.update(std.mem.asBytes(&materialization));
        hash.update(std.mem.sliceAsBytes(&binding.occupied));
    }
    for (slots) |slot| {
        hash.update(std.mem.asBytes(&slot.offset_bytes));
        hash.update(std.mem.asBytes(&slot.capacity_bytes));
        hash.update(std.mem.asBytes(&slot.alignment));
        hash.update(std.mem.sliceAsBytes(&slot.occupied));
    }
    for (actions) |action| {
        hash.update(std.mem.asBytes(&action.tick));
        hash.update(std.mem.asBytes(&action.logical_id));
        const kind: u8 = @intFromEnum(action.kind);
        hash.update(std.mem.asBytes(&kind));
    }
    return hash.final();
}

/// One physical Metal allocation backing all colored slots in a plan.
pub const ResidentArena = struct {
    buffer: runtime.ResidentBuffer,

    pub fn init(metal: *runtime.Runtime, plan: Plan) runtime.MetalError!ResidentArena {
        return .{ .buffer = try metal.allocateResidentBuffer(@intCast(plan.total_bytes)) };
    }

    pub fn deinit(self: *ResidentArena) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn bytes(self: *ResidentArena, binding: Binding) Error![]align(1) u8 {
        const end = std.math.add(u64, binding.offset_bytes, binding.size_bytes) catch return Error.BindingOutOfBounds;
        if (end > self.buffer.byte_length) return Error.BindingOutOfBounds;
        const base: [*]u8 = @ptrCast(self.buffer.contents);
        return base[@intCast(binding.offset_bytes)..@intCast(end)];
    }
};

pub const RecoveryHooks = struct {
    context: *anyopaque,
    spill: *const fn (*anyopaque, u16, Binding) anyerror!void,
    restore: *const fn (*anyopaque, u16, Binding) anyerror!void,
    recompute: *const fn (*anyopaque, u16, Binding) anyerror!void,
};

pub const EpochRunner = struct {
    const State = enum { absent, live, spilled };

    allocator: std.mem.Allocator,
    plan: *const Plan,
    states: []State,
    slot_owners: []?u32,

    pub fn init(allocator: std.mem.Allocator, plan: *const Plan) !EpochRunner {
        const states = try allocator.alloc(State, plan.bindings.len);
        errdefer allocator.free(states);
        @memset(states, .absent);
        const owners = try allocator.alloc(?u32, plan.slots.len);
        @memset(owners, null);
        return .{ .allocator = allocator, .plan = plan, .states = states, .slot_owners = owners };
    }

    pub fn deinit(self: *EpochRunner) void {
        self.allocator.free(self.states);
        self.allocator.free(self.slot_owners);
        self.* = undefined;
    }

    /// Restores or regenerates every input before kernels for `tick` launch.
    pub fn begin(self: *EpochRunner, tick: u16, hooks: RecoveryHooks) !void {
        if (tick >= max_ticks) return Error.InvalidTick;
        for (self.actionsAt(tick)) |action| {
            if (action.kind == .spill or action.kind == .release) continue;
            const index = self.bindingIndex(action.logical_id) orelse return Error.UnknownBinding;
            const binding = self.plan.bindings[index];
            if (self.slot_owners[binding.slot] != null) return Error.AliasOverlap;
            switch (action.kind) {
                .produce => {},
                .restore => try hooks.restore(hooks.context, tick, binding),
                .recompute => try hooks.recompute(hooks.context, tick, binding),
                else => unreachable,
            }
            self.slot_owners[binding.slot] = binding.logical_id;
            self.states[index] = .live;
        }
    }

    /// Persists selected outputs and releases their slots after the tick's
    /// command buffer has completed. The caller owns that Metal barrier.
    pub fn end(self: *EpochRunner, tick: u16, hooks: RecoveryHooks) !void {
        if (tick >= max_ticks) return Error.InvalidTick;
        const actions = self.actionsAt(tick);
        for (actions) |action| {
            if (action.kind != .spill) continue;
            const index = self.bindingIndex(action.logical_id) orelse return Error.UnknownBinding;
            const binding = self.plan.bindings[index];
            if (self.states[index] != .live) return Error.InvalidUseOrder;
            try hooks.spill(hooks.context, tick, binding);
            self.states[index] = .spilled;
        }
        for (actions) |action| {
            if (action.kind != .release) continue;
            const index = self.bindingIndex(action.logical_id) orelse return Error.UnknownBinding;
            const binding = self.plan.bindings[index];
            if (self.states[index] != .live and self.states[index] != .spilled) return Error.InvalidUseOrder;
            if (self.slot_owners[binding.slot] != binding.logical_id) return Error.AliasOverlap;
            self.slot_owners[binding.slot] = null;
            if (self.states[index] != .spilled) self.states[index] = .absent;
        }
    }

    fn bindingIndex(self: EpochRunner, id: u32) ?usize {
        var low: usize = 0;
        var high = self.plan.bindings.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = self.plan.bindings[middle].logical_id;
            if (candidate < id) low = middle + 1 else high = middle;
        }
        return if (low < self.plan.bindings.len and self.plan.bindings[low].logical_id == id) low else null;
    }

    fn actionsAt(self: EpochRunner, tick: u16) []const Action {
        return self.plan.actions[self.plan.action_offsets[tick]..self.plan.action_offsets[tick + 1]];
    }
};

test "metal arena: sparse recovery shortens ranges and aliases safely" {
    const uses_a = [_]LiveRange{ .{ .first = 1, .last = 1 }, .{ .first = 8, .last = 8 } };
    const uses_b = [_]LiveRange{.{ .first = 4, .last = 5 }};
    const uses_c = [_]LiveRange{ .{ .first = 2, .last = 2 }, .{ .first = 7, .last = 7 } };
    const logical = [_]LogicalBuffer{
        .{ .id = 1, .size_bytes = 4096, .alignment = 4096, .live_ranges = &uses_a, .recompute_cost_ns = 10 },
        .{ .id = 2, .size_bytes = 4096, .alignment = 4096, .live_ranges = &uses_b },
        .{ .id = 3, .size_bytes = 2048, .alignment = 4096, .live_ranges = &uses_c, .spill_cost_ns = 20 },
    };
    var plan = try build(std.testing.allocator, &logical, 16 * 1024);
    defer plan.deinit();
    try std.testing.expectEqual(@as(u64, 16 * 1024), plan.total_bytes);
    try std.testing.expectEqual(Materialization.recompute, (try plan.binding(1)).materialization);
    try std.testing.expectEqual(Materialization.spill, (try plan.binding(3)).materialization);
    try plan.validate(16 * 1024);
}

test "metal arena: unrecoverable values retain their full interval" {
    const uses_a = [_]LiveRange{ .{ .first = 1, .last = 1 }, .{ .first = 8, .last = 8 } };
    const uses_b = [_]LiveRange{.{ .first = 4, .last = 4 }};
    const logical = [_]LogicalBuffer{
        .{ .id = 1, .size_bytes = 4096, .alignment = 4096, .live_ranges = &uses_a },
        .{ .id = 2, .size_bytes = 4096, .alignment = 4096, .live_ranges = &uses_b },
    };
    try std.testing.expectError(Error.BudgetExceeded, build(std.testing.allocator, &logical, 4096));
}

test "metal arena: epoch runner performs recovery around each local epoch" {
    const Hooks = struct {
        spills: usize = 0,
        restores: usize = 0,
        recomputes: usize = 0,
        fn spill(raw: *anyopaque, _: u16, _: Binding) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.spills += 1;
        }
        fn restore(raw: *anyopaque, _: u16, _: Binding) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.restores += 1;
        }
        fn recompute(raw: *anyopaque, _: u16, _: Binding) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.recomputes += 1;
        }
    };
    const uses_a = [_]LiveRange{ .{ .first = 1, .last = 1 }, .{ .first = 8, .last = 8 } };
    const uses_b = [_]LiveRange{ .{ .first = 2, .last = 2 }, .{ .first = 7, .last = 7 } };
    const logical = [_]LogicalBuffer{
        .{ .id = 1, .size_bytes = 4096, .alignment = 4096, .live_ranges = &uses_a, .spill_cost_ns = 10 },
        .{ .id = 2, .size_bytes = 4096, .alignment = 4096, .live_ranges = &uses_b, .recompute_cost_ns = 10 },
    };
    var plan = try build(std.testing.allocator, &logical, 16 * 1024);
    defer plan.deinit();
    var runner = try EpochRunner.init(std.testing.allocator, &plan);
    defer runner.deinit();
    var counters = Hooks{};
    const hooks = RecoveryHooks{ .context = &counters, .spill = Hooks.spill, .restore = Hooks.restore, .recompute = Hooks.recompute };
    for ([_]u16{ 1, 2, 7, 8 }) |tick| {
        try runner.begin(tick, hooks);
        try runner.end(tick, hooks);
    }
    try std.testing.expectEqual(@as(usize, 1), counters.spills);
    try std.testing.expectEqual(@as(usize, 1), counters.restores);
    try std.testing.expectEqual(@as(usize, 1), counters.recomputes);
}
