//! Parallel ownership for the six independent fixed-table interactions.
//!
//! Workers write only their own task result. The caller joins and takes those
//! results in the canonical table order before any claim or column is exposed,
//! so scheduling cannot change the transcript-visible order.

const std = @import("std");
const component_order = @import("../air/component_order.zig");
const counter_mod = @import("../air/lookups/tables/counter.zig");
const lookup_table_interaction = @import("../air/lookups/tables/interaction.zig");
const relations_mod = @import("../air/relation_challenges.zig");
const work_pool = @import("stwo_prover_engine").work_pool;

const COUNT = component_order.LOOKUP_TABLE_COUNT;
const Result = lookup_table_interaction.Result;
const Relations = relations_mod.Relations;

pub const Batch = struct {
    tasks: [COUNT]Task,
    wait_group: std.Thread.WaitGroup = .{},
    started: bool = false,
    joined: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        counters: *const counter_mod.Set,
        relations: *const Relations,
    ) Batch {
        var result: Batch = undefined;
        result.wait_group = .{};
        result.started = false;
        result.joined = false;
        for (component_order.lookupTables(), 0..) |kind, index| {
            result.tasks[index] = Task.init(
                allocator,
                &counters.counters[@intFromEnum(kind)],
                relations,
            );
        }
        return result;
    }

    pub fn start(self: *Batch) void {
        self.startWithPool(work_pool.getGlobalPool());
    }

    fn startWithPool(self: *Batch, pool: ?*work_pool.WorkPool) void {
        std.debug.assert(!self.started);
        self.started = true;
        if (pool) |active_pool| {
            for (&self.tasks) |*task| {
                active_pool.spawnWg(&self.wait_group, Task.run, .{task});
            }
        } else {
            for (&self.tasks) |*task| task.run();
            self.joined = true;
        }
    }

    fn join(self: *Batch) void {
        if (!self.started or self.joined) return;
        self.wait_group.wait();
        self.joined = true;
    }

    pub fn take(self: *Batch, index: usize) !Result {
        std.debug.assert(self.started);
        std.debug.assert(index < self.tasks.len);
        self.join();
        return self.tasks[index].take();
    }

    pub fn deinit(self: *Batch) void {
        if (!self.started) return;
        self.join();
        for (&self.tasks) |*task| task.deinit();
        self.started = false;
        self.joined = false;
    }
};

const TaskOptions = struct {
    injected_error: ?anyerror = null,
};

const Task = struct {
    allocator: std.mem.Allocator,
    counter: *const counter_mod.Counter,
    relations: *const Relations,
    options: TaskOptions,
    result: ?Result = null,
    error_value: ?anyerror = null,

    fn init(
        allocator: std.mem.Allocator,
        counter: *const counter_mod.Counter,
        relations: *const Relations,
    ) Task {
        return .{
            .allocator = allocator,
            .counter = counter,
            .relations = relations,
            .options = .{},
        };
    }

    fn run(self: *Task) void {
        if (self.options.injected_error) |err| {
            self.error_value = err;
            return;
        }
        self.result = lookup_table_interaction.generate(
            self.allocator,
            self.counter,
            self.relations,
        ) catch |err| {
            self.error_value = err;
            return;
        };
    }

    fn take(self: *Task) !Result {
        if (self.error_value) |err| return err;
        const result = self.result orelse return error.TaskProducedNoResult;
        self.result = null;
        return result;
    }

    fn deinit(self: *Task) void {
        if (self.result) |*result| result.deinit(self.allocator);
        self.result = null;
    }
};

fn expectEqualResults(expected: *const Result, actual: *const Result) !void {
    try std.testing.expect(expected.claim.eql(actual.claim));
    for (expected.columns, actual.columns) |expected_column, actual_column| {
        try std.testing.expectEqualSlices(
            @import("stwo_core").fields.m31.M31,
            expected_column,
            actual_column,
        );
    }
}

pub fn testParallelLookupTableBatch() !void {
    const allocator = std.testing.allocator;
    const relations = Relations.dummy();
    const M31 = @import("stwo_core").fields.m31.M31;
    var counters = try counter_mod.Set.init(allocator);
    defer counters.deinit(allocator);
    for (component_order.lookupTables(), 0..) |kind, index| {
        const counter = &counters.counters[@intFromEnum(kind)];
        counter.values[index] = M31.fromU64(index + 1);
        counter.values[counter.values.len / 2] = M31.fromU64(index + 7).neg();
    }

    var batch = Batch.init(allocator, &counters, &relations);
    defer batch.deinit();
    batch.startWithPool(null);
    for (component_order.lookupTables(), 0..) |kind, index| {
        var serial = try lookup_table_interaction.generate(
            allocator,
            &counters.counters[@intFromEnum(kind)],
            &relations,
        );
        defer serial.deinit(allocator);
        var threaded = try batch.take(index);
        defer threaded.deinit(allocator);
        try expectEqualResults(&serial, &threaded);
    }

    var failed_batch = Batch.init(allocator, &counters, &relations);
    failed_batch.tasks[0].options = .{
        .injected_error = error.TestInjectedFailure,
    };
    failed_batch.startWithPool(null);
    try std.testing.expectError(
        error.TestInjectedFailure,
        failed_batch.take(0),
    );
    // This is the production error path: the first canonical task failed, so
    // the remaining five results were never taken. Cleanup must still join
    // every worker and free every owned result.
    failed_batch.deinit();
    try std.testing.expect(!failed_batch.started);

    var abandoned_batch = Batch.init(allocator, &counters, &relations);
    abandoned_batch.startWithPool(null);
    abandoned_batch.deinit();
    try std.testing.expect(!abandoned_batch.started);
}
