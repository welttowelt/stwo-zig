const std = @import("std");

pub const Identity = struct {
    implementation_commit: [commit_hex_len]u8,
    implementation_dirty: bool,
};

pub const ResolveError = std.process.Child.RunError || error{
    GitCommandFailed,
    InvalidImplementationCommit,
    IncompleteImplementationIdentityOverride,
};

const commit_hex_len = 40;
const git_output_limit = 256;

/// Resolves an immutable identity during build configuration. Overrides are a
/// pair so source archives never publish a partly inferred identity.
pub fn resolve(
    allocator: std.mem.Allocator,
    repository_root: []const u8,
    explicit_commit: ?[]const u8,
    explicit_dirty: ?bool,
) ResolveError!Identity {
    if ((explicit_commit == null) != (explicit_dirty == null))
        return error.IncompleteImplementationIdentityOverride;

    if (explicit_commit) |commit| {
        return .{
            .implementation_commit = try parseCommit(commit),
            .implementation_dirty = explicit_dirty.?,
        };
    }

    return .{
        .implementation_commit = try readCommit(allocator, repository_root),
        .implementation_dirty = try readDirty(allocator, repository_root),
    };
}

fn readCommit(allocator: std.mem.Allocator, repository_root: []const u8) ResolveError![commit_hex_len]u8 {
    const result = try runGit(allocator, repository_root, &.{ "rev-parse", "--verify", "HEAD" }, git_output_limit);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(result.term);
    return parseCommit(std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn readDirty(allocator: std.mem.Allocator, repository_root: []const u8) ResolveError!bool {
    const tracked = try runGit(allocator, repository_root, &.{ "diff", "--quiet", "HEAD", "--" }, git_output_limit);
    defer allocator.free(tracked.stdout);
    defer allocator.free(tracked.stderr);
    switch (tracked.term) {
        .Exited => |status| switch (status) {
            0 => {},
            1 => return true,
            else => return error.GitCommandFailed,
        },
        else => return error.GitCommandFailed,
    }

    // One output byte is enough to distinguish an empty untracked set. A
    // longer listing is deliberately stopped and interpreted as dirty.
    const untracked = runGit(
        allocator,
        repository_root,
        &.{ "ls-files", "--others", "--exclude-standard" },
        1,
    ) catch |err| switch (err) {
        error.StdoutStreamTooLong => return true,
        else => return err,
    };
    defer allocator.free(untracked.stdout);
    defer allocator.free(untracked.stderr);
    try requireSuccess(untracked.term);
    return untracked.stdout.len != 0;
}

fn runGit(
    allocator: std.mem.Allocator,
    repository_root: []const u8,
    arguments: []const []const u8,
    max_output_bytes: usize,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, arguments);
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = repository_root,
        .max_output_bytes = max_output_bytes,
    });
}

fn requireSuccess(term: std.process.Child.Term) error{GitCommandFailed}!void {
    switch (term) {
        .Exited => |status| if (status == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn parseCommit(value: []const u8) error{InvalidImplementationCommit}![commit_hex_len]u8 {
    if (value.len != commit_hex_len) return error.InvalidImplementationCommit;
    var result: [commit_hex_len]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
            return error.InvalidImplementationCommit;
        result[index] = byte;
    }
    return result;
}

test "accepts a complete explicit identity without a repository" {
    const identity = try resolve(
        std.testing.allocator,
        "definitely-not-a-repository",
        "0123456789abcdef0123456789abcdef01234567",
        false,
    );
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        &identity.implementation_commit,
    );
    try std.testing.expect(!identity.implementation_dirty);
}

test "rejects partial explicit identity" {
    try std.testing.expectError(
        error.IncompleteImplementationIdentityOverride,
        resolve(
            std.testing.allocator,
            ".",
            "0123456789abcdef0123456789abcdef01234567",
            null,
        ),
    );
    try std.testing.expectError(
        error.IncompleteImplementationIdentityOverride,
        resolve(std.testing.allocator, ".", null, true),
    );
}

test "rejects malformed or uppercase explicit commit" {
    inline for (.{
        "0123456789abcdef",
        "0123456789abcdef0123456789abcdef0123456g",
        "0123456789abcdef0123456789abcdef0123456A",
    }) |commit| {
        try std.testing.expectError(
            error.InvalidImplementationCommit,
            resolve(std.testing.allocator, ".", commit, false),
        );
    }
}
