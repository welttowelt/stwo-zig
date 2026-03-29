//! Allocator using explicit mmap with OS page management hints.
//!
//! Provides MADV_SEQUENTIAL for linear access patterns (Merkle layer hashing)
//! and MADV_DONTNEED to release physical pages without unmapping.

const std = @import("std");
const builtin = @import("builtin");

pub const MmapAllocator = struct {
    /// Get a std.mem.Allocator backed by mmap with sequential hint.
    pub fn allocator() std.mem.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free_fn,
            },
        };
    }

    fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
        if (len == 0) return @as([*]u8, @ptrFromInt(std.mem.page_size)); // sentinel

        const page_size = std.mem.page_size;
        const total = std.mem.alignForward(usize, len, page_size);

        if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
            const buf = std.posix.mmap(
                null,
                total,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            ) catch return null;

            // Hint: this memory will be accessed sequentially
            adviseSequential(buf.ptr, total);

            return buf.ptr;
        }

        // Fallback for other platforms
        return std.heap.page_allocator.vtable.alloc(std.heap.page_allocator.ptr, len, 0, 0);
    }

    fn resize(_: *anyopaque, _: [*]u8, _: usize, _: usize, _: u8, _: usize) bool {
        return false;
    }

    fn free_fn(_: *anyopaque, buf: [*]u8, len: usize, _: u8, _: usize) void {
        if (len == 0) return;
        const page_size = std.mem.page_size;
        const total = std.mem.alignForward(usize, len, page_size);

        if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
            const slice: []align(std.mem.page_size) u8 = @alignCast(buf[0..total]);
            std.posix.munmap(slice);
        } else {
            std.heap.page_allocator.vtable.free(std.heap.page_allocator.ptr, buf, len, 0, 0);
        }
    }
};

/// Hint to the OS that memory will be accessed sequentially.
pub fn adviseSequential(ptr: [*]u8, len: usize) void {
    if (comptime builtin.os.tag == .linux) {
        const aligned_ptr: [*]align(std.mem.page_size) u8 = @alignCast(ptr);
        std.posix.madvise(aligned_ptr, len, .SEQUENTIAL);
    }
    if (comptime builtin.os.tag == .macos) {
        const aligned_ptr: [*]align(std.mem.page_size) u8 = @alignCast(ptr);
        std.posix.madvise(aligned_ptr, len, .SEQUENTIAL);
    }
}

/// Release physical pages without unmapping virtual addresses.
/// The next access will trigger a page fault and get zeroed pages.
pub fn adviseDontNeed(ptr: [*]u8, len: usize) void {
    if (comptime builtin.os.tag == .linux) {
        const aligned_ptr: [*]align(std.mem.page_size) u8 = @alignCast(ptr);
        std.posix.madvise(aligned_ptr, len, .DONTNEED);
    }
    if (comptime builtin.os.tag == .macos) {
        // macOS equivalent: MADV_FREE lets the OS reclaim pages lazily
        const aligned_ptr: [*]align(std.mem.page_size) u8 = @alignCast(ptr);
        std.posix.madvise(aligned_ptr, len, .FREE);
    }
}

test "mmap_alloc: basic alloc and free" {
    const a = MmapAllocator.allocator();
    const buf = try a.alloc(u8, 4096);
    try std.testing.expectEqual(@as(usize, 4096), buf.len);
    a.free(buf);
}

test "mmap_alloc: large allocation" {
    const a = MmapAllocator.allocator();
    const buf = try a.alloc(u32, 1024 * 1024); // 4MB
    buf[0] = 42;
    buf[1023 * 1024] = 99;
    try std.testing.expectEqual(@as(u32, 42), buf[0]);
    try std.testing.expectEqual(@as(u32, 99), buf[1023 * 1024]);
    a.free(buf);
}
