//! Content-addressed immutable artifact storage for the Metal proving service.

const std = @import("std");
const builtin = @import("builtin");
const artifact_manifest = @import("manifest.zig");

extern "c" fn fclonefileat(
    source_fd: std.posix.fd_t,
    destination_dir_fd: std.posix.fd_t,
    destination: [*:0]const u8,
    flags: u32,
) c_int;

const clone_no_owner_copy: u32 = 0x0002;

pub const CopyMethod = enum {
    cache,
    apfs_clone,
    byte_copy,
};

pub const IngestPolicy = enum {
    prefer_apfs_clone,
    byte_copy,
};

/// An authenticated reference to a service-owned immutable object. Callers
/// must bind both fields into the request or manifest that authorizes reuse.
pub const ObjectRef = struct {
    object_id: [32]u8,
    bytes: u64,
};

pub const Snapshot = struct {
    object_id: [32]u8,
    path: []u8,
    measurement: artifact_manifest.Measurement,
    source_identity: ?artifact_manifest.FileIdentity,
    method: CopyMethod,
    bytes_hashed: u64,

    pub fn ref(self: *const Snapshot) ObjectRef {
        return .{
            .object_id = self.object_id,
            .bytes = self.measurement.bytes,
        };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const CacheEntry = struct {
    object_path: []u8,
    measurement: artifact_manifest.Measurement,
};

/// A per-service immutable snapshot store. Every method, including `deinit`,
/// must run on the initializing thread; there is intentionally no map-level
/// synchronization. `deinit` invalidates every returned snapshot path. Source
/// metadata is diagnostic only, while manifest evidence describes the private
/// snapshot.
pub const Store = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    objects_path: []u8,
    cleanup_on_deinit: bool,
    objects: std.AutoHashMap([32]u8, CacheEntry),
    owner_thread_id: std.Thread.Id,
    temporary_counter: u64 = 0,

    pub fn initNew(
        allocator: std.mem.Allocator,
        root_path: []const u8,
        cleanup_on_deinit: bool,
    ) !Store {
        if (!std.fs.path.isAbsolute(root_path)) return error.InvalidArtifactStorePath;
        const owned_root = try allocator.dupe(u8, root_path);
        errdefer allocator.free(owned_root);
        try std.posix.mkdir(owned_root, 0o700);
        errdefer std.fs.deleteTreeAbsolute(owned_root) catch {};
        var root = try std.fs.openDirAbsolute(owned_root, .{ .no_follow = true });
        defer root.close();
        try root.chmod(0o700);

        const objects_path = try std.fs.path.join(allocator, &.{ owned_root, "objects" });
        errdefer allocator.free(objects_path);
        try std.posix.mkdir(objects_path, 0o700);
        var objects = try std.fs.openDirAbsolute(objects_path, .{ .no_follow = true });
        defer objects.close();
        try objects.chmod(0o700);
        try syncDirectory(objects);
        try syncDirectory(root);

        return .{
            .allocator = allocator,
            .root_path = owned_root,
            .objects_path = objects_path,
            .cleanup_on_deinit = cleanup_on_deinit,
            .objects = std.AutoHashMap([32]u8, CacheEntry).init(allocator),
            .owner_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn deinit(self: *Store) void {
        if (self.owner_thread_id != std.Thread.getCurrentId())
            @panic("artifact store deinitialized from non-owner thread");
        var iterator = self.objects.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.object_path);
        }
        self.objects.deinit();
        if (self.cleanup_on_deinit)
            std.fs.deleteTreeAbsolute(self.root_path) catch {};
        self.allocator.free(self.objects_path);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    /// Arbitrary paths always cross the trust boundary by snapshotting and
    /// hashing their current bytes. Path metadata never authorizes reuse.
    pub fn ingestPath(self: *Store, source_path: []const u8) !Snapshot {
        return self.ingestPathWithPolicy(source_path, .prefer_apfs_clone);
    }

    /// Byte-copy mode normalizes filesystem metadata for executable or shader
    /// artifacts whose extended attributes must not enter the trusted store.
    pub fn ingestPathWithPolicy(
        self: *Store,
        source_path: []const u8,
        policy: IngestPolicy,
    ) !Snapshot {
        try self.requireOwnerThread();
        const canonical = try std.fs.realpathAlloc(self.allocator, source_path);
        defer self.allocator.free(canonical);
        const source = try std.fs.openFileAbsolute(canonical, .{});
        defer source.close();
        const source_stat = try source.stat();
        if (source_stat.kind != .file or source_stat.size == 0)
            return error.InvalidArtifact;
        const source_identity = artifact_manifest.FileIdentity.fromStat(source_stat);

        var ingested = try self.ingest(source, source_identity, policy);
        errdefer ingested.deinit(self.allocator);
        return ingested;
    }

    /// Reuse performs no content read. It is valid only after the caller has
    /// authenticated both fields of `object_ref` and bound them to the
    /// intended artifact role.
    pub fn resolveRef(self: *Store, object_ref: ObjectRef) !Snapshot {
        try self.requireOwnerThread();
        const cached = self.objects.getPtr(object_ref.object_id) orelse
            return error.UnknownArtifactObject;
        if (!std.mem.eql(u8, &cached.measurement.sha256, &object_ref.object_id))
            return error.ArtifactStoreCorrupt;
        if (cached.measurement.bytes != object_ref.bytes)
            return error.ArtifactObjectLengthMismatch;
        try requireStoredIdentity(cached.object_path, cached.measurement.identity);
        return .{
            .object_id = object_ref.object_id,
            .path = try self.allocator.dupe(u8, cached.object_path),
            .measurement = cached.measurement,
            .source_identity = null,
            .method = .cache,
            .bytes_hashed = 0,
        };
    }

    /// Diagnostic compatibility path for callers that have not yet bound the
    /// object byte count into an authenticated request. Production request
    /// handling must use `resolveRef`.
    pub fn resolveObject(self: *Store, object_id: [32]u8) !Snapshot {
        try self.requireOwnerThread();
        const cached = self.objects.getPtr(object_id) orelse return error.UnknownArtifactObject;
        return self.resolveRef(.{
            .object_id = object_id,
            .bytes = cached.measurement.bytes,
        });
    }

    fn ingest(
        self: *Store,
        source: std.fs.File,
        source_identity: artifact_manifest.FileIdentity,
        policy: IngestPolicy,
    ) !Snapshot {
        const temporary_path = try self.temporaryPath();
        defer self.allocator.free(temporary_path);
        defer std.fs.deleteFileAbsolute(temporary_path) catch {};

        const clone_succeeded = policy == .prefer_apfs_clone and
            try cloneOpenFile(source, temporary_path);
        const method = if (clone_succeeded) CopyMethod.apfs_clone else CopyMethod.byte_copy;
        var measured = if (clone_succeeded)
            try artifact_manifest.measureFile(self.allocator, temporary_path)
        else
            try copyOpenFile(self.allocator, source, temporary_path);

        const source_after = artifact_manifest.FileIdentity.fromStat(try source.stat());
        if (!source_identity.eql(source_after)) return error.ArtifactChangedDuringSnapshot;

        if (measured.bytes != source_identity.size) return error.ArtifactChangedDuringSnapshot;
        const temporary = try std.fs.openFileAbsolute(temporary_path, .{ .mode = .read_write });
        defer temporary.close();
        try temporary.chmod(0o400);
        try temporary.sync();

        const digest_hex = std.fmt.bytesToHex(measured.sha256, .lower);
        if (self.objects.getPtr(measured.sha256)) |cached| {
            try requireStoredIdentity(cached.object_path, cached.measurement.identity);
            return .{
                .object_id = measured.sha256,
                .path = try self.allocator.dupe(u8, cached.object_path),
                .measurement = cached.measurement,
                .source_identity = source_identity,
                .method = method,
                .bytes_hashed = measured.bytes,
            };
        }
        const object_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.artifact",
            .{ self.objects_path, digest_hex },
        );
        errdefer self.allocator.free(object_path);

        std.posix.link(temporary_path, object_path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.ArtifactStoreCorrupt,
            else => return err,
        };
        var published = true;
        errdefer if (published) std.fs.deleteFileAbsolute(object_path) catch {};
        std.fs.deleteFileAbsolute(temporary_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var objects = try std.fs.openDirAbsolute(self.objects_path, .{});
        defer objects.close();
        try syncDirectory(objects);

        const object = try std.fs.openFileAbsolute(object_path, .{});
        defer object.close();
        const object_stat = try object.stat();
        if (object_stat.kind != .file or object_stat.size != measured.bytes)
            return error.ArtifactStoreCorrupt;
        measured.identity = artifact_manifest.FileIdentity.fromStat(object_stat);
        const retained_path = try self.allocator.dupe(u8, object_path);
        errdefer self.allocator.free(retained_path);
        try self.objects.put(measured.sha256, .{
            .object_path = retained_path,
            .measurement = measured,
        });
        published = false;
        return .{
            .object_id = measured.sha256,
            .path = object_path,
            .measurement = measured,
            .source_identity = source_identity,
            .method = method,
            .bytes_hashed = measured.bytes,
        };
    }

    fn temporaryPath(self: *Store) ![]u8 {
        self.temporary_counter +%= 1;
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/.ingest-{}-{}-{x}.tmp",
            .{
                self.objects_path,
                self.owner_thread_id,
                self.temporary_counter,
                std.crypto.random.int(u64),
            },
        );
    }

    fn requireOwnerThread(self: *const Store) !void {
        if (self.owner_thread_id != std.Thread.getCurrentId())
            return error.ArtifactStoreWrongThread;
    }
};

fn cloneOpenFile(source: std.fs.File, destination: []const u8) !bool {
    if (comptime builtin.os.tag != .macos) return false;
    const destination_z = try std.posix.toPosixPath(destination);
    const result = fclonefileat(
        source.handle,
        std.posix.AT.FDCWD,
        &destination_z,
        clone_no_owner_copy,
    );
    return switch (std.posix.errno(result)) {
        .SUCCESS => true,
        .XDEV, .OPNOTSUPP => false,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .IO => error.InputOutput,
        .ROFS => error.ReadOnlyFileSystem,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn copyOpenFile(
    allocator: std.mem.Allocator,
    source: std.fs.File,
    destination: []const u8,
) !artifact_manifest.Measurement {
    try source.seekTo(0);
    const output = try std.fs.createFileAbsolute(destination, .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    errdefer output.close();
    errdefer std.fs.deleteFileAbsolute(destination) catch {};
    const buffer = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: u64 = 0;
    while (true) {
        const count = try source.read(buffer);
        if (count == 0) break;
        try output.writeAll(buffer[0..count]);
        hasher.update(buffer[0..count]);
        bytes = std.math.add(u64, bytes, count) catch return error.InvalidArtifact;
    }
    try output.sync();
    const stat = try output.stat();
    if (stat.kind != .file or stat.size != bytes) return error.ArtifactChangedDuringSnapshot;
    output.close();
    return .{
        .bytes = bytes,
        .sha256 = hasher.finalResult(),
        .identity = artifact_manifest.FileIdentity.fromStat(stat),
    };
}

fn requireStoredIdentity(path: []const u8, expected: artifact_manifest.FileIdentity) !void {
    const object = try std.fs.openFileAbsolute(path, .{});
    defer object.close();
    const stat = try object.stat();
    if (stat.kind != .file or !artifact_manifest.FileIdentity.fromStat(stat).eql(expected))
        return error.ArtifactStoreCorrupt;
}

fn syncDirectory(directory: std.fs.Dir) !void {
    try std.posix.fsync(directory.fd);
}

fn testStore(allocator: std.mem.Allocator, temporary: *std.testing.TmpDir) !Store {
    const parent = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(parent);
    const root = try std.fs.path.join(allocator, &.{ parent, "artifact-store" });
    defer allocator.free(root);
    return Store.initNew(allocator, root, true);
}

const ResolveThreadContext = struct {
    store: *Store,
    object_ref: ObjectRef,
    observed_error: ?anyerror = null,
};

fn resolveFromNonOwnerThread(context: *ResolveThreadContext) void {
    var snapshot = context.store.resolveRef(context.object_ref) catch |err| {
        context.observed_error = err;
        return;
    };
    snapshot.deinit(std.testing.allocator);
}

test "snapshot is immutable after the source changes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "first-version" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var snapshot = try store.ingestPath(source_path);
    defer snapshot.deinit(std.testing.allocator);
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "later-version" });
    const stored = try std.fs.openFileAbsolute(snapshot.path, .{});
    defer stored.close();
    var bytes: [13]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try stored.readAll(&bytes));
    try std.testing.expectEqualStrings("first-version", &bytes);
    try std.testing.expect(snapshot.method == .apfs_clone or snapshot.method == .byte_copy);
    try std.testing.expectEqual(@as(u64, bytes.len), snapshot.bytes_hashed);
}

