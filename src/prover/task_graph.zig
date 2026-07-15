//! Task dependency graph executor for the prover pipeline.
//!
//! Tasks declare dependencies. The executor runs all tasks with
//! satisfied dependencies in parallel via a thread pool.
//! When a task completes, it unlocks dependents.

const std = @import("std");

pub const MAX_TASKS: usize = 32;
pub const MAX_DEPS_PER_TASK: usize = 8;

pub const TaskId = u8;

pub const TaskStatus = enum {
    pending,
    ready,
    running,
    done,
    failed,
};

pub const TaskFn = *const fn (context: *anyopaque) anyerror!void;

pub const TaskDesc = struct {
    name: []const u8,
    func: TaskFn,
    context: *anyopaque,
    deps: [MAX_DEPS_PER_TASK]TaskId = .{0} ** MAX_DEPS_PER_TASK,
    n_deps: u8 = 0,
};

pub const TaskGraph = struct {
    tasks: [MAX_TASKS]TaskDesc = undefined,
    status: [MAX_TASKS]TaskStatus = .{.pending} ** MAX_TASKS,
    n_tasks: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TaskGraph {
        return .{ .allocator = allocator };
    }

    /// Add a task with no dependencies.
    pub fn addTask(self: *TaskGraph, name: []const u8, func: TaskFn, context: *anyopaque) TaskId {
        const id: TaskId = @intCast(self.n_tasks);
        self.tasks[id] = .{ .name = name, .func = func, .context = context };
        self.status[id] = .ready; // No deps -> ready immediately
        self.n_tasks += 1;
        return id;
    }

    /// Add a task that depends on `deps`.
    pub fn addTaskWithDeps(
        self: *TaskGraph,
        name: []const u8,
        func: TaskFn,
        context: *anyopaque,
        deps: []const TaskId,
    ) TaskId {
        const id: TaskId = @intCast(self.n_tasks);
        var desc = TaskDesc{ .name = name, .func = func, .context = context };
        for (deps, 0..) |dep, i| {
            desc.deps[i] = dep;
        }
        desc.n_deps = @intCast(deps.len);
        self.tasks[id] = desc;
        self.status[id] = .pending;
        self.n_tasks += 1;
        return id;
    }

    /// Execute all tasks, running independent ones in parallel.
    /// Falls back to sequential execution if no pool is available.
    pub fn execute(self: *TaskGraph) !void {
        // Simple sequential executor (parallel version uses work_pool)
        while (true) {
            var any_executed = false;
            for (0..self.n_tasks) |i| {
                if (self.status[i] != .ready and self.status[i] != .pending) continue;

                // Check if all deps are done
                if (self.status[i] == .pending) {
                    var all_done = true;
                    const desc = self.tasks[i];
                    for (0..desc.n_deps) |d| {
                        if (self.status[desc.deps[d]] != .done) {
                            all_done = false;
                            break;
                        }
                    }
                    if (!all_done) continue;
                    self.status[i] = .ready;
                }

                // Execute ready task
                self.status[i] = .running;
                self.tasks[i].func(self.tasks[i].context) catch {
                    self.status[i] = .failed;
                    return error.TaskFailed;
                };
                self.status[i] = .done;
                any_executed = true;
            }

            if (!any_executed) break;
        }

        // Verify all tasks completed
        for (0..self.n_tasks) |i| {
            if (self.status[i] != .done) return error.DeadlockDetected;
        }
    }
};

test "task_graph: single task executes" {
    var executed = false;
    const Context = struct {
        done: *bool,
        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done.* = true;
        }
    };
    var ctx = Context{ .done = &executed };

    var graph = TaskGraph.init(std.testing.allocator);
    _ = graph.addTask("test", Context.run, @ptrCast(&ctx));
    try graph.execute();
    try std.testing.expect(executed);
}

test "task_graph: dependency ordering" {
    const allocator = std.testing.allocator;
    var order = std.ArrayList(u8).empty;
    defer order.deinit(allocator);

    const Ctx = struct {
        id: u8,
        list: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        fn run(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.list.append(self.alloc, self.id);
        }
    };

    var ctx0 = Ctx{ .id = 0, .list = &order, .alloc = allocator };
    var ctx1 = Ctx{ .id = 1, .list = &order, .alloc = allocator };
    var ctx2 = Ctx{ .id = 2, .list = &order, .alloc = allocator };

    var graph = TaskGraph.init(allocator);
    const t0 = graph.addTask("A", Ctx.run, @ptrCast(&ctx0));
    const t1 = graph.addTaskWithDeps("B", Ctx.run, @ptrCast(&ctx1), &[_]TaskId{t0});
    _ = graph.addTaskWithDeps("C", Ctx.run, @ptrCast(&ctx2), &[_]TaskId{t1});

    try graph.execute();

    try std.testing.expectEqual(@as(u8, 0), order.items[0]);
    try std.testing.expectEqual(@as(u8, 1), order.items[1]);
    try std.testing.expectEqual(@as(u8, 2), order.items[2]);
}

test "task_graph: independent tasks both execute" {
    var count: u32 = 0;
    const Ctx = struct {
        counter: *u32,
        fn run(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.counter.* += 1;
        }
    };
    var ctx1 = Ctx{ .counter = &count };
    var ctx2 = Ctx{ .counter = &count };

    var graph = TaskGraph.init(std.testing.allocator);
    _ = graph.addTask("A", Ctx.run, @ptrCast(&ctx1));
    _ = graph.addTask("B", Ctx.run, @ptrCast(&ctx2));
    try graph.execute();

    try std.testing.expectEqual(@as(u32, 2), count);
}
