//! Multi-GPU device context for memory-aware scheduling.
//!
//! `DeviceContext` enumerates available CUDA devices and tracks their
//! memory utilisation so that callers can pick the best device for a
//! given allocation.
//!
//! At link time, when `libstwo_cuda` is present, `init` queries the
//! CUDA runtime for real memory information. In test-only builds the
//! struct still compiles with stub data.

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("ffi.zig");

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
    /// When running under `zig build test` (no CUDA library linked) this
    /// falls back to a single pseudo-device with zeroed memory counters
    /// so that the rest of the test suite can compile and run.
    pub fn init(allocator: std.mem.Allocator) !DeviceContext {
        if (comptime builtin.is_test) {
            // Test-only stub: no real CUDA runtime available.
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

        // --- Real CUDA path ------------------------------------------------
        // Probe device 0.  Multi-GPU support can be extended by iterating
        // device IDs (requires a cudaGetDeviceCount FFI, not yet exposed).
        var free_mem: usize = 0;
        var total_mem: usize = 0;
        ffi.cuda_get_memory_info(&free_mem, &total_mem);

        const devices = try allocator.alloc(DeviceInfo, 1);
        devices[0] = DeviceInfo{
            .id = 0,
            .total_memory = total_mem,
            .free_memory = free_mem,
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
        // TODO: call cudaSetDevice(id) via FFI when multi-GPU is wired.
    }

    /// Return the device ordinal with the most free memory that can
    /// satisfy `bytes_needed`.  Falls back to device 0 when no device
    /// has enough reported free memory (the CUDA runtime will still
    /// try to allocate -- this is advisory).
    pub fn bestDeviceForAlloc(self: *DeviceContext, bytes_needed: usize) u32 {
        self.refreshMemoryInfo();
        var best_id: u32 = 0;
        var best_free: usize = 0;
        for (self.devices) |dev| {
            if (dev.free_memory > best_free and dev.free_memory >= bytes_needed) {
                best_free = dev.free_memory;
                best_id = dev.id;
            }
        }
        return best_id;
    }

    /// Re-query each device's free memory from the CUDA runtime.
    pub fn refreshMemoryInfo(self: *DeviceContext) void {
        if (comptime builtin.is_test) return; // No CUDA runtime in tests.

        for (self.devices) |*dev| {
            // TODO: call cudaSetDevice(dev.id) before querying when
            // multi-GPU is fully wired.
            var free_mem: usize = 0;
            var total_mem: usize = 0;
            ffi.cuda_get_memory_info(&free_mem, &total_mem);
            dev.free_memory = free_mem;
            dev.total_memory = total_mem;
        }
    }

    // ---------------------------------------------------------
    // Peer-to-peer transfer
    // ---------------------------------------------------------

    /// Copy `size` bytes between two devices.
    ///
    /// When `src_dev == dst_dev` this is a same-device copy using the
    /// existing host-bounce path (the FFI does not yet expose
    /// cudaMemcpyDeviceToDevice). Cross-device copies require
    /// `cudaMemcpyPeer` which is not yet exposed; for now we panic to
    /// make the gap explicit.
    pub fn transferP2P(
        self: *DeviceContext,
        src_dev: u32,
        dst_dev: u32,
        src: *anyopaque,
        dst: *anyopaque,
        size: usize,
    ) void {
        _ = self;
        if (src_dev == dst_dev) {
            const n_words: u32 = @intCast(size / @sizeOf(u32));
            // Same-device: bounce through host memory.
            // Use the page allocator for the host-side bounce buffer instead
            // of cuda_malloc (which allocates on the device, not the host).
            const host_alloc = std.heap.page_allocator;
            const tmp = host_alloc.alloc(u32, n_words) catch
                @panic("transferP2P: failed to allocate host bounce buffer");
            defer host_alloc.free(tmp);
            // Step 1: Download src device buffer into host bounce buffer.
            ffi.copy_uint32_t_vec_from_device_to_host(@ptrCast(src), @ptrCast(tmp.ptr), n_words);
            // Step 2: Upload host bounce into a new device allocation.
            // The current FFI always allocates a new device buffer on upload,
            // so we need an intermediate allocation and a second download to
            // land the data in the caller-provided dst pointer. A proper D2D
            // copy FFI would eliminate this extra round-trip.
            const uploaded = ffi.copy_uint32_t_vec_from_host_to_device(@ptrCast(tmp.ptr), n_words);
            if (uploaded == null) @panic("transferP2P: failed to re-upload bounce buffer");
            defer ffi.cuda_free_memory(@ptrCast(uploaded));
            // Step 3: Download from intermediate device buffer into dst.
            ffi.copy_uint32_t_vec_from_device_to_host(@ptrCast(uploaded), @ptrCast(dst), n_words);
        } else {
            @panic("Cross-device P2P not yet implemented - requires cudaMemcpyPeer FFI");
        }
    }
};

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "cuda: DeviceContext init and deinit" {
    var ctx = try DeviceContext.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 0), ctx.active_device);
    try std.testing.expect(ctx.devices.len > 0);
}

test "cuda: DeviceContext setDevice" {
    var ctx = try DeviceContext.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.setDevice(0);
    try std.testing.expectEqual(@as(u32, 0), ctx.active_device);
}

test "cuda: bestDeviceForAlloc returns 0 in test mode" {
    var ctx = try DeviceContext.init(std.testing.allocator);
    defer ctx.deinit();

    // In test mode all free_memory is 0, so best device falls back to 0.
    const dev = ctx.bestDeviceForAlloc(1024);
    try std.testing.expectEqual(@as(u32, 0), dev);
}

test "cuda: DeviceInfo struct layout" {
    try std.testing.expectEqual(@as(usize, @sizeOf(u32) + 2 * @sizeOf(usize)), @sizeOf(DeviceInfo));
}

test "cuda: refreshMemoryInfo is no-op in tests" {
    var ctx = try DeviceContext.init(std.testing.allocator);
    defer ctx.deinit();

    // Should not crash.
    ctx.refreshMemoryInfo();
    // Memory stays at 0 in test mode.
    try std.testing.expectEqual(@as(usize, 0), ctx.devices[0].free_memory);
}