test "authenticated object reference receives a zero-read reuse hit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "cache-me" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var first = try store.ingestPath(source_path);
    defer first.deinit(std.testing.allocator);
    const object_ref = first.ref();
    try std.testing.expectEqual(first.object_id, object_ref.object_id);
    try std.testing.expectEqual(first.measurement.bytes, object_ref.bytes);
    var second = try store.resolveRef(object_ref);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(CopyMethod.cache, second.method);
    try std.testing.expectEqual(@as(u64, 0), second.bytes_hashed);
    try std.testing.expectEqualStrings(first.path, second.path);
    try std.testing.expectEqual(first.measurement.sha256, second.measurement.sha256);

    var path_again = try store.ingestPath(source_path);
    defer path_again.deinit(std.testing.allocator);
    try std.testing.expect(path_again.method != .cache);
    try std.testing.expectEqual(@as(u64, 8), path_again.bytes_hashed);
    try std.testing.expectEqualStrings(first.path, path_again.path);
}

test "unknown object reference fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    try std.testing.expectError(
        error.UnknownArtifactObject,
        store.resolveRef(.{
            .object_id = [_]u8{0xa5} ** 32,
            .bytes = 1,
        }),
    );
}

test "object reference with wrong byte count fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "sized-object" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var snapshot = try store.ingestPath(source_path);
    defer snapshot.deinit(std.testing.allocator);
    var wrong_ref = snapshot.ref();
    wrong_ref.bytes += 1;
    try std.testing.expectError(
        error.ArtifactObjectLengthMismatch,
        store.resolveRef(wrong_ref),
    );
}

