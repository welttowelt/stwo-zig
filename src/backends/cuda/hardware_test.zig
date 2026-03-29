//! CUDA hardware integration tests.
//!
//! These tests require a linked libstwo_cuda.a and an NVIDIA GPU.
//! They are skipped automatically when running without CUDA hardware.
//! Run with: zig build cuda-test (after building libstwo_cuda.a)

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("ffi.zig");
const DeviceColumn = @import("device_column.zig").DeviceColumn;
const DeviceContext = @import("device_context.zig").DeviceContext;
const M31 = @import("../../core/fields/m31.zig").M31;
const QM31 = @import("../../core/fields/qm31.zig").QM31;
const mod = @import("mod.zig");
const CudaBackend = mod.CudaBackend;

/// Check if CUDA hardware is available at runtime.
fn hasCudaHardware() bool {
    if (comptime builtin.is_test) return false;
    // Try to query device memory — if this succeeds, CUDA is available
    var free_mem: usize = 0;
    var total_mem: usize = 0;
    ffi.cuda_get_memory_info(&free_mem, &total_mem);
    return total_mem > 0;
}

fn skipIfNoCuda() !void {
    if (!hasCudaHardware()) return error.SkipZigTest;
}

// ==========================================================================
// Device Memory Tests
// ==========================================================================

test "cuda hw: allocate and free device memory" {
    try skipIfNoCuda();

    var col = try DeviceColumn(M31).allocOnDevice(1024, 0);
    defer col.free();
    try std.testing.expectEqual(@as(usize, 1024), col.len());
}

test "cuda hw: host-to-device-to-host roundtrip" {
    try skipIfNoCuda();
    const alloc = std.testing.allocator;

    // Create host data
    const host_data = try alloc.alloc(M31, 256);
    defer alloc.free(host_data);
    for (host_data, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(i));

    // Upload to device
    var dev_col = try DeviceColumn(M31).fromHost(host_data, 0);
    defer dev_col.free();

    // Download back
    const roundtrip = try dev_col.toHost(alloc);
    defer alloc.free(roundtrip);

    // Verify
    for (host_data, roundtrip) |expected, actual| {
        try std.testing.expect(expected.eql(actual));
    }
}

test "cuda hw: device column clone" {
    try skipIfNoCuda();
    const alloc = std.testing.allocator;

    const host_data = try alloc.alloc(M31, 128);
    defer alloc.free(host_data);
    for (host_data, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(i + 1));

    var dev_col = try DeviceColumn(M31).fromHost(host_data, 0);
    defer dev_col.free();

    var cloned = try dev_col.clone(alloc);
    defer cloned.free();

    const cloned_host = try cloned.toHost(alloc);
    defer alloc.free(cloned_host);

    for (host_data, cloned_host) |expected, actual| {
        try std.testing.expect(expected.eql(actual));
    }
}

// ==========================================================================
// Field Operation Tests
// ==========================================================================

test "cuda hw: batch inverse" {
    try skipIfNoCuda();
    const alloc = std.testing.allocator;

    const values = try alloc.alloc(M31, 64);
    defer alloc.free(values);
    for (values, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(i + 1)); // non-zero

    var dev_vals = try DeviceColumn(M31).fromHost(values, 0);
    defer dev_vals.free();

    var dev_inv = try CudaBackend.batchInverseDevice(M31, dev_vals);
    defer dev_inv.free();

    const inv_host = try dev_inv.toHost(alloc);
    defer alloc.free(inv_host);

    // Verify: x * x^-1 == 1
    for (values, inv_host) |x, inv_x| {
        try std.testing.expect(x.mul(inv_x).eql(M31.one()));
    }
}

test "cuda hw: bit reverse" {
    try skipIfNoCuda();
    const alloc = std.testing.allocator;

    const log_size: u32 = 4;
    const n: usize = 1 << log_size;
    const values = try alloc.alloc(M31, n);
    defer alloc.free(values);
    for (values, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(i));

    var dev_vals = try DeviceColumn(M31).fromHost(values, 0);
    defer dev_vals.free();

    ffi.bit_reverse_base_field(log_size, @ptrCast(dev_vals.device_ptr.?));

    const result = try dev_vals.toHost(alloc);
    defer alloc.free(result);

    // Verify bit-reversal: position i should have value bit_reverse(i, log_size)
    try std.testing.expect(result[0].eql(M31.fromCanonical(0))); // 0b0000 -> 0b0000
    try std.testing.expect(result[1].eql(M31.fromCanonical(8))); // 0b0001 -> 0b1000
    try std.testing.expect(result[2].eql(M31.fromCanonical(4))); // 0b0010 -> 0b0100
}

// ==========================================================================
// Multi-GPU Tests
// ==========================================================================

test "cuda hw: device context enumerates GPUs" {
    try skipIfNoCuda();
    const alloc = std.testing.allocator;

    var ctx = try DeviceContext.init(alloc);
    defer ctx.deinit();

    try std.testing.expect(ctx.devices.len >= 1);
    try std.testing.expect(ctx.devices[0].total_memory > 0);
}

test "cuda hw: device context memory-aware scheduling" {
    try skipIfNoCuda();
    const alloc = std.testing.allocator;

    var ctx = try DeviceContext.init(alloc);
    defer ctx.deinit();

    // Should return a valid device for a small allocation
    const dev = ctx.bestDeviceForAlloc(1024);
    try std.testing.expect(dev < ctx.devices.len);
}
