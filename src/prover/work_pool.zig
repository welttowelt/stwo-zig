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

    // Apple parts may expose more than one fast-core tier. In particular,
    // newer Max parts report both "Super" and "Performance" levels before
    // the "Efficiency" level. Treating perflevel0 as the whole fast-core
    // population can therefore leave most high-performance CPUs idle.
    const fast_cores = detectFastCoreCount();
    const cpu_count = fast_cores orelse (std.Thread.getCpuCount() catch return 1);
    return @min(cpu_count, MAX_WORKERS);
}

/// Sum every named Apple fast-core tier while excluding Efficiency cores.
///
/// The allowlist is deliberately fail-closed: an unknown topology name or a
/// partial sysctl read returns null, and the caller preserves the prior total-
/// logical-CPU behavior. This avoids silently under-subscribing a future Apple
/// topology whose tier names differ.
fn detectFastCoreCount() ?usize {
    if (builtin.os.tag != .macos) return null;

    const level_count = readSysctlPositiveInt("hw.nperflevels") orelse return null;
    var fast_cores: usize = 0;
    var level: usize = 0;
    while (level < level_count) : (level += 1) {
        var name_key_buf: [64]u8 = undefined;
        const name_key = std.fmt.bufPrintZ(
            &name_key_buf,
            "hw.perflevel{d}.name",
            .{level},
        ) catch return null;
        var count_key_buf: [64]u8 = undefined;
        const count_key = std.fmt.bufPrintZ(
            &count_key_buf,
            "hw.perflevel{d}.logicalcpu",
            .{level},
        ) catch return null;

        var name_buf: [64]u8 = undefined;
        var name_len: usize = name_buf.len;
        const name_rc = std.c.sysctlbyname(
            name_key,
            &name_buf,
            &name_len,
            null,
            0,
        );
        if (name_rc != 0 or name_len == 0 or name_len > name_buf.len) return null;
        const name = std.mem.sliceTo(name_buf[0..name_len], 0);
        const logical_cpus = readSysctlPositiveInt(count_key) orelse return null;

        if (isFastCoreTier(name)) {
            fast_cores = std.math.add(usize, fast_cores, logical_cpus) catch return null;
        } else if (!std.mem.eql(u8, name, "Efficiency")) {
            return null;
        }
    }
    return if (fast_cores > 0) fast_cores else null;
}

fn readSysctlPositiveInt(name: [:0]const u8) ?usize {
    var value: c_int = 0;
    var len: usize = @sizeOf(c_int);
    const rc = std.c.sysctlbyname(name, &value, &len, null, 0);
    if (rc != 0 or len != @sizeOf(c_int) or value <= 0) return null;
    return @intCast(value);
}

fn isFastCoreTier(name: []const u8) bool {
    return std.mem.eql(u8, name, "Super") or
        std.mem.eql(u8, name, "Performance");
}

// Tests
test "work_pool: detectWorkerCount returns positive" {
    const n = detectWorkerCount();
    try std.testing.expect(n >= 1);
}

test "work_pool: Apple fast-tier names are explicit" {
    try std.testing.expect(isFastCoreTier("Super"));
    try std.testing.expect(isFastCoreTier("Performance"));
    try std.testing.expect(!isFastCoreTier("Efficiency"));
    try std.testing.expect(!isFastCoreTier("Unknown"));
}

test "work_pool: Apple fast-core probe is complete and bounded" {
    if (builtin.os.tag != .macos) return;
    const fast_cores = detectFastCoreCount() orelse return error.MissingFastCoreTopology;
    const total_cores = try std.Thread.getCpuCount();
    try std.testing.expect(fast_cores >= 1);
    try std.testing.expect(fast_cores <= total_cores);
}

test "work_pool: getGlobalPool returns null in test mode" {
    // In test mode, pool is disabled to avoid thread interference
    try std.testing.expect(getGlobalPool() == null);
}

test "work_pool: MAX_WORKERS is reasonable" {
    try std.testing.expect(MAX_WORKERS >= 1);
    try std.testing.expect(MAX_WORKERS <= 64);
}
