//! Unified global work pool for all proving phases.
//!
//! Replaces 3 separate thread pools (FFT, Merkle, PoW) with one shared pool.
//! Lazy initialization on first use. Thread-safe via mutex.
//! Worker count auto-detected from CPU cores, overridable via STWO_ZIG_WORKERS.

const std = @import("std");
const builtin = @import("builtin");

/// Fixed storage ceiling, not a scheduling target. Modern Apple Max parts
/// expose more than 16 logical cores; detection still chooses the host count
/// (or the explicit override) below this fail-closed array bound.
pub const MAX_WORKERS: usize = 32;
pub const WORKER_STACK_SIZE: usize = 16 * 1024 * 1024; // 16 MiB (matches std default)

pub const WorkPool = struct {
    pool: std.Thread.Pool,
    n_workers: usize,

    /// Initialise the pool IN PLACE. The `std.Thread.Pool` spawns workers
    /// that hold a reference to the pool struct, so it must already live at
    /// its final address (i.e. the global singleton). Never call this on a
    /// stack-local variable and then move the result.
    pub fn initInPlace(self: *WorkPool) !void {
        const n_workers = detectWorkerCount();
        if (n_workers <= 1) return error.SingleThreaded;

        self.n_workers = n_workers;
        try self.pool.init(.{
            .allocator = std.heap.page_allocator,
            .n_jobs = n_workers - 1, // main thread is worker 0
            .stack_size = WORKER_STACK_SIZE,
        });
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
    pool: WorkPool = undefined,
    pool_initialized: bool = false,
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
    if (global_state.pool_initialized) return &global_state.pool;

    // Init the pool in-place at its final global address so spawned
    // worker threads hold a valid reference.
    global_state.pool.initInPlace() catch {
        global_state.init_failed = true;
        return null;
    };
    global_state.pool_initialized = true;
    return &global_state.pool;
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

    // Prefer the PERFORMANCE-core count over total logicals: E-cores drag
    // statically-chunked parallel stages (measured: wide -5.8% at P-only on
    // 8P+4E; the effect is a K3 static-scheduling artifact). Detected at
    // runtime so it transfers across hosts (e.g. an M5's larger P-cluster)
    // instead of hardcoding one machine's count. Falls back to total logical
    // cores where the probe is unavailable (non-Apple / CI), preserving prior
    // behavior there.
    const performance_cores = detectPerformanceCores();
    const cpu_count = performance_cores orelse (std.Thread.getCpuCount() catch return 1);
    return @min(cpu_count, MAX_WORKERS);
}

/// Apple-only: logical CPUs in the highest-performance core cluster
/// (`hw.perflevel0.logicalcpu`). Returns null off Apple or on any probe
/// failure, so callers fall back to the total logical count.
fn detectPerformanceCores() ?usize {
    if (builtin.os.tag != .macos) return null;
    var value: c_int = 0;
    var len: usize = @sizeOf(c_int);
    const rc = std.c.sysctlbyname("hw.perflevel0.logicalcpu", &value, &len, null, 0);
    if (rc != 0 or value <= 0) return null;
    return @intCast(value);
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
