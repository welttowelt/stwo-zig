//! Process-wide Native Metal runtime ownership.
//!
//! Backend calls hold shared leases while using the runtime. Resident objects
//! retain a separate resource count, so explicit shutdown can fail closed
//! instead of invalidating buffers or trees that outlive a call.

const std = @import("std");
const runtime_mod = @import("runtime.zig");

var runtime_lock: std.Thread.RwLock = .{};
var shared_runtime: ?runtime_mod.Runtime = null;
var runtime_initializations: std.atomic.Value(u64) = .init(0);
var runtime_shutdowns: std.atomic.Value(u64) = .init(0);
var active_call_leases: std.atomic.Value(u64) = .init(0);
var live_resident_resources: std.atomic.Value(u64) = .init(0);

pub const LifecycleSnapshot = struct {
    initialized: bool,
    active_call_leases: u64,
    live_resident_resources: u64,
    initialization_count: u64,
    shutdown_count: u64,
};

pub const ShutdownError = error{
    RuntimeBusy,
    ResidentResourcesLive,
};

pub const CallLease = struct {
    runtime: *runtime_mod.Runtime,

    pub fn deinit(_: *CallLease) void {
        _ = active_call_leases.fetchSub(1, .monotonic);
        runtime_lock.unlockShared();
    }
};

pub fn acquire() !CallLease {
    while (true) {
        runtime_lock.lockShared();
        if (shared_runtime) |*active_runtime| {
            _ = active_call_leases.fetchAdd(1, .monotonic);
            return .{ .runtime = active_runtime };
        }
        runtime_lock.unlockShared();

        runtime_lock.lock();
        defer runtime_lock.unlock();
        if (shared_runtime == null) {
            shared_runtime = try runtime_mod.Runtime.init();
            _ = runtime_initializations.fetchAdd(1, .monotonic);
        }
    }
}

pub fn acquireExisting() error{RuntimeNotInitialized}!CallLease {
    runtime_lock.lockShared();
    const active_runtime = if (shared_runtime) |*value| value else {
        runtime_lock.unlockShared();
        return error.RuntimeNotInitialized;
    };
    _ = active_call_leases.fetchAdd(1, .monotonic);
    return .{ .runtime = active_runtime };
}

/// Retains one resident object created while a call lease is active.
pub fn retainResidentResource() void {
    _ = live_resident_resources.fetchAdd(1, .monotonic);
}

pub fn releaseResidentResource() void {
    const previous = live_resident_resources.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);
}

pub fn destroyResidentBuffer(handle: *anyopaque) void {
    runtime_mod.ResidentBuffer.destroyOpaque(handle);
    releaseResidentResource();
}

pub fn lifecycleSnapshot() LifecycleSnapshot {
    runtime_lock.lockShared();
    defer runtime_lock.unlockShared();
    return .{
        .initialized = shared_runtime != null,
        .active_call_leases = active_call_leases.load(.monotonic),
        .live_resident_resources = live_resident_resources.load(.monotonic),
        .initialization_count = runtime_initializations.load(.monotonic),
        .shutdown_count = runtime_shutdowns.load(.monotonic),
    };
}

/// Releases the runtime only when no calls or backend-owned resident objects
/// can still reference it. A successful shutdown permits a later warmup.
pub fn shutdown() ShutdownError!void {
    if (!runtime_lock.tryLock()) return error.RuntimeBusy;
    defer runtime_lock.unlock();
    if (live_resident_resources.load(.acquire) != 0) {
        return error.ResidentResourcesLive;
    }
    if (shared_runtime) |*active_runtime| {
        active_runtime.deinit();
        shared_runtime = null;
        _ = runtime_shutdowns.fetchAdd(1, .monotonic);
    }
}

test "Metal shared runtime lifecycle observation does not initialize a device" {
    const lifecycle = lifecycleSnapshot();
    try std.testing.expect(lifecycle.initialization_count >= lifecycle.shutdown_count);
    try std.testing.expectEqual(
        lifecycle.initialized,
        lifecycle.initialization_count > lifecycle.shutdown_count,
    );
}

test "Metal shared runtime rejects shutdown while resident resources are live" {
    const before = lifecycleSnapshot().live_resident_resources;
    retainResidentResource();
    defer releaseResidentResource();

    try std.testing.expectEqual(before + 1, lifecycleSnapshot().live_resident_resources);
    try std.testing.expectError(error.ResidentResourcesLive, shutdown());
}

test "Metal shared runtime rejects shutdown while a call holds the read lock" {
    runtime_lock.lockShared();
    defer runtime_lock.unlockShared();
    try std.testing.expectError(error.RuntimeBusy, shutdown());
}
