const std = @import("std");
const proof_plan = @import("proof_plan.zig");

pub const Stage = enum {
    seed,
    gather,
    compact,
    writer,
    feed,
};

pub const Hook = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, u32, Stage) anyerror!f64,

    pub fn run(self: Hook, component_index: u32, stage: Stage) !f64 {
        return self.run_fn(self.context, component_index, stage);
    }
};

pub const ComponentOperation = struct {
    component_index: u32,
    seed: ?Hook = null,
    gather: ?Hook = null,
    compact: ?Hook = null,
    writer: Hook,
    feed: ?Hook = null,
};

pub const ComponentTelemetry = struct {
    component_index: u32,
    gpu_ms: f64,
};

pub const ExecutionTelemetry = struct {
    components: []ComponentTelemetry,
    gpu_ms: f64,
};

pub const Error = error{
    MissingOperation,
    DuplicateOperation,
    InvalidComponentIndex,
    OperationOrderMismatch,
};

/// Executes one proof plan level at a time. Every component operation is an
/// indivisible seed/gather/compact -> writer -> feed sequence. Independent
/// components in a level may later be assigned to Metal command-buffer lanes;
/// the dependency and atomicity contract does not change.
pub const CairoWitnessScheduler = struct {
    allocator: std.mem.Allocator,
    plan: *const proof_plan.CairoProofPlan,
    operations: []ComponentOperation,

    pub fn init(
        allocator: std.mem.Allocator,
        plan: *const proof_plan.CairoProofPlan,
        operations: []const ComponentOperation,
    ) !CairoWitnessScheduler {
        if (operations.len != plan.components.len) return Error.MissingOperation;
        const owned = try allocator.dupe(ComponentOperation, operations);
        errdefer allocator.free(owned);
        std.mem.sortUnstable(ComponentOperation, owned, {}, struct {
            fn lessThan(_: void, lhs: ComponentOperation, rhs: ComponentOperation) bool {
                return lhs.component_index < rhs.component_index;
            }
        }.lessThan);
        for (owned, 0..) |operation, index| {
            if (operation.component_index >= plan.components.len) return Error.InvalidComponentIndex;
            if (index > 0 and owned[index - 1].component_index == operation.component_index)
                return Error.DuplicateOperation;
            if (operation.component_index != index) return Error.MissingOperation;
        }
        return .{ .allocator = allocator, .plan = plan, .operations = owned };
    }

    pub fn deinit(self: *CairoWitnessScheduler) void {
        self.allocator.free(self.operations);
        self.* = undefined;
    }

    pub fn execute(self: *CairoWitnessScheduler, allocator: std.mem.Allocator) !ExecutionTelemetry {
        const telemetry = try allocator.alloc(ComponentTelemetry, self.plan.components.len);
        errdefer allocator.free(telemetry);
        var completed = try std.DynamicBitSetUnmanaged.initEmpty(allocator, self.plan.components.len);
        defer completed.deinit(allocator);
        var total_gpu_ms: f64 = 0;
        var telemetry_count: usize = 0;
        for (self.plan.levels) |level| {
            for (level.component_indices) |component_index| {
                const component = self.plan.components[component_index];
                for (component.producer_edges) |edge| {
                    const producer = self.plan.componentIndex(edge.producer) orelse return Error.OperationOrderMismatch;
                    if (!completed.isSet(producer)) return Error.OperationOrderMismatch;
                }
                for (component.capacity_feeds) |feed| {
                    const producer = self.plan.componentIndex(feed.producer) orelse return Error.OperationOrderMismatch;
                    if (!completed.isSet(producer)) return Error.OperationOrderMismatch;
                }
                const gpu_ms = try executeComponent(self.operations[component_index]);
                telemetry[telemetry_count] = .{ .component_index = component_index, .gpu_ms = gpu_ms };
                telemetry_count += 1;
                total_gpu_ms += gpu_ms;
                completed.set(component_index);
            }
        }
        if (telemetry_count != telemetry.len) return Error.MissingOperation;
        return .{ .components = telemetry, .gpu_ms = total_gpu_ms };
    }
};

fn executeComponent(operation: ComponentOperation) !f64 {
    var gpu_ms: f64 = 0;
    if (operation.seed) |hook| gpu_ms += try hook.run(operation.component_index, .seed);
    if (operation.gather) |hook| gpu_ms += try hook.run(operation.component_index, .gather);
    if (operation.compact) |hook| gpu_ms += try hook.run(operation.component_index, .compact);
    gpu_ms += try operation.writer.run(operation.component_index, .writer);
    if (operation.feed) |hook| gpu_ms += try hook.run(operation.component_index, .feed);
    return gpu_ms;
}

test "Cairo witness scheduler preserves component atomicity and levels" {
    const rows = [_]proof_plan.TracePart{.{ .id = .main, .rows = .{ .real_rows = 16, .padded_rows = 16 } }};
    const edge = [_]proof_plan.ProducerEdge{.{
        .producer = "producer",
        .word_base = 0,
        .words_per_instance = 1,
        .instances = 1,
    }};
    const components = [_]proof_plan.Component{
        .{
            .name = "producer",
            .canonical_ordinal = 0,
            .writer = .recorded_aot,
            .trace_parts = &rows,
            .producer_edges = &.{},
            .capacity_feeds = &.{},
        },
        .{
            .name = "consumer",
            .canonical_ordinal = 1,
            .writer = .recorded_aot,
            .trace_parts = &rows,
            .producer_edges = &edge,
            .capacity_feeds = &.{},
        },
    };
    var plan = try proof_plan.CairoProofPlan.init(std.testing.allocator, &components);
    defer plan.deinit();

    const Context = struct {
        calls: [8]u8 = [_]u8{0} ** 8,
        len: usize = 0,

        fn run(raw: *anyopaque, component: u32, stage: Stage) !f64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls[self.len] = @as(u8, @intCast(component * 8)) + @intFromEnum(stage);
            self.len += 1;
            return 1;
        }
    };
    var context = Context{};
    const hook = Hook{ .context = &context, .run_fn = Context.run };
    const operations = [_]ComponentOperation{
        .{ .component_index = 1, .gather = hook, .writer = hook, .feed = hook },
        .{ .component_index = 0, .seed = hook, .writer = hook, .feed = hook },
    };
    var scheduler = try CairoWitnessScheduler.init(std.testing.allocator, &plan, &operations);
    defer scheduler.deinit();
    const result = try scheduler.execute(std.testing.allocator);
    defer std.testing.allocator.free(result.components);
    try std.testing.expectEqual(@as(f64, 6), result.gpu_ms);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 4, 9, 11, 12 }, context.calls[0..context.len]);
}