test "store rejects access from a non-owner thread" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "thread-owned" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var snapshot = try store.ingestPath(source_path);
    defer snapshot.deinit(std.testing.allocator);
    var context = ResolveThreadContext{
        .store = &store,
        .object_ref = snapshot.ref(),
    };
    const thread = try std.Thread.spawn(.{}, resolveFromNonOwnerThread, .{&context});
    thread.join();
    try std.testing.expectEqual(error.ArtifactStoreWrongThread, context.observed_error.?);
}

test "cleanup policy removes the exclusive store root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const parent = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(parent);
    const root = try std.fs.path.join(std.testing.allocator, &.{ parent, "cleanup-store" });
    defer std.testing.allocator.free(root);

    var store = try Store.initNew(std.testing.allocator, root, true);
    store.deinit();
    try std.testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(root, .{}));
}

test "same-size mutation with restored mtime invalidates the cache" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "abcdefgh" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var first = try store.ingestPath(source_path);
    defer first.deinit(std.testing.allocator);
    const source = try std.fs.openFileAbsolute(source_path, .{ .mode = .read_write });
    const before = try source.stat();
    try source.pwriteAll("abcdWXYZ", 0);
    try source.updateTimes(before.atime, before.mtime);
    try source.sync();
    source.close();
    var second = try store.ingestPath(source_path);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &first.measurement.sha256, &second.measurement.sha256));
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
}

