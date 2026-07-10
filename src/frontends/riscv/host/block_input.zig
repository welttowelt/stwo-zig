//! Ethereum block input loading for the host runtime.
//!
//! Loads pre-serialized block input files (produced by the
//! `prepare-block-input` tool) for use with the HostRuntime.

const std = @import("std");

/// Block input data for the Ethereum guest.
/// The serialized bytes are passed as a single hint to the guest
/// via the HostRuntime's hint oracle.
pub const BlockInput = struct {
    /// Raw serialized block input (postcard format).
    serialized: []const u8,
    allocator: std.mem.Allocator,

    /// Load block input from a file.
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !BlockInput {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024);
        return .{
            .serialized = data,
            .allocator = allocator,
        };
    }

    /// Create from raw bytes (takes ownership).
    pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) BlockInput {
        return .{
            .serialized = data,
            .allocator = allocator,
        };
    }

    /// Get the hint slice array for passing to HostRuntime.
    /// Returns a single-element slice pointing to the serialized data.
    pub fn asHints(self: *const BlockInput, buf: *[1][]const u8) []const []const u8 {
        buf[0] = self.serialized;
        return buf[0..1];
    }

    pub fn deinit(self: *BlockInput) void {
        self.allocator.free(self.serialized);
        self.* = undefined;
    }
};
