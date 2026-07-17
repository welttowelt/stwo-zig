//! Internal Merkle layer construction for lifted commitments.

const std = @import("std");
const builtin = @import("builtin");
const work_pool_mod = @import("../work_pool.zig");
const parameters = @import("parameters.zig");

pub fn Operations(comptime H: type) type {
    return struct {
        const Self = @This();
        const NodeSeed = if (@hasDecl(H, "nodeSeed")) @TypeOf(H.nodeSeed()) else H;
        const ThreadPool = std.Thread.Pool;
        const WaitGroup = std.Thread.WaitGroup;

        const SharedPoolState = struct {
            mutex: std.Thread.Mutex = .{},
            pool: ThreadPool = undefined,
            pool_initialized: bool = false,
            failed: bool = false,
        };
        var shared_pool_state: SharedPoolState = .{};

        pub const Executor = struct {
            enabled: bool = false,
            owns_pool: bool = false,
            owned_pool: ThreadPool = undefined,
            pool_ptr: ?*ThreadPool = null,

            pub fn init(
                self: *Executor,
                max_out_len: usize,
                worker_override: ?usize,
                reuse_pool: bool,
            ) void {
                const max_workers = parameters.parallelWorkersForLayer(max_out_len, worker_override);
                self.* = .{
                    .enabled = false,
                    .owns_pool = false,
                    .pool_ptr = null,
                };
                if (builtin.single_threaded or max_workers <= 1) return;

                if (reuse_pool) {
                    if (Self.sharedThreadPool()) |shared_pool| {
                        self.pool_ptr = shared_pool;
                        self.enabled = true;
                        return;
                    }
                }

                self.owned_pool.init(.{
                    // Keep task allocation independent from caller allocators,
                    // including test allocators shared with other threads.
                    .allocator = std.heap.page_allocator,
                    .n_jobs = max_workers - 1,
                    .stack_size = parameters.merkle_worker_stack_size,
                }) catch return;
                self.owns_pool = true;
                self.pool_ptr = &self.owned_pool;
                self.enabled = true;
            }

            pub fn deinit(self: *Executor) void {
                if (self.enabled and self.owns_pool) self.owned_pool.deinit();
                self.* = undefined;
            }

            fn pool(self: *Executor) *ThreadPool {
                return self.pool_ptr orelse unreachable;
            }
        };

        /// Returns the process-level Merkle pool used when no unified work pool
        /// is installed. Leaf finalization shares this fallback to avoid creating
        /// competing pools.
        pub fn sharedThreadPool() ?*ThreadPool {
            if (work_pool_mod.getGlobalPool()) |global_pool| {
                return &global_pool.pool;
            }

            shared_pool_state.mutex.lock();
            defer shared_pool_state.mutex.unlock();

            if (shared_pool_state.failed) return null;
            if (!shared_pool_state.pool_initialized) {
                shared_pool_state.pool.init(.{
                    .allocator = std.heap.page_allocator,
                    .n_jobs = parameters.max_parallel_workers - 1,
                    .stack_size = parameters.merkle_worker_stack_size,
                }) catch {
                    shared_pool_state.failed = true;
                    return null;
                };
                shared_pool_state.pool_initialized = true;
            }
            return &shared_pool_state.pool;
        }

        pub fn buildNextLayer(
            allocator: std.mem.Allocator,
            prev_layer: []const H.Hash,
            executor: *Executor,
            worker_override: ?usize,
        ) ![]H.Hash {
            std.debug.assert(prev_layer.len > 1 and std.math.isPowerOfTwo(prev_layer.len));
            const out = try allocator.alloc(H.Hash, prev_layer.len >> 1);
            const workers = parameters.parallelWorkersForLayer(out.len, worker_override);

            if (workers > 1 and executor.enabled) {
                if (comptime @hasDecl(H, "nodeSeed") and @hasDecl(H, "hashChildrenWithSeed")) {
                    const seed = H.nodeSeed();
                    if (buildNextLayerSeededParallel(out, prev_layer, seed, workers, executor)) |_| {
                        return out;
                    } else |_| {}
                } else {
                    if (buildNextLayerBasicParallel(out, prev_layer, workers, executor)) |_| {
                        return out;
                    } else |_| {}
                }
            }

            if (comptime @hasDecl(H, "nodeSeed") and @hasDecl(H, "hashChildrenWithSeed")) {
                const seed = H.nodeSeed();
                var i_seeded: usize = 0;
                if (comptime @hasDecl(H, "hashChildrenWithSeed4")) {
                    while (i_seeded + 4 <= out.len) : (i_seeded += 4) {
                        const children: *const [8]H.Hash = @ptrCast(&prev_layer[2 * i_seeded]);
                        const hashes = H.hashChildrenWithSeed4(seed, children);
                        inline for (0..4) |lane| out[i_seeded + lane] = hashes[lane];
                    }
                }
                while (i_seeded + 4 <= out.len) : (i_seeded += 4) {
                    out[i_seeded] = H.hashChildrenWithSeed(seed, .{
                        .left = prev_layer[2 * i_seeded],
                        .right = prev_layer[2 * i_seeded + 1],
                    });
                    out[i_seeded + 1] = H.hashChildrenWithSeed(seed, .{
                        .left = prev_layer[2 * (i_seeded + 1)],
                        .right = prev_layer[2 * (i_seeded + 1) + 1],
                    });
                    out[i_seeded + 2] = H.hashChildrenWithSeed(seed, .{
                        .left = prev_layer[2 * (i_seeded + 2)],
                        .right = prev_layer[2 * (i_seeded + 2) + 1],
                    });
                    out[i_seeded + 3] = H.hashChildrenWithSeed(seed, .{
                        .left = prev_layer[2 * (i_seeded + 3)],
                        .right = prev_layer[2 * (i_seeded + 3) + 1],
                    });
                }
                while (i_seeded < out.len) : (i_seeded += 1) {
                    out[i_seeded] = H.hashChildrenWithSeed(seed, .{
                        .left = prev_layer[2 * i_seeded],
                        .right = prev_layer[2 * i_seeded + 1],
                    });
                }
                return out;
            }

            var i: usize = 0;
            while (i + 4 <= out.len) : (i += 4) {
                out[i] = H.hashChildren(.{
                    .left = prev_layer[2 * i],
                    .right = prev_layer[2 * i + 1],
                });
                out[i + 1] = H.hashChildren(.{
                    .left = prev_layer[2 * (i + 1)],
                    .right = prev_layer[2 * (i + 1) + 1],
                });
                out[i + 2] = H.hashChildren(.{
                    .left = prev_layer[2 * (i + 2)],
                    .right = prev_layer[2 * (i + 2) + 1],
                });
                out[i + 3] = H.hashChildren(.{
                    .left = prev_layer[2 * (i + 3)],
                    .right = prev_layer[2 * (i + 3) + 1],
                });
            }
            while (i < out.len) : (i += 1) {
                out[i] = H.hashChildren(.{
                    .left = prev_layer[2 * i],
                    .right = prev_layer[2 * i + 1],
                });
            }
            return out;
        }

        const SeededRangeCtx = struct {
            out: []H.Hash,
            prev_layer: []const H.Hash,
            start: usize,
            end: usize,
            seed: NodeSeed,
        };

        fn hashSeededRange(ctx: *const SeededRangeCtx) void {
            var i = ctx.start;
            if (comptime @hasDecl(H, "hashChildrenWithSeed4")) {
                while (i + 4 <= ctx.end) : (i += 4) {
                    const children: *const [8]H.Hash = @ptrCast(&ctx.prev_layer[2 * i]);
                    const hashes = H.hashChildrenWithSeed4(ctx.seed, children);
                    inline for (0..4) |lane| ctx.out[i + lane] = hashes[lane];
                }
            }
            while (i < ctx.end) : (i += 1) {
                ctx.out[i] = H.hashChildrenWithSeed(ctx.seed, .{
                    .left = ctx.prev_layer[2 * i],
                    .right = ctx.prev_layer[2 * i + 1],
                });
            }
        }

        fn buildNextLayerSeededParallel(
            out: []H.Hash,
            prev_layer: []const H.Hash,
            seed: NodeSeed,
            worker_count: usize,
            executor: *Executor,
        ) !void {
            std.debug.assert(worker_count > 1);
            std.debug.assert(worker_count <= parameters.max_parallel_workers);
            std.debug.assert(executor.enabled);
            var contexts: [parameters.max_parallel_workers]SeededRangeCtx = undefined;

            const chunk_len = (out.len + worker_count - 1) / worker_count;
            var actual_workers: usize = 0;
            var start: usize = 0;
            while (start < out.len and actual_workers < worker_count) : (actual_workers += 1) {
                const end = @min(out.len, start + chunk_len);
                contexts[actual_workers] = .{
                    .out = out,
                    .prev_layer = prev_layer,
                    .start = start,
                    .end = end,
                    .seed = seed,
                };
                start = end;
            }
            if (actual_workers <= 1) {
                hashSeededRange(&contexts[0]);
                return;
            }

            var wait_group: WaitGroup = .{};
            for (1..actual_workers) |i| {
                executor.pool().spawnWg(&wait_group, hashSeededRange, .{&contexts[i]});
            }
            hashSeededRange(&contexts[0]);
            wait_group.wait();
        }

        const BasicRangeCtx = struct {
            out: []H.Hash,
            prev_layer: []const H.Hash,
            start: usize,
            end: usize,
        };

        fn hashBasicRange(ctx: *const BasicRangeCtx) void {
            var i = ctx.start;
            while (i < ctx.end) : (i += 1) {
                ctx.out[i] = H.hashChildren(.{
                    .left = ctx.prev_layer[2 * i],
                    .right = ctx.prev_layer[2 * i + 1],
                });
            }
        }

        fn buildNextLayerBasicParallel(
            out: []H.Hash,
            prev_layer: []const H.Hash,
            worker_count: usize,
            executor: *Executor,
        ) !void {
            std.debug.assert(worker_count > 1);
            std.debug.assert(worker_count <= parameters.max_parallel_workers);
            std.debug.assert(executor.enabled);
            var contexts: [parameters.max_parallel_workers]BasicRangeCtx = undefined;

            const chunk_len = (out.len + worker_count - 1) / worker_count;
            var actual_workers: usize = 0;
            var start: usize = 0;
            while (start < out.len and actual_workers < worker_count) : (actual_workers += 1) {
                const end = @min(out.len, start + chunk_len);
                contexts[actual_workers] = .{
                    .out = out,
                    .prev_layer = prev_layer,
                    .start = start,
                    .end = end,
                };
                start = end;
            }
            if (actual_workers <= 1) {
                hashBasicRange(&contexts[0]);
                return;
            }

            var wait_group: WaitGroup = .{};
            for (1..actual_workers) |i| {
                executor.pool().spawnWg(&wait_group, hashBasicRange, .{&contexts[i]});
            }
            hashBasicRange(&contexts[0]);
            wait_group.wait();
        }
    };
}