test "content objects are read only and addressed by digest" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "content-address" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var snapshot = try store.ingestPath(source_path);
    defer snapshot.deinit(std.testing.allocator);
    const object = try std.fs.openFileAbsolute(snapshot.path, .{});
    defer object.close();
    const stat = try object.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0), stat.mode & 0o222);
    const digest_hex = std.fmt.bytesToHex(snapshot.measurement.sha256, .lower);
    try std.testing.expect(std.mem.endsWith(u8, snapshot.path, &digest_hex ++ ".artifact"));
}

test "forced byte-copy admission hashes once and stores normalized bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "copy-fallback" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var snapshot = try store.ingestPathWithPolicy(source_path, .byte_copy);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(CopyMethod.byte_copy, snapshot.method);
    try std.testing.expectEqual(@as(u64, "copy-fallback".len), snapshot.bytes_hashed);
    try std.testing.expectEqual(
        artifact_manifest.digestBytes("copy-fallback"),
        snapshot.measurement.sha256,
    );
}

test "stored object tampering fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "source.bin", .data = "protected" });
    const source_path = try temporary.dir.realpathAlloc(std.testing.allocator, "source.bin");
    defer std.testing.allocator.free(source_path);
    var store = try testStore(std.testing.allocator, &temporary);
    defer store.deinit();

    var snapshot = try store.ingestPath(source_path);
    defer snapshot.deinit(std.testing.allocator);
    const read_only_object = try std.fs.openFileAbsolute(snapshot.path, .{});
    const before = try read_only_object.stat();
    try read_only_object.chmod(0o600);
    read_only_object.close();
    const object = try std.fs.openFileAbsolute(snapshot.path, .{ .mode = .read_write });
    try object.pwriteAll("tampered!", 0);
    try object.updateTimes(before.atime, before.mtime);
    try object.chmod(0o400);
    try object.sync();
    object.close();
    try std.testing.expectError(
        error.ArtifactStoreCorrupt,
        store.resolveRef(snapshot.ref()),
    );
}
