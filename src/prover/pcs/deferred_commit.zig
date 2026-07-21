//! Deferred first-tree commitment.
//!
//! The first committed tree's contents are channel-independent — only the
//! ORDER of Merkle-root mixes into the channel is protocol-bound. This
//! module runs that tree's full build on a dedicated worker thread so it
//! overlaps the next commit's build; the pending root is joined and mixed
//! in original order at the `tree_builders.appendCommittedTree` choke point
//! before any later tree is appended. Proof bytes are identical to the
//! sequential path by construction.
//!
//! Deferral gates (see `canDeferFirstTree`): multi-threaded build, first
//! tree only, non-empty non-constant columns, and a borrowed (pre-built,
//! read-only) twiddle tower so the worker never mutates shared cache state.
//! Spawn failure falls back to the sequential path; `discard` drains an
//! unresolved build on abort.

const std = @import("std");
const builtin = @import("builtin");
const column_preparation = @import("columns/preparation.zig");
const column_storage = @import("columns/storage.zig");
const commitment_tree = @import("commitment_tree.zig");
const tree_builders = @import("tree_builders.zig");

const ColumnEvaluation = commitment_tree.ColumnEvaluation;

pub fn Pending(comptime Tree: type) type {
    return struct {
        thread: std.Thread,
        slot: *Slot,

        pub const Slot = struct {
            tree: ?Tree = null,
            err: ?anyerror = null,
        };
    };
}

pub fn canDeferFirstTree(scheme: anytype, owned_columns: []const ColumnEvaluation) bool {
    if (comptime builtin.single_threaded) return false;
    if (scheme.pending_commit != null) return false;
    if (scheme.trees.items.len != 0) return false;
    if (owned_columns.len == 0) return false;
    if (!scheme.twiddle_source.isBorrowed()) return false;
    return true;
}

/// Spawns the deferred build; returns false (caller runs the sequential
/// path) if the slot allocation or thread spawn fails.
pub fn trySpawn(
    comptime B: type,
    comptime Tree: type,
    scheme: anytype,
    allocator: std.mem.Allocator,
    owned_columns: []ColumnEvaluation,
) bool {
    const P = Pending(Tree);
    const slot = allocator.create(P.Slot) catch return false;
    slot.* = .{};
    const Worker = struct {
        fn run(
            scheme_ptr: @TypeOf(scheme),
            worker_allocator: std.mem.Allocator,
            columns: []ColumnEvaluation,
            out: *P.Slot,
        ) void {
            var prepared = column_preparation.prepareColumnsForCommitOwnedForBackend(
                B,
                worker_allocator,
                columns,
                scheme_ptr.config.fri_config.log_blowup_factor,
                scheme_ptr.coefficient_retention_policy,
                &scheme_ptr.twiddle_source,
                null,
            ) catch |err| {
                column_storage.freeOwnedColumnEvaluations(worker_allocator, columns);
                out.err = err;
                return;
            };
            const tree = Tree.initOwnedWithBacking(
                worker_allocator,
                prepared.columns,
                prepared.coefficients,
                prepared.column_backing_buffers,
                prepared.coefficient_backing_buffers,
            ) catch |err| {
                prepared.deinit(worker_allocator);
                out.err = err;
                return;
            };
            out.tree = tree;
        }
    };
    const thread = std.Thread.spawn(
        .{},
        Worker.run,
        .{ scheme, allocator, owned_columns, slot },
    ) catch {
        allocator.destroy(slot);
        return false;
    };
    scheme.pending_commit = .{ .thread = thread, .slot = slot };
    return true;
}

/// Joins a deferred first-tree build (if any) and replays its root mix by
/// re-entering the append choke point. Clears the pending slot first, so
/// the recursion terminates and mix order matches the sequential path.
pub fn resolve(
    comptime MC: type,
    scheme: anytype,
    allocator: std.mem.Allocator,
    channel: anytype,
) anyerror!void {
    const pending = scheme.pending_commit orelse return;
    scheme.pending_commit = null;
    pending.thread.join();
    const slot = pending.slot;
    defer allocator.destroy(slot);
    if (slot.err) |err| return err;
    var tree = slot.tree.?;
    errdefer tree.deinit(allocator);
    try tree_builders.appendCommittedTree(MC, scheme, allocator, tree, channel);
}

/// Abort path: join and discard a deferred build without mixing.
pub fn discard(scheme: anytype, allocator: std.mem.Allocator) void {
    const pending = scheme.pending_commit orelse return;
    scheme.pending_commit = null;
    pending.thread.join();
    if (pending.slot.tree) |*tree| tree.deinit(allocator);
    allocator.destroy(pending.slot);
}
