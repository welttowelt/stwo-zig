//! GPU device memory column for the CUDA backend.
//!
//! `DeviceColumn(F)` wraps a raw CUDA device pointer and a length. It
//! is the CUDA counterpart of a plain `[]F` slice used by `CpuBackend`.
//!
//! Current status: **stub** -- all methods that would require a linked
//! CUDA runtime panic at runtime. The types themselves compile on any
//! host so that the rest of the codebase can be developed and tested
//! without a GPU toolchain.

const std = @import("std");

/// A column of field elements stored in CUDA device memory.
///
/// `F` is the field element type (e.g. `M31`, `CM31`, `QM31`).
pub fn DeviceColumn(comptime F: type) type {
    return struct {
        /// Opaque pointer to the device allocation (cast from `CUdeviceptr`).
        device_ptr: ?*anyopaque,
        /// Number of *elements* (not bytes) in the column.
        size: usize,
        /// Ordinal of the CUDA device that owns this allocation.
        device_id: u32,

        const Self = @This();

        /// Size in bytes of a single element.
        pub const elem_size: usize = @sizeOf(F);

        // ---------------------------------------------------------
        // Construction / destruction
        // ---------------------------------------------------------

        /// Allocate device memory and copy `host_data` into it.
        pub fn fromHost(host_data: []const F, device_id: u32) !Self {
            _ = host_data;
            _ = device_id;
            @panic("CUDA backend: link libstwo_cuda to use DeviceColumn.fromHost");
        }

        /// Copy the device buffer back to a freshly allocated host slice.
        pub fn toHost(self: Self, allocator: std.mem.Allocator) ![]F {
            _ = self;
            _ = allocator;
            @panic("CUDA backend: link libstwo_cuda to use DeviceColumn.toHost");
        }

        /// Release the device allocation.
        pub fn free(self: *Self) void {
            _ = self;
            @panic("CUDA backend: link libstwo_cuda to use DeviceColumn.free");
        }

        // ---------------------------------------------------------
        // Accessors
        // ---------------------------------------------------------

        /// Number of elements in the column.
        pub fn len(self: Self) usize {
            return self.size;
        }

        /// Size of the allocation in bytes.
        pub fn byteSize(self: Self) usize {
            return self.size * elem_size;
        }
    };
}
