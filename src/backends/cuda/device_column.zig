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
        /// The `allocator` parameter is accepted for API symmetry with
        /// CPU backends but is unused -- device memory is allocated via
        /// the CUDA runtime.
        pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
            _ = allocator;
            const n_words: u32 = @intCast(self.size * words_per_elem);
            // Allocate a fresh device buffer and copy device-to-device
            // via a host bounce (the FFI does not expose cudaMemcpyD2D).
            var new_col = try allocOnDevice(self.size, self.device_id);
            // Use host-to-device round-trip: download then re-upload.
            // This is correct though not optimal; a D2D FFI can be added later.
            const tmp_host = ffi.cuda_malloc_uint32_t(n_words);
            if (tmp_host == null) {
                ffi.cuda_free_memory(new_col.device_ptr);
                new_col.device_ptr = null;
                return error.CudaAllocFailed;
            }
            // device -> host bounce buffer
            ffi.copy_uint32_t_vec_from_device_to_host(
                @ptrCast(self.device_ptr),
                tmp_host.?,
                n_words,
            );
            // host bounce -> new device buffer
            const uploaded = ffi.copy_uint32_t_vec_from_host_to_device(
                tmp_host.?,
                n_words,
            );
            if (uploaded == null) {
                ffi.cuda_free_memory(new_col.device_ptr);
                new_col.device_ptr = null;
                return error.CudaAllocFailed;
            }
            // Free the intermediate allocation and use the uploaded pointer.
            ffi.cuda_free_memory(new_col.device_ptr);
            new_col.device_ptr = @ptrCast(uploaded);
            // tmp_host was a device allocation used as scratch; free it.
            ffi.cuda_free_memory(@ptrCast(tmp_host));
            return new_col;
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

const m31_mod = @import("../../core/fields/m31.zig");
const qm31_mod = @import("../../core/fields/qm31.zig");

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
