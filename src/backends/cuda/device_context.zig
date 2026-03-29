//! Multi-GPU device context for memory-aware scheduling.
//!
//! `DeviceContext` enumerates available CUDA devices and tracks their
//! memory utilisation so that callers can pick the best device for a
//! given allocation.
//!
//! Current status: **stub** -- the implementation assumes a single
//! device (id 0) with unknown memory capacity. Real enumeration will
//! be wired once the CUDA runtime is linked.

const std = @import("std");

/// Static information about a single CUDA device.
pub const DeviceInfo = struct {
    /// Zero-based device ordinal.
    id: u32,
    /// Total device memory in bytes (0 = unknown / stub).
    total_memory: usize,
    /// Approximate free memory in bytes at last refresh.
    free_memory: usize,
};

/// Manages one or more CUDA devices.
pub const DeviceContext = struct {
    /// Per-device metadata, indexed by device ordinal.
    devices: []DeviceInfo,
    /// Currently selected device for new allocations / kernel launches.
    active_device: u32,
    /// Allocator used for the `devices` slice itself.
    allocator: std.mem.Allocator,

    // ---------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------

    /// Enumerate available CUDA devices and populate initial memory info.
    ///
    /// Stub: creates a single pseudo-device with id 0.
    pub fn init(allocator: std.mem.Allocator) !DeviceContext {
        const devices = try allocator.alloc(DeviceInfo, 1);
        devices[0] = DeviceInfo{
            .id = 0,
            .total_memory = 0,
            .free_memory = 0,
        };
        return DeviceContext{
            .devices = devices,
            .active_device = 0,
            .allocator = allocator,
        };
    }

    /// Release resources held by this context.
    pub fn deinit(self: *DeviceContext) void {
        self.allocator.free(self.devices);
        self.devices = &.{};
    }

    // ---------------------------------------------------------
    // Device selection
    // ---------------------------------------------------------

    /// Set the active device for subsequent operations.
    pub fn setDevice(self: *DeviceContext, id: u32) void {
        std.debug.assert(id < self.devices.len);
        self.active_device = id;
        // TODO: call cudaSetDevice(id) when CUDA is linked.
    }

    /// Return the device ordinal with the most free memory.
    /// Useful for memory-aware work distribution across GPUs.
    pub fn bestDeviceForAlloc(self: *const DeviceContext, bytes_needed: usize) u32 {
        _ = bytes_needed;
        var best_id: u32 = 0;
        var best_free: usize = 0;
        for (self.devices) |dev| {
            if (dev.free_memory > best_free) {
                best_free = dev.free_memory;
                best_id = dev.id;
            }
        }
        return best_id;
    }

    /// Re-query each device's free memory from the CUDA runtime.
    ///
    /// Stub: no-op until CUDA is linked.
    pub fn refreshMemoryInfo(self: *DeviceContext) void {
        // TODO: for each device call cuda_get_memory_info via ffi.
        _ = self;
    }
};
