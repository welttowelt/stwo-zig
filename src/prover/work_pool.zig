//! Unified global work pool for all proving phases.
//!
//! Replaces 3 separate thread pools (FFT, Merkle, PoW) with one shared pool.
//! Lazy initialization on first use. Thread-safe via mutex.
//! Worker count auto-detected from CPU cores, overridable via STWO_ZIG_WORKERS.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_WORKERS: usize = 16;
pub const WORKER_STACK_SIZE: usize = 1 << 20; // 1 MiB

pub const WorkPool = struct {
    pool: std.Thread.Pool,
    n_workers: usize,

    pub fn init() !WorkPool {
        const n_workers = detectWorkerCount();
        if (n_workers <= 1) return error.SingleThreaded;

        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = std.heap.page_allocator,
            .n_jobs = n_workers - 1, // main thread is worker 0
            .stack_size = WORKER_STACK_SIZE,
        });
        return .{ .pool = pool, .n_workers = n_workers };
    }

    pub fn deinit(self: *WorkPool) void {
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn spawnWg(
        self: *WorkPool,
        wg: *std.Thread.WaitGroup,
        comptime func: anytype,
        args: anytype,
    ) void {
        self.pool.spawnWg(wg, func, args);
    }

    pub fn workerCount(self: WorkPool) usize {
        return self.n_workers;
    }
};

// Global singleton
var global_state: struct {
    mutex: std.Thread.Mutex = .{},
    pool: ?WorkPool = null,
    init_failed: bool = false,
} = .{};

/// Get or initialize the global work pool.
/// Returns null on single-threaded builds or if initialization fails.
pub fn getGlobalPool() ?*WorkPool {
    if (comptime builtin.single_threaded) return null;
    if (comptime builtin.is_test) return null; // Don't spawn threads in tests

    global_state.mutex.lock();
    defer global_state.mutex.unlock();

    if (global_state.init_failed) return null;
    if (global_state.pool != null) return &global_state.pool.?;

    global_state.pool = WorkPool.init() catch {
        global_state.init_failed = true;
        return null;
    };
    return &global_state.pool.?;
}

fn detectWorkerCount() usize {
    // Check env override
    if (!builtin.is_test) {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "STWO_ZIG_WORKERS")) |val| {
            defer std.heap.page_allocator.free(val);
            if (std.fmt.parseInt(usize, val, 10)) |n| {
                return @min(n, MAX_WORKERS);
            } else |_| {}
        } else |_| {}
    }

    const cpu_count = std.Thread.getCpuCount() catch return 1;
    return @min(cpu_count, MAX_WORKERS);
}

// Tests
test "work_pool: detectWorkerCount returns positive" {
    const n = detectWorkerCount();
    try std.testing.expect(n >= 1);
}

test "work_pool: getGlobalPool returns null in test mode" {
    // In test mode, pool is disabled to avoid thread interference
    try std.testing.expect(getGlobalPool() == null);
}

test "work_pool: MAX_WORKERS is reasonable" {
    try std.testing.expect(MAX_WORKERS >= 1);
    try std.testing.expect(MAX_WORKERS <= 64);
}
