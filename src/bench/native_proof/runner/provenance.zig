//! Native benchmark source and environment provenance capture.

const std = @import("std");
const report = @import("../report.zig");

const override_names = [_][]const u8{
    "STWO_ZIG_WORKERS",
    "STWO_ZIG_POW_WORKERS",
    "STWO_ZIG_MERKLE_WORKERS",
    "STWO_ZIG_LEAF_BATCH_SIZE",
    "STWO_ZIG_MERKLE_POOL_REUSE",
    "STWO_ZIG_METAL_RADIX4_RFFT",
    "STWO_ZIG_METAL_CACHE_DIR",
};

pub const Owned = struct {
    git_commit: []u8,
    environment_overrides: []report.EnvironmentOverride,

    pub fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.git_commit);
        for (self.environment_overrides) |entry| allocator.free(entry.value);
        allocator.free(self.environment_overrides);
        self.* = undefined;
    }
};

pub fn collect(allocator: std.mem.Allocator) !Owned {
    const git_commit = try runCommand(allocator, &.{ "git", "rev-parse", "HEAD" });
    errdefer allocator.free(git_commit);
    if (git_commit.len != 40) return error.InvalidGitCommit;

    var overrides = std.ArrayList(report.EnvironmentOverride).empty;
    errdefer {
        for (overrides.items) |entry| allocator.free(entry.value);
        overrides.deinit(allocator);
    }
    for (override_names) |name| {
        const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        };
        try overrides.append(allocator, .{ .name = name, .value = value });
    }
    return .{
        .git_commit = git_commit,
        .environment_overrides = try overrides.toOwnedSlice(allocator),
    };
}

pub fn collectGitStatus(allocator: std.mem.Allocator) ![]u8 {
    return runCommand(
        allocator,
        &.{ "git", "status", "--porcelain", "--untracked-files=normal" },
    );
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ProvenanceCommandFailed,
        else => return error.ProvenanceCommandFailed,
    }
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}
