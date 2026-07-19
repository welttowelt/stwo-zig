//! GPU device memory column for the CUDA backend.
//!
//! `DeviceColumn(F)` wraps a raw CUDA device pointer and a length. It
//! is the CUDA counterpart of a plain `[]F` slice used by `CpuBackend`.
//!
//! When `libstwo_cuda` is linked at build time the methods delegate to
//! real CUDA memory management calls. In pure-test builds without the
//! library the types still compile (only runtime use would fail).

const std = @import("std");
const ffi = @import("ffi.zig");

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

        /// Number of u32 words per element.
        const words_per_elem: usize = elem_size / @sizeOf(u32);

        // ---------------------------------------------------------
        // Construction / destruction
        // ---------------------------------------------------------

        /// Allocate uninitialised device memory for `count` elements.
        pub fn allocOnDevice(count: usize, device_id: u32) !Self {
            const n_words = count * words_per_elem;
            const ptr = ffi.cuda_malloc_uint32_t(n_words);
            if (ptr == null) return error.CudaAllocFailed;
            return .{ .device_ptr = @ptrCast(ptr), .size = count, .device_id = device_id };
        }

        /// Allocate device memory and copy `host_data` into it.
        pub fn fromHost(host_data: []const F, device_id: u32) !Self {
            const n_words: u32 = @intCast(host_data.len * words_per_elem);
            const device_ptr = ffi.copy_uint32_t_vec_from_host_to_device(
                @ptrCast(host_data.ptr),
                n_words,
            );
            if (device_ptr == null) return error.CudaAllocFailed;
            return .{
                .device_ptr = @ptrCast(device_ptr),
                .size = host_data.len,
                .device_id = device_id,
            };
        }

        /// Copy the device buffer back to a freshly allocated host slice.
        pub fn toHost(self: Self, allocator: std.mem.Allocator) ![]F {
            const host_buf = try allocator.alloc(F, self.size);
            const n_words: u32 = @intCast(self.size * words_per_elem);
            ffi.copy_uint32_t_vec_from_device_to_host(
                @ptrCast(self.device_ptr),
                @ptrCast(host_buf.ptr),
                n_words,
            );
            return host_buf;
        }

        /// Release the device allocation.
        pub fn free(self: *Self) void {
            if (self.device_ptr) |ptr| {
                ffi.cuda_free_memory(ptr);
                self.device_ptr = null;
            }
        }

        /// Create an independent copy of this column on the same device.
        ///
        /// The `allocator` is used for a temporary host-side bounce buffer
        /// needed because the FFI does not expose cudaMemcpyDeviceToDevice.
        /// Data is downloaded to host memory, then re-uploaded to a fresh
        /// device allocation.
        pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
            const n_words = self.size * words_per_elem;

            // Allocate host-side bounce buffer using the Zig allocator.
            const tmp = try allocator.alloc(u32, n_words);
            defer allocator.free(tmp);

            // Download from source device buffer into host bounce buffer.
            ffi.copy_uint32_t_vec_from_device_to_host(
                @ptrCast(self.device_ptr.?),
                @ptrCast(tmp.ptr),
                @intCast(n_words),
            );

            // Upload from host bounce buffer into a new device allocation.
            const new_ptr = ffi.copy_uint32_t_vec_from_host_to_device(
                @ptrCast(tmp.ptr),
                @intCast(n_words),
            );
            if (new_ptr == null) return error.CudaAllocFailed;

            return .{ .device_ptr = @ptrCast(new_ptr), .size = self.size, .device_id = self.device_id };
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

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

const m31_mod = @import("stwo_core").fields.m31;
const qm31_mod = @import("stwo_core").fields.qm31;

const M31 = m31_mod.M31;
const QM31 = qm31_mod.QM31;

test "cuda: DeviceColumn type layout" {
    // DeviceColumn holds an optional pointer, a usize length, and a u32 device id.
    const ColM31 = DeviceColumn(M31);
    try std.testing.expectEqual(@as(usize, @sizeOf(?*anyopaque) + @sizeOf(usize) + @sizeOf(u32)), @sizeOf(ColM31));
}

test "cuda: DeviceColumn elem_size and words_per_elem" {
    try std.testing.expectEqual(@as(usize, 4), DeviceColumn(M31).elem_size);
    try std.testing.expectEqual(@as(usize, 16), DeviceColumn(QM31).elem_size);
    try std.testing.expectEqual(@as(usize, 1), DeviceColumn(M31).words_per_elem);
    try std.testing.expectEqual(@as(usize, 4), DeviceColumn(QM31).words_per_elem);
}

test "cuda: DeviceColumn zero-length accessors" {
    const col = DeviceColumn(M31){
        .device_ptr = null,
        .size = 0,
        .device_id = 0,
    };
    try std.testing.expectEqual(@as(usize, 0), col.len());
    try std.testing.expectEqual(@as(usize, 0), col.byteSize());
}

test "cuda: DeviceColumn free on null is safe" {
    var col = DeviceColumn(M31){
        .device_ptr = null,
        .size = 0,
        .device_id = 0,
    };
    // Should not panic or crash.
    col.free();
    try std.testing.expectEqual(@as(?*anyopaque, null), col.device_ptr);
}

test "cuda: clone accepts a Zig allocator (not device memory)" {
    // This test verifies the clone() signature requires a std.mem.Allocator
    // for the host bounce buffer, confirming the bug fix. We cannot call
    // clone() without a real CUDA device, but we can verify the function
    // signature accepts the allocator and that the type compiles correctly.
    const ColM31 = DeviceColumn(M31);
    const clone_fn_info = @typeInfo(@TypeOf(ColM31.clone));
    // clone takes (self: Self, allocator: std.mem.Allocator) -> !Self
    try std.testing.expectEqual(@as(usize, 2), clone_fn_info.@"fn".params.len);
    // Second parameter should be std.mem.Allocator.
    try std.testing.expect(clone_fn_info.@"fn".params[1].type == std.mem.Allocator);
    // Return type should be an error union.
    const return_info = @typeInfo(clone_fn_info.@"fn".return_type.?);
    try std.testing.expect(return_info == .error_union);
}

test "cuda: clone signature for QM31 columns" {
    const ColQM31 = DeviceColumn(QM31);
    const clone_fn_info = @typeInfo(@TypeOf(ColQM31.clone));
    try std.testing.expectEqual(@as(usize, 2), clone_fn_info.@"fn".params.len);
    try std.testing.expect(clone_fn_info.@"fn".params[1].type == std.mem.Allocator);
}
