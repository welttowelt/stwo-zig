//! Test-only fault injection at the backend ownership-transfer boundary.

const std = @import("std");
const builtin = @import("builtin");

var fail_after_transfer: std.atomic.Value(bool) = .init(false);

pub fn arm() void {
    if (comptime !builtin.is_test) @compileError("test-only Metal failure injection");
    fail_after_transfer.store(true, .release);
}

pub fn clear() void {
    if (comptime !builtin.is_test) @compileError("test-only Metal failure injection");
    fail_after_transfer.store(false, .release);
}

pub fn failAfterTransfer() !void {
    if (comptime builtin.is_test) {
        if (fail_after_transfer.swap(false, .acq_rel))
            return error.InjectedOwnershipTransferFailure;
    }
}
