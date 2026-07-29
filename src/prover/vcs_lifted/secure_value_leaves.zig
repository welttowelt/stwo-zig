//! Fused secure-row materialization and Merkle leaf hashing.

const std = @import("std");
const builtin = @import("builtin");
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const secure_column = @import("../secure_column.zig");
const work_pool = @import("../work_pool.zig");
const parameters = @import("parameters.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;

fn Work(comptime H: type) type {
    return struct {
        values: []const QM31,
        column: *SecureColumnByCoords,
        leaves: []H.Hash,
        start: usize,
        end: usize,
    };
}

fn runRange(comptime H: type, work: *const Work(H)) void {
    var position = work.start;
    if (comptime @hasDecl(H, "leafSeed") and @hasDecl(H, "hashPackedLeavesWithSeed4")) {
        const seed = H.leafSeed();
        while (position + 4 <= work.end) : (position += 4) {
            var coordinates: [4][qm31.SECURE_EXTENSION_DEGREE]M31 = undefined;
            var packed_bytes: [4][qm31.SECURE_EXTENSION_DEGREE * @sizeOf(M31)]u8 = undefined;
            var messages: [4][]const u8 = undefined;
            for (0..4) |lane| {
                coordinates[lane] = work.values[position + lane].toM31Array();
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                    work.column.columns[coordinate][position + lane] = coordinates[lane][coordinate];
                }
                if (builtin.cpu.arch.endian() == .little) {
                    messages[lane] = std.mem.sliceAsBytes(coordinates[lane][0..]);
                } else {
                    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                        const encoded = coordinates[lane][coordinate].toBytesLe();
                        const start = coordinate * @sizeOf(M31);
                        @memcpy(packed_bytes[lane][start .. start + @sizeOf(M31)], encoded[0..]);
                    }
                    messages[lane] = packed_bytes[lane][0..];
                }
            }
            const hashes = H.hashPackedLeavesWithSeed4(seed, &messages);
            inline for (0..4) |lane| work.leaves[position + lane] = hashes[lane];
        }
    }
    while (position < work.end) : (position += 1) {
        const coordinates = work.values[position].toM31Array();
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            work.column.columns[coordinate][position] = coordinates[coordinate];
        }
        var hasher = H.defaultWithInitialState();
        hasher.updateLeaf(coordinates[0..]);
        work.leaves[position] = hasher.finalize();
    }
}

pub fn build(
    comptime H: type,
    layer_allocator: std.mem.Allocator,
    values: []const QM31,
    column: *SecureColumnByCoords,
) ![]H.Hash {
    const Runner = struct {
        fn run(item: *const Work(H)) void {
            runRange(H, item);
        }
    };
    const leaves = try layer_allocator.alloc(H.Hash, values.len);
    const pool = work_pool.getGlobalPool() orelse {
        runRange(H, &.{
            .values = values,
            .column = column,
            .leaves = leaves,
            .start = 0,
            .end = values.len,
        });
        return leaves;
    };
    const worker_count = @min(
        pool.workerCount(),
        values.len / parameters.parallel_min_nodes_per_worker,
    );
    if (worker_count <= 1) {
        runRange(H, &.{
            .values = values,
            .column = column,
            .leaves = leaves,
            .start = 0,
            .end = values.len,
        });
        return leaves;
    }

    var work: [work_pool.MAX_WORKERS]Work(H) = undefined;
    const chunk_len = (values.len + worker_count - 1) / worker_count;
    for (0..worker_count) |worker| {
        const start = worker * chunk_len;
        work[worker] = .{
            .values = values,
            .column = column,
            .leaves = leaves,
            .start = start,
            .end = @min(values.len, start + chunk_len),
        };
    }

    var wait_group: std.Thread.WaitGroup = .{};
    for (work[1..worker_count]) |*item| {
        pool.spawnWg(&wait_group, Runner.run, .{@as(*const Work(H), item)});
    }
    runRange(H, &work[0]);
    wait_group.wait();
    return leaves;
}
