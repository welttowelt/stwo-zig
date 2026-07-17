const std = @import("std");
const builtin = @import("builtin");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const lifted_merkle_hasher = @import("../../core/vcs_lifted/merkle_hasher.zig");
const work_pool_mod = @import("../work_pool.zig");
const quotient_ops = @import("../pcs/quotient_ops.zig");
const secure_column = @import("../secure_column.zig");
const decommit_mod = @import("decommit.zig");
const columns_mod = @import("columns.zig");
const parameters = @import("parameters.zig");

const M31 = m31.M31;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;

pub fn MerkleProverLifted(comptime H: type) type {
    comptime lifted_merkle_hasher.assertMerkleHasherLifted(H);
    return struct {
        /// Merkle layers from root to largest layer.
        layers: [][]H.Hash,
        /// Allocator used for individual layer data buffers. When mmap is
        /// available and layers are large enough, this is MmapAllocator
        /// (MADV_SEQUENTIAL hint for streaming hash reads). The outer
        /// `layers` array itself is always freed with the caller's allocator.
        layer_allocator: std.mem.Allocator,

        const Self = @This();
        const NodeSeed = if (@hasDecl(H, "nodeSeed")) @TypeOf(H.nodeSeed()) else H;
        const parallel_min_nodes = parameters.parallel_min_nodes;
        const parallel_min_nodes_per_worker = parameters.parallel_min_nodes_per_worker;
        const max_parallel_workers = parameters.max_parallel_workers;
        const merkle_worker_stack_size = parameters.merkle_worker_stack_size;
        const leaf_tile_len = parameters.leaf_tile_len;
        const max_leaf_scratch_bytes = parameters.max_leaf_scratch_bytes;
        const default_leaf_batch_size = parameters.default_leaf_batch_size;
        const batched_leaf_threshold = parameters.batched_leaf_threshold;
        const layerAllocator = parameters.layerAllocator;
        const merkleWorkerOverride = parameters.merkleWorkerOverride;
        const leafBatchSizeOverride = parameters.leafBatchSizeOverride;
        const merklePoolReuseEnabled = parameters.merklePoolReuseEnabled;
        const parallelWorkersForLayer = parameters.parallelWorkersForLayer;
        const ThreadPool = std.Thread.Pool;
        const WaitGroup = std.Thread.WaitGroup;
        const SharedPoolState = struct {
            mutex: std.Thread.Mutex = .{},
            pool: ThreadPool = undefined,
            pool_initialized: bool = false,
            failed: bool = false,
        };
        var shared_pool_state: SharedPoolState = .{};

        pub const DecommitmentResult = decommit_mod.DecommitmentResult(H);

        const LayerExecutor = struct {
            enabled: bool = false,
            max_workers: usize = 1,
            owns_pool: bool = false,
            owned_pool: ThreadPool = undefined,
            pool_ptr: ?*ThreadPool = null,

            fn init(self: *LayerExecutor, max_workers: usize, reuse_pool: bool) void {
                self.* = .{
                    .enabled = false,
                    .max_workers = max_workers,
                    .owns_pool = false,
                    .pool_ptr = null,
                };
                if (builtin.single_threaded or max_workers <= 1) return;

                if (reuse_pool) {
                    if (sharedThreadPool()) |shared_pool| {
                        self.pool_ptr = shared_pool;
                        self.enabled = true;
                        return;
                    }
                }

                self.owned_pool.init(.{
                    // Keep pool task allocation decoupled from caller allocators
                    // (including test allocators) to avoid cross-thread contention.
                    .allocator = std.heap.page_allocator,
                    // Previous implementation used one caller worker + N-1 spawned workers.
                    .n_jobs = max_workers - 1,
                    .stack_size = merkle_worker_stack_size,
                }) catch return;
                self.owns_pool = true;
                self.pool_ptr = &self.owned_pool;
                self.enabled = true;
            }

            fn deinit(self: *LayerExecutor) void {
                if (self.enabled and self.owns_pool) {
                    self.owned_pool.deinit();
                }
                self.* = undefined;
            }

            fn pool(self: *LayerExecutor) *ThreadPool {
                return self.pool_ptr orelse unreachable;
            }

            fn sharedThreadPool() ?*ThreadPool {
                // Prefer the unified global work pool so Merkle hashing and
                // FFT don't create competing thread pools.
                if (work_pool_mod.getGlobalPool()) |global_pool| {
                    return &global_pool.pool;
                }

                // Fallback: create our own pool (test builds, single-threaded,
                // or if the global pool failed to initialise).
                shared_pool_state.mutex.lock();
                defer shared_pool_state.mutex.unlock();

                if (shared_pool_state.failed) return null;
                if (!shared_pool_state.pool_initialized) {
                    shared_pool_state.pool.init(.{
                        .allocator = std.heap.page_allocator,
                        .n_jobs = max_parallel_workers - 1,
                        .stack_size = merkle_worker_stack_size,
                    }) catch {
                        shared_pool_state.failed = true;
                        return null;
                    };
                    shared_pool_state.pool_initialized = true;
                }
                return &shared_pool_state.pool;
            }
        };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.layers) |layer| self.layer_allocator.free(layer);
            allocator.free(self.layers);
            self.* = undefined;
        }

        pub fn root(self: Self) H.Hash {
            return self.layers[0][0];
        }

        pub fn commit(
            allocator: std.mem.Allocator,
            columns: []const []const M31,
        ) !Self {
            return commitWithOptions(
                allocator,
                columns,
                merkleWorkerOverride(allocator),
                merklePoolReuseEnabled(allocator),
            );
        }

        /// Builds a Merkle tree by computing quotient values lazily from the
        /// provider, chunk by chunk.  Simultaneously writes the computed
        /// quotient coordinates into `out_column`, so the caller obtains both
        /// the Merkle commitment and the materialized column without ever
        /// needing a separate full-column allocation before hashing.
        pub fn commitWithLazyQuotients(
            allocator: std.mem.Allocator,
            provider: *quotient_ops.LazyQuotientProvider,
            out_column: *SecureColumnByCoords,
        ) !Self {
            const domain_size = provider.domain_size;
            if (domain_size < 2 or !std.math.isPowerOfTwo(domain_size)) return error.InvalidColumnSize;
            const log_size: u32 = @intCast(std.math.log2_int(usize, domain_size));

            try provider.computeAll(allocator, out_column);

            const layer_alloc = layerAllocator(allocator);
            const leaves = try layer_alloc.alloc(H.Hash, domain_size);
            errdefer layer_alloc.free(leaves);
            hashLazyQuotientLeaves(out_column, leaves);

            // Build internal Merkle layers from the leaves upward.
            var layers_bottom_up = std.ArrayList([]H.Hash).empty;
            defer layers_bottom_up.deinit(allocator);
            errdefer {
                for (layers_bottom_up.items) |layer| layer_alloc.free(layer);
            }

            try layers_bottom_up.append(allocator, leaves);

            if (domain_size > 1) {
                const max_out_len = domain_size >> 1;
                var executor: LayerExecutor = undefined;
                executor.init(
                    parallelWorkersForLayer(max_out_len, merkleWorkerOverride(allocator)),
                    merklePoolReuseEnabled(allocator),
                );
                defer executor.deinit();

                var i: usize = 0;
                while (i < log_size) : (i += 1) {
                    const next_layer = try buildNextLayer(
                        layer_alloc,
                        layers_bottom_up.items[layers_bottom_up.items.len - 1],
                        &executor,
                        merkleWorkerOverride(allocator),
                    );
                    try layers_bottom_up.append(allocator, next_layer);
                }
            }

            const out_layers = try allocator.alloc([]H.Hash, layers_bottom_up.items.len);
            var j: usize = 0;
            while (j < out_layers.len) : (j += 1) {
                out_layers[j] = layers_bottom_up.items[out_layers.len - 1 - j];
            }
            return .{ .layers = out_layers, .layer_allocator = layer_alloc };
        }

        const LazyLeafRange = struct {
            column: *const SecureColumnByCoords,
            leaves: []H.Hash,
            start: usize,
            end: usize,
        };

        fn hashLazyLeafRange(work: *const LazyLeafRange) void {
            for (work.start..work.end) |position| {
                var values: [qm31.SECURE_EXTENSION_DEGREE]M31 = undefined;
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                    values[coord] = work.column.columns[coord][position];
                }
                var hasher = H.defaultWithInitialState();
                hasher.updateLeaf(values[0..]);
                work.leaves[position] = hasher.finalize();
            }
        }

        fn hashLazyQuotientLeaves(column: *const SecureColumnByCoords, leaves: []H.Hash) void {
            const pool = work_pool_mod.getGlobalPool() orelse {
                hashLazyLeafRange(&.{ .column = column, .leaves = leaves, .start = 0, .end = leaves.len });
                return;
            };
            const worker_count = @min(pool.workerCount(), leaves.len / parallel_min_nodes_per_worker);
            if (worker_count <= 1) {
                hashLazyLeafRange(&.{ .column = column, .leaves = leaves, .start = 0, .end = leaves.len });
                return;
            }

            var work: [work_pool_mod.MAX_WORKERS]LazyLeafRange = undefined;
            const chunk_len = (leaves.len + worker_count - 1) / worker_count;
            for (0..worker_count) |worker| {
                const start = worker * chunk_len;
                work[worker] = .{
                    .column = column,
                    .leaves = leaves,
                    .start = start,
                    .end = @min(leaves.len, start + chunk_len),
                };
            }

            var wait_group: WaitGroup = .{};
            for (work[1..worker_count]) |*item| {
                pool.spawnWg(&wait_group, hashLazyLeafRange, .{@as(*const LazyLeafRange, item)});
            }
            hashLazyLeafRange(&work[0]);
            wait_group.wait();
        }

        fn commitWithWorkerOverride(
            allocator: std.mem.Allocator,
            columns: []const []const M31,
            worker_override: ?usize,
        ) !Self {
            return commitWithOptions(allocator, columns, worker_override, false);
        }

        fn commitWithOptions(
            allocator: std.mem.Allocator,
            columns: []const []const M31,
            worker_override: ?usize,
            reuse_pool: bool,
        ) !Self {
            const sorted = try sortColumnsByLogSizeAsc(allocator, columns);
            defer allocator.free(sorted);

            // Use MmapAllocator for individual layer buffers (sequential-read
            // hint helps the OS prefetcher during Merkle hashing).
            const layer_alloc = layerAllocator(allocator);

            if (allColumnsConstant(sorted)) {
                return commitConstantColumns(allocator, layer_alloc, sorted);
            }

            var layers_bottom_up = std.ArrayList([]H.Hash).empty;
            defer layers_bottom_up.deinit(allocator);
            errdefer {
                for (layers_bottom_up.items) |layer| layer_alloc.free(layer);
            }

            // Choose leaf-building strategy based on domain size.  For large
            // domains, use the row-batch path to keep the transient hasher
            // array bounded (saves ~(N - batch_size) * sizeof(H) peak RAM,
            // e.g. >100 MiB for 2^20 leaves with Blake2s).
            const leaves = blk: {
                if (sorted.len > 0) {
                    const max_col_log_size = sorted[sorted.len - 1].log_size;
                    const total_leaves = @as(usize, 1) << @intCast(max_col_log_size);
                    if (total_leaves >= batched_leaf_threshold) {
                        const batch_size = leafBatchSizeOverride(allocator) orelse default_leaf_batch_size;
                        break :blk try buildLeavesBatched(allocator, layer_alloc, sorted, batch_size);
                    }
                }
                break :blk try buildLeaves(allocator, layer_alloc, sorted);
            };
            try layers_bottom_up.append(allocator, leaves);

            if (leaves.len > 1) {
                std.debug.assert(std.math.isPowerOfTwo(leaves.len));
                const max_log_size = std.math.log2_int(usize, leaves.len);
                const max_out_len = leaves.len >> 1;
                var executor: LayerExecutor = undefined;
                executor.init(parallelWorkersForLayer(max_out_len, worker_override), reuse_pool);
                defer executor.deinit();

                var i: usize = 0;
                while (i < max_log_size) : (i += 1) {
                    const prev_idx = layers_bottom_up.items.len - 1;
                    const next_layer = try buildNextLayer(
                        layer_alloc,
                        layers_bottom_up.items[prev_idx],
                        &executor,
                        worker_override,
                    );
                    try layers_bottom_up.append(allocator, next_layer);
                }
            }

            const out_layers = try allocator.alloc([]H.Hash, layers_bottom_up.items.len);
            var i: usize = 0;
            while (i < out_layers.len) : (i += 1) {
                out_layers[i] = layers_bottom_up.items[out_layers.len - 1 - i];
            }
            return .{ .layers = out_layers, .layer_allocator = layer_alloc };
        }

        const allColumnsConstant = columns_mod.allConstant;

        fn commitConstantColumns(
            allocator: std.mem.Allocator,
            layer_alloc: std.mem.Allocator,
            columns: []const ColumnRef,
        ) !Self {
            const leaf_count = if (columns.len == 0)
                @as(usize, 1)
            else
                @as(usize, 1) << @intCast(columns[columns.len - 1].log_size);

            var leaf_hasher = H.defaultWithInitialState();
            for (columns) |column| leaf_hasher.updateLeaf(column.values[0..1]);
            const leaf_hash = leaf_hasher.finalize();

            var layers_bottom_up = std.ArrayList([]H.Hash).empty;
            defer layers_bottom_up.deinit(allocator);
            errdefer for (layers_bottom_up.items) |layer| layer_alloc.free(layer);

            const leaves = try layer_alloc.alloc(H.Hash, leaf_count);
            @memset(leaves, leaf_hash);
            try layers_bottom_up.append(allocator, leaves);

            var layer_len = leaf_count;
            var child_hash = leaf_hash;
            while (layer_len > 1) {
                layer_len >>= 1;
                child_hash = H.hashChildren(.{ .left = child_hash, .right = child_hash });
                const layer = try layer_alloc.alloc(H.Hash, layer_len);
                @memset(layer, child_hash);
                try layers_bottom_up.append(allocator, layer);
            }

            const out_layers = try allocator.alloc([]H.Hash, layers_bottom_up.items.len);
            for (out_layers, 0..) |*layer, i| {
                layer.* = layers_bottom_up.items[out_layers.len - 1 - i];
            }
            return .{ .layers = out_layers, .layer_allocator = layer_alloc };
        }

        pub fn decommit(
            self: Self,
            allocator: std.mem.Allocator,
            query_positions: []const usize,
            columns: []const []const M31,
        ) !DecommitmentResult {
            return decommit_mod.decommit(H, self, allocator, query_positions, columns);
        }

        pub fn maxLogSize(self: Self) u32 {
            return @intCast(self.layers.len - 1);
        }

        pub fn readHashes(
            self: Self,
            allocator: std.mem.Allocator,
            layer_log_size: u32,
            indices: []const u32,
        ) ![]H.Hash {
            const layer = self.layers[layer_log_size];
            const out = try allocator.alloc(H.Hash, indices.len);
            for (indices, out) |index, *destination| destination.* = layer[index];
            return out;
        }

        pub const ColumnRef = columns_mod.ColumnRef;
        pub const sortColumnsByLogSizeAsc = columns_mod.sortByLogSizeAsc;

        fn buildLeaves(
            allocator: std.mem.Allocator,
            layer_alloc: std.mem.Allocator,
            sorted_columns: []const ColumnRef,
        ) ![]H.Hash {
            var seed_hasher = H.defaultWithInitialState();
            if (sorted_columns.len == 0) {
                const layer = try layer_alloc.alloc(H.Hash, 1);
                layer[0] = seed_hasher.finalize();
                return layer;
            }

            if (sorted_columns[0].values.len == 1) return error.InvalidColumnSize;

            var prev_layer = try allocator.alloc(H, 2);
            prev_layer[0] = seed_hasher;
            prev_layer[1] = seed_hasher;

            var prev_layer_log_size: u32 = 1;
            var group_start: usize = 0;
            while (group_start < sorted_columns.len) {
                const log_size = sorted_columns[group_start].log_size;
                var group_end = group_start + 1;
                while (group_end < sorted_columns.len and
                    sorted_columns[group_end].log_size == log_size)
                {
                    group_end += 1;
                }

                const log_ratio = log_size - prev_layer_log_size;
                const layer_size = @as(usize, 1) << @intCast(log_size);
                const shift_amt: std.math.Log2Int(usize) = @intCast(log_ratio + 1);
                const expanded = try allocator.alloc(H, layer_size);
                for (0..layer_size) |idx| {
                    const src_idx = ((idx >> shift_amt) << 1) + (idx & 1);
                    expanded[idx] = prev_layer[src_idx];
                }
                allocator.free(prev_layer);
                prev_layer = expanded;

                const group_columns = sorted_columns[group_start..group_end];
                if (comptime @hasDecl(H, "updateLeafPackedBytes")) {
                    try updateLeafHashersPacked(
                        allocator,
                        prev_layer,
                        group_columns,
                        layer_size,
                    );
                } else {
                    var idx: usize = 0;
                    while (idx < layer_size) : (idx += 1) {
                        for (group_columns) |column| {
                            prev_layer[idx].updateLeaf(column.values[idx .. idx + 1]);
                        }
                    }
                }

                prev_layer_log_size = log_size;
                group_start = group_end;
            }

            // Output layer uses mmap-backed allocator for sequential-read
            // hinting; temporary hasher arrays above use the regular allocator.
            const out = try layer_alloc.alloc(H.Hash, prev_layer.len);
            if (prev_layer.len >= parallel_min_nodes and !builtin.single_threaded) {
                finalizeLeafHashersParallel(prev_layer, out);
            } else {
                for (prev_layer, 0..) |*hasher, i| out[i] = hasher.finalize();
            }
            allocator.free(prev_layer);
            return out;
        }

        /// Builds leaf hashes in row batches to bound peak memory.
        ///
        /// Instead of allocating one hasher per leaf for the entire column
        /// set (which can be hundreds of MiB for large domains), this
        /// function processes `batch_size` leaves at a time:
        ///
        /// 1. Allocate a small hasher array of length `batch_size`.
        /// 2. For each column, compute the correct value mapping for the
        ///    current row range and feed it into the batch hashers.
        /// 3. Finalize the batch and write leaf hashes to the output.
        /// 4. Reuse the hasher array for the next batch.
        ///
        /// The mapping from leaf position `pos` (in the max-log-size
        /// domain) to a column at `col_log_size` is:
        ///
        ///   column_index = ((pos >> (max_log_size - col_log_size + 1)) << 1) + (pos & 1)
        ///
        /// This matches the lifting index used by the decommit path and
        /// produces bit-identical leaf hashes.
        const BatchedLeafRangeCtx = struct {
            seed_hasher: H,
            sorted_columns: []const ColumnRef,
            max_log_size: u32,
            out: []H.Hash,
            batch_hashers: []H,
            scratch: ?[]align(@alignOf(M31)) u8,
            start: usize,
            end: usize,
        };

        fn buildLeavesBatchedRange(ctx: *const BatchedLeafRangeCtx) void {
            if (comptime @hasDecl(H, "leafSeed") and @hasDecl(H, "hashPackedLeavesWithSeed4")) {
                buildLeavesBatchedRange4(ctx);
                return;
            }
            var batch_start = ctx.start;
            while (batch_start < ctx.end) : (batch_start += ctx.batch_hashers.len) {
                const batch_end = @min(ctx.end, batch_start + ctx.batch_hashers.len);
                const batch_len = batch_end - batch_start;
                for (ctx.batch_hashers[0..batch_len]) |*hasher| hasher.* = ctx.seed_hasher;

                for (ctx.sorted_columns) |column| {
                    const shift_amt: std.math.Log2Int(usize) = @intCast(ctx.max_log_size - column.log_size + 1);
                    if (comptime @hasDecl(H, "updateLeafPackedBytes")) {
                        const scratch = ctx.scratch orelse {
                            for (0..batch_len) |local| {
                                const position = batch_start + local;
                                const column_index = ((position >> shift_amt) << 1) + (position & 1);
                                ctx.batch_hashers[local].updateLeaf(column.values[column_index .. column_index + 1]);
                            }
                            continue;
                        };
                        const max_tile = max_leaf_scratch_bytes / @sizeOf(M31);
                        var tile_offset: usize = 0;
                        while (tile_offset < batch_len) : (tile_offset += max_tile) {
                            const tile_len = @min(max_tile, batch_len - tile_offset);
                            const buffer = scratch[0 .. tile_len * @sizeOf(M31)];
                            if (builtin.cpu.arch.endian() == .little) {
                                const words = std.mem.bytesAsSlice(M31, buffer);
                                for (0..tile_len) |local| {
                                    const position = batch_start + tile_offset + local;
                                    const column_index = ((position >> shift_amt) << 1) + (position & 1);
                                    words[local] = column.values[column_index];
                                }
                            } else {
                                for (0..tile_len) |local| {
                                    const position = batch_start + tile_offset + local;
                                    const column_index = ((position >> shift_amt) << 1) + (position & 1);
                                    const encoded = column.values[column_index].toBytesLe();
                                    const byte_start = local * @sizeOf(M31);
                                    @memcpy(buffer[byte_start .. byte_start + @sizeOf(M31)], encoded[0..]);
                                }
                            }
                            for (0..tile_len) |local| {
                                const byte_start = local * @sizeOf(M31);
                                ctx.batch_hashers[tile_offset + local].updateLeafPackedBytes(
                                    buffer[byte_start .. byte_start + @sizeOf(M31)],
                                );
                            }
                        }
                    } else {
                        for (0..batch_len) |local| {
                            const position = batch_start + local;
                            const column_index = ((position >> shift_amt) << 1) + (position & 1);
                            ctx.batch_hashers[local].updateLeaf(column.values[column_index .. column_index + 1]);
                        }
                    }
                }

                for (ctx.batch_hashers[0..batch_len], 0..) |*hasher, local| {
                    ctx.out[batch_start + local] = hasher.finalize();
                }
            }
        }

        fn buildLeavesBatchedRange4(ctx: *const BatchedLeafRangeCtx) void {
            const scratch = ctx.scratch orelse {
                buildLeavesBatchedRangeScalar(ctx);
                return;
            };
            const bytes_per_leaf = ctx.sorted_columns.len * @sizeOf(M31);
            if (bytes_per_leaf == 0 or 4 * bytes_per_leaf > scratch.len) {
                buildLeavesBatchedRangeScalar(ctx);
                return;
            }

            const seed = H.leafSeed();
            var position = ctx.start;
            while (position + 4 <= ctx.end) : (position += 4) {
                const buffer = scratch[0 .. 4 * bytes_per_leaf];
                packBatchedLeafMessages(ctx, buffer, position, 4, bytes_per_leaf);
                var messages: [4][]const u8 = undefined;
                for (0..4) |lane| {
                    messages[lane] = buffer[lane * bytes_per_leaf ..][0..bytes_per_leaf];
                }
                const hashes = H.hashPackedLeavesWithSeed4(seed, &messages);
                inline for (0..4) |lane| ctx.out[position + lane] = hashes[lane];
            }

            while (position < ctx.end) : (position += 1) {
                var hasher = ctx.seed_hasher;
                for (ctx.sorted_columns) |column| {
                    const shift_amt: std.math.Log2Int(usize) = @intCast(ctx.max_log_size - column.log_size + 1);
                    const source_index = ((position >> shift_amt) << 1) + (position & 1);
                    hasher.updateLeaf(column.values[source_index .. source_index + 1]);
                }
                ctx.out[position] = hasher.finalize();
            }
        }

        fn packBatchedLeafMessages(
            ctx: *const BatchedLeafRangeCtx,
            buffer: []align(@alignOf(M31)) u8,
            position: usize,
            lane_count: usize,
            bytes_per_leaf: usize,
        ) void {
            if (builtin.cpu.arch.endian() == .little) {
                const words = std.mem.bytesAsSlice(M31, buffer);
                for (0..lane_count) |lane| {
                    for (ctx.sorted_columns, 0..) |column, column_index| {
                        const shift_amt: std.math.Log2Int(usize) = @intCast(ctx.max_log_size - column.log_size + 1);
                        const leaf_position = position + lane;
                        const source_index = ((leaf_position >> shift_amt) << 1) + (leaf_position & 1);
                        words[lane * ctx.sorted_columns.len + column_index] = column.values[source_index];
                    }
                }
                return;
            }
            for (0..lane_count) |lane| {
                for (ctx.sorted_columns, 0..) |column, column_index| {
                    const shift_amt: std.math.Log2Int(usize) = @intCast(ctx.max_log_size - column.log_size + 1);
                    const leaf_position = position + lane;
                    const source_index = ((leaf_position >> shift_amt) << 1) + (leaf_position & 1);
                    const encoded = column.values[source_index].toBytesLe();
                    const start = lane * bytes_per_leaf + column_index * @sizeOf(M31);
                    @memcpy(buffer[start .. start + @sizeOf(M31)], encoded[0..]);
                }
            }
        }

        fn buildLeavesBatchedRangeScalar(ctx: *const BatchedLeafRangeCtx) void {
            var position = ctx.start;
            while (position < ctx.end) : (position += 1) {
                var hasher = ctx.seed_hasher;
                for (ctx.sorted_columns) |column| {
                    const shift_amt: std.math.Log2Int(usize) = @intCast(ctx.max_log_size - column.log_size + 1);
                    const source_index = ((position >> shift_amt) << 1) + (position & 1);
                    hasher.updateLeaf(column.values[source_index .. source_index + 1]);
                }
                ctx.out[position] = hasher.finalize();
            }
        }

        fn buildLeavesBatched(
            allocator: std.mem.Allocator,
            layer_alloc: std.mem.Allocator,
            sorted_columns: []const ColumnRef,
            batch_size: usize,
        ) ![]H.Hash {
            var seed_hasher = H.defaultWithInitialState();
            if (sorted_columns.len == 0) {
                const layer = try layer_alloc.alloc(H.Hash, 1);
                layer[0] = seed_hasher.finalize();
                return layer;
            }

            if (sorted_columns[0].values.len == 1) return error.InvalidColumnSize;

            // The maximum log size determines the total leaf count.
            const max_log_size: u32 = sorted_columns[sorted_columns.len - 1].log_size;
            const total_leaves: usize = @as(usize, 1) << @intCast(max_log_size);

            const out = try layer_alloc.alloc(H.Hash, total_leaves);
            errdefer layer_alloc.free(out);

            const pool = work_pool_mod.getGlobalPool();
            const worker_capacity = total_leaves / parallel_min_nodes_per_worker;
            const worker_count = if (pool) |active_pool|
                @max(@as(usize, 1), @min(active_pool.workerCount(), worker_capacity))
            else
                1;
            const per_worker_batch = @min(@min(batch_size, total_leaves), @as(usize, 1024));
            const hashers = try allocator.alloc(H, worker_count * per_worker_batch);
            defer allocator.free(hashers);
            const scratch_words_per_worker = max_leaf_scratch_bytes / @sizeOf(M31);
            const scratch_words = if (comptime @hasDecl(H, "updateLeafPackedBytes"))
                allocator.alloc(M31, worker_count * scratch_words_per_worker) catch null
            else
                null;
            defer if (scratch_words) |words| allocator.free(words);

            var contexts: [max_parallel_workers]BatchedLeafRangeCtx = undefined;
            const batches = (total_leaves + per_worker_batch - 1) / per_worker_batch;
            const batches_per_worker = (batches + worker_count - 1) / worker_count;
            for (0..worker_count) |worker| {
                const start = @min(total_leaves, worker * batches_per_worker * per_worker_batch);
                const end = @min(total_leaves, start + batches_per_worker * per_worker_batch);
                contexts[worker] = .{
                    .seed_hasher = seed_hasher,
                    .sorted_columns = sorted_columns,
                    .max_log_size = max_log_size,
                    .out = out,
                    .batch_hashers = hashers[worker * per_worker_batch ..][0..per_worker_batch],
                    .scratch = if (scratch_words) |words| blk: {
                        const scratch_start = worker * scratch_words_per_worker;
                        break :blk std.mem.sliceAsBytes(words[scratch_start..][0..scratch_words_per_worker]);
                    } else null,
                    .start = start,
                    .end = end,
                };
            }

            if (worker_count > 1) {
                var wait_group: WaitGroup = .{};
                for (contexts[1..worker_count]) |*ctx| {
                    pool.?.spawnWg(&wait_group, buildLeavesBatchedRange, .{@as(*const BatchedLeafRangeCtx, ctx)});
                }
                buildLeavesBatchedRange(&contexts[0]);
                wait_group.wait();
            } else {
                buildLeavesBatchedRange(&contexts[0]);
            }

            return out;
        }

        const FinalizeRangeCtx = struct {
            hashers: []H,
            out: []H.Hash,
            start: usize,
            end: usize,
        };

        fn finalizeRange(ctx: *const FinalizeRangeCtx) void {
            var i = ctx.start;
            while (i < ctx.end) : (i += 1) {
                ctx.out[i] = ctx.hashers[i].finalize();
            }
        }

        fn finalizeRangeThread(ctx: *const FinalizeRangeCtx) void {
            finalizeRange(ctx);
        }

        fn finalizeLeafHashersParallel(hashers: []H, out: []H.Hash) void {
            std.debug.assert(hashers.len == out.len);
            std.debug.assert(hashers.len >= parallel_min_nodes);

            const worker_count = blk: {
                const capacity = hashers.len / parallel_min_nodes_per_worker;
                if (capacity < 2) break :blk @as(usize, 1);
                const cpu_count = std.Thread.getCpuCount() catch break :blk @as(usize, 1);
                break :blk @min(@min(cpu_count, capacity), max_parallel_workers);
            };

            if (worker_count <= 1) {
                for (hashers, 0..) |*h, i| out[i] = h.finalize();
                return;
            }

            // Try to use the unified global pool first, then the Merkle shared pool.
            const pool_ptr: *ThreadPool = blk: {
                if (work_pool_mod.getGlobalPool()) |global_pool| {
                    break :blk &global_pool.pool;
                }
                break :blk LayerExecutor.sharedThreadPool() orelse {
                    for (hashers, 0..) |*h, i| out[i] = h.finalize();
                    return;
                };
            };

            var contexts: [max_parallel_workers]FinalizeRangeCtx = undefined;
            const chunk_len = (hashers.len + worker_count - 1) / worker_count;
            var actual_workers: usize = 0;
            var start: usize = 0;
            while (start < hashers.len and actual_workers < worker_count) : (actual_workers += 1) {
                const end = @min(hashers.len, start + chunk_len);
                contexts[actual_workers] = FinalizeRangeCtx{
                    .hashers = hashers,
                    .out = out,
                    .start = start,
                    .end = end,
                };
                start = end;
            }
            if (actual_workers <= 1) {
                finalizeRange(&contexts[0]);
                return;
            }

            var wait_group: WaitGroup = .{};
            for (1..actual_workers) |i| {
                pool_ptr.spawnWg(&wait_group, finalizeRangeThread, .{&contexts[i]});
            }
            finalizeRange(&contexts[0]);
            wait_group.wait();
        }

        const PackedLeafRangeCtx = struct {
            scratch: []align(@alignOf(M31)) u8,
            leaf_hashers: []H,
            group_columns: []const ColumnRef,
            start: usize,
            end: usize,
        };

        fn updateLeafHashersPackedRange(ctx: *const PackedLeafRangeCtx) void {
            var tile_start = ctx.start;
            while (tile_start < ctx.end) : (tile_start += leaf_tile_len) {
                const tile_end = @min(ctx.end, tile_start + leaf_tile_len);
                const tile_size = tile_end - tile_start;
                const max_chunk_columns = @max(
                    @as(usize, 1),
                    max_leaf_scratch_bytes / (tile_size * @sizeOf(M31)),
                );

                var column_start: usize = 0;
                while (column_start < ctx.group_columns.len) {
                    const column_end = @min(ctx.group_columns.len, column_start + max_chunk_columns);
                    const column_chunk = ctx.group_columns[column_start..column_end];
                    const bytes_per_leaf = column_chunk.len * @sizeOf(M31);
                    const scratch_len = tile_size * bytes_per_leaf;
                    packLeafTileBytes(
                        ctx.scratch[0..scratch_len],
                        column_chunk,
                        tile_start,
                        tile_size,
                    );

                    for (0..tile_size) |local_leaf| {
                        const byte_start = local_leaf * bytes_per_leaf;
                        ctx.leaf_hashers[tile_start + local_leaf].updateLeafPackedBytes(
                            ctx.scratch[byte_start .. byte_start + bytes_per_leaf],
                        );
                    }
                    column_start = column_end;
                }
            }
        }

        fn updateLeafHashersPacked(
            allocator: std.mem.Allocator,
            leaf_hashers: []H,
            group_columns: []const ColumnRef,
            layer_size: usize,
        ) !void {
            const pool = work_pool_mod.getGlobalPool();
            const worker_count = if (pool) |active_pool|
                @min(active_pool.workerCount(), layer_size / parallel_min_nodes_per_worker)
            else
                1;
            const actual_workers = @max(@as(usize, 1), worker_count);
            const scratch_words_per_worker = max_leaf_scratch_bytes / @sizeOf(M31);
            const scratch_words = try allocator.alloc(M31, actual_workers * scratch_words_per_worker);
            defer allocator.free(scratch_words);

            var contexts: [max_parallel_workers]PackedLeafRangeCtx = undefined;
            const tiles = (layer_size + leaf_tile_len - 1) / leaf_tile_len;
            const tiles_per_worker = (tiles + actual_workers - 1) / actual_workers;
            for (0..actual_workers) |worker| {
                const start = @min(layer_size, worker * tiles_per_worker * leaf_tile_len);
                const end = @min(layer_size, start + tiles_per_worker * leaf_tile_len);
                const scratch_start = worker * scratch_words_per_worker;
                contexts[worker] = .{
                    .scratch = std.mem.sliceAsBytes(scratch_words[scratch_start..][0..scratch_words_per_worker]),
                    .leaf_hashers = leaf_hashers,
                    .group_columns = group_columns,
                    .start = start,
                    .end = end,
                };
            }

            if (actual_workers > 1) {
                var wait_group: WaitGroup = .{};
                for (contexts[1..actual_workers]) |*ctx| {
                    pool.?.spawnWg(&wait_group, updateLeafHashersPackedRange, .{@as(*const PackedLeafRangeCtx, ctx)});
                }
                updateLeafHashersPackedRange(&contexts[0]);
                wait_group.wait();
                return;
            }
            updateLeafHashersPackedRange(&contexts[0]);
        }

        fn packLeafTileBytes(
            scratch: []align(@alignOf(M31)) u8,
            column_chunk: []const ColumnRef,
            tile_start: usize,
            tile_size: usize,
        ) void {
            const bytes_per_leaf = column_chunk.len * @sizeOf(M31);
            std.debug.assert(scratch.len == tile_size * bytes_per_leaf);

            if (builtin.cpu.arch.endian() == .little) {
                const scratch_words = std.mem.bytesAsSlice(M31, scratch);
                var local_leaf: usize = 0;
                while (local_leaf < tile_size) : (local_leaf += 1) {
                    const leaf_words = scratch_words[local_leaf * column_chunk.len ..][0..column_chunk.len];
                    const leaf_index = tile_start + local_leaf;
                    for (column_chunk, 0..) |column, column_idx| {
                        leaf_words[column_idx] = column.values[leaf_index];
                    }
                }
                return;
            }

            var local_leaf: usize = 0;
            while (local_leaf < tile_size) : (local_leaf += 1) {
                const leaf_index = tile_start + local_leaf;
                const leaf_start = local_leaf * bytes_per_leaf;
                for (column_chunk, 0..) |column, column_idx| {
                    const encoded = column.values[leaf_index].toBytesLe();
                    const byte_start = leaf_start + (column_idx * @sizeOf(M31));
                    @memcpy(scratch[byte_start .. byte_start + @sizeOf(M31)], encoded[0..]);
                }
            }
        }

        fn buildNextLayer(
            allocator: std.mem.Allocator,
            prev_layer: []const H.Hash,
            executor: *LayerExecutor,
            worker_override: ?usize,
        ) ![]H.Hash {
            std.debug.assert(prev_layer.len > 1 and std.math.isPowerOfTwo(prev_layer.len));
            const out = try allocator.alloc(H.Hash, prev_layer.len >> 1);
            const workers = parallelWorkersForLayer(out.len, worker_override);

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

        fn hashSeededRangeThread(ctx: *const SeededRangeCtx) void {
            hashSeededRange(ctx);
        }

        fn buildNextLayerSeededParallel(
            out: []H.Hash,
            prev_layer: []const H.Hash,
            seed: NodeSeed,
            worker_count: usize,
            executor: *LayerExecutor,
        ) !void {
            std.debug.assert(worker_count > 1);
            std.debug.assert(worker_count <= max_parallel_workers);
            std.debug.assert(executor.enabled);
            var contexts: [max_parallel_workers]SeededRangeCtx = undefined;

            const chunk_len = (out.len + worker_count - 1) / worker_count;
            var actual_workers: usize = 0;
            var start: usize = 0;
            while (start < out.len and actual_workers < worker_count) : (actual_workers += 1) {
                const end = @min(out.len, start + chunk_len);
                contexts[actual_workers] = SeededRangeCtx{
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
                executor.pool().spawnWg(&wait_group, hashSeededRangeThread, .{&contexts[i]});
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

        fn hashBasicRangeThread(ctx: *const BasicRangeCtx) void {
            hashBasicRange(ctx);
        }

        fn buildNextLayerBasicParallel(
            out: []H.Hash,
            prev_layer: []const H.Hash,
            worker_count: usize,
            executor: *LayerExecutor,
        ) !void {
            std.debug.assert(worker_count > 1);
            std.debug.assert(worker_count <= max_parallel_workers);
            std.debug.assert(executor.enabled);
            var contexts: [max_parallel_workers]BasicRangeCtx = undefined;

            const chunk_len = (out.len + worker_count - 1) / worker_count;
            var actual_workers: usize = 0;
            var start: usize = 0;
            while (start < out.len and actual_workers < worker_count) : (actual_workers += 1) {
                const end = @min(out.len, start + chunk_len);
                contexts[actual_workers] = BasicRangeCtx{
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
                executor.pool().spawnWg(&wait_group, hashBasicRangeThread, .{&contexts[i]});
            }
            hashBasicRange(&contexts[0]);
            wait_group.wait();
        }
        /// Streaming committer that builds a Merkle tree incrementally from column
        /// batches.  Each batch's column data is consumed and can be freed before
        /// the next batch is fed, reducing peak memory.
        ///
        /// Usage:
        ///   1. `init()` — start a streaming commitment for a known total column set.
        ///   2. `addColumns()` — feed one or more batches of columns (must be
        ///       supplied in ascending log-size order, matching `sortColumnsByLogSizeAsc`).
        ///   3. `finalize()` — finalise the leaf hashes, build the internal tree
        ///       layers, and return the completed `MerkleProverLifted`.
        ///
        /// The resulting Merkle root is bit-identical to calling `commit()` with all
        /// columns at once.
        pub const StreamingCommitter = struct {
            allocator: std.mem.Allocator,
            /// Leaf hasher state — one hasher per leaf position.
            /// Grows (via expansion) as larger log_size columns are encountered.
            leaf_hashers: []H,
            /// Current log_size of the leaf hasher array (number of positions = 1 << leaf_log_size).
            leaf_log_size: u32,
            /// Whether any columns have been added yet.
            initialized: bool,

            pub fn init(allocator: std.mem.Allocator) StreamingCommitter {
                return .{
                    .allocator = allocator,
                    .leaf_hashers = &[_]H{},
                    .leaf_log_size = 0,
                    .initialized = false,
                };
            }

            pub fn deinit(self: *StreamingCommitter) void {
                if (self.leaf_hashers.len > 0) {
                    self.allocator.free(self.leaf_hashers);
                }
                self.* = undefined;
            }

            /// Feed a batch of columns into the streaming hasher.
            ///
            /// Columns MUST be supplied in ascending log_size order (matching
            /// `sortColumnsByLogSizeAsc` within each batch and across batches).
            /// Columns with the same log_size as columns from a previous batch
            /// are permitted — they extend the same group.
            ///
            /// After this call returns, the caller may free the column value
            /// slices; their data has been absorbed into the leaf hasher state.
            pub fn addColumns(
                self: *StreamingCommitter,
                columns: []const ColumnRef,
            ) !void {
                if (columns.len == 0) return;

                for (columns) |column| {
                    if (!std.math.isPowerOfTwo(column.values.len) or column.values.len < 2) {
                        return error.InvalidColumnSize;
                    }
                }

                // Initialize seed hasher on first call.
                if (!self.initialized) {
                    const seed_hasher = H.defaultWithInitialState();
                    const first_log_size = columns[0].log_size;
                    const first_size = @as(usize, 1) << @intCast(first_log_size);
                    self.leaf_hashers = try self.allocator.alloc(H, first_size);
                    for (self.leaf_hashers) |*h| h.* = seed_hasher;
                    self.leaf_log_size = first_log_size;
                    self.initialized = true;
                }

                // Process columns in groups by log_size.
                var group_start: usize = 0;
                while (group_start < columns.len) {
                    const log_size = columns[group_start].log_size;
                    var group_end = group_start + 1;
                    while (group_end < columns.len and
                        columns[group_end].log_size == log_size)
                    {
                        group_end += 1;
                    }

                    // Expand leaf hashers if needed for this log_size.
                    if (log_size > self.leaf_log_size) {
                        const log_ratio = log_size - self.leaf_log_size;
                        const layer_size = @as(usize, 1) << @intCast(log_size);
                        const shift_amt: std.math.Log2Int(usize) = @intCast(log_ratio + 1);
                        const expanded = try self.allocator.alloc(H, layer_size);
                        for (0..layer_size) |idx| {
                            const src_idx = ((idx >> shift_amt) << 1) + (idx & 1);
                            expanded[idx] = self.leaf_hashers[src_idx];
                        }
                        self.allocator.free(self.leaf_hashers);
                        self.leaf_hashers = expanded;
                        self.leaf_log_size = log_size;
                    }

                    const layer_size = self.leaf_hashers.len;
                    const group_columns = columns[group_start..group_end];

                    // Feed column values into leaf hashers — same logic as buildLeaves.
                    if (comptime @hasDecl(H, "updateLeafPackedBytes")) {
                        try updateLeafHashersPacked(
                            self.allocator,
                            self.leaf_hashers,
                            group_columns,
                            layer_size,
                        );
                    } else {
                        var idx: usize = 0;
                        while (idx < layer_size) : (idx += 1) {
                            for (group_columns) |column| {
                                self.leaf_hashers[idx].updateLeaf(column.values[idx .. idx + 1]);
                            }
                        }
                    }

                    group_start = group_end;
                }
            }

            /// Finalize the streaming commitment: produce leaf hashes from the
            /// accumulated hasher state, build internal Merkle layers, and return
            /// the completed tree.  The `StreamingCommitter` is consumed (its
            /// hasher memory is freed).
            pub fn finalize(self: *StreamingCommitter) !Self {
                const allocator = self.allocator;
                const layer_alloc = layerAllocator(allocator);
                if (!self.initialized) {
                    // No columns were added — replicate the empty-column path
                    // from buildLeaves.
                    const seed_hasher = H.defaultWithInitialState();
                    var h = seed_hasher;
                    const leaves = try layer_alloc.alloc(H.Hash, 1);
                    leaves[0] = h.finalize();

                    var layers_bottom_up = std.ArrayList([]H.Hash).empty;
                    defer layers_bottom_up.deinit(allocator);
                    errdefer {
                        for (layers_bottom_up.items) |layer| layer_alloc.free(layer);
                    }
                    try layers_bottom_up.append(allocator, leaves);

                    const out_layers = try allocator.alloc([]H.Hash, 1);
                    out_layers[0] = leaves;
                    self.* = undefined;
                    return .{ .layers = out_layers, .layer_allocator = layer_alloc };
                }

                // Finalize leaf hashers into leaf hashes.
                const leaf_count = self.leaf_hashers.len;
                const leaves = try layer_alloc.alloc(H.Hash, leaf_count);
                if (leaf_count >= parallel_min_nodes and !builtin.single_threaded)
                    finalizeLeafHashersParallel(self.leaf_hashers, leaves)
                else for (self.leaf_hashers, 0..) |*hasher, i| leaves[i] = hasher.finalize();
                // Free hasher state — column data is no longer needed.
                allocator.free(self.leaf_hashers);
                self.leaf_hashers = &[_]H{};

                // Build internal tree layers — identical to commitWithOptions.
                const worker_override = merkleWorkerOverride(allocator);
                const reuse_pool = merklePoolReuseEnabled(allocator);

                var layers_bottom_up = std.ArrayList([]H.Hash).empty;
                defer layers_bottom_up.deinit(allocator);
                errdefer {
                    for (layers_bottom_up.items) |layer| layer_alloc.free(layer);
                }
                try layers_bottom_up.append(allocator, leaves);

                if (leaves.len > 1) {
                    std.debug.assert(std.math.isPowerOfTwo(leaves.len));
                    const max_log_size = std.math.log2_int(usize, leaves.len);
                    const max_out_len = leaves.len >> 1;
                    var executor: LayerExecutor = undefined;
                    executor.init(parallelWorkersForLayer(max_out_len, worker_override), reuse_pool);
                    defer executor.deinit();

                    var i: usize = 0;
                    while (i < max_log_size) : (i += 1) {
                        const next_layer = try buildNextLayer(
                            layer_alloc,
                            layers_bottom_up.items[layers_bottom_up.items.len - 1],
                            &executor,
                            worker_override,
                        );
                        try layers_bottom_up.append(allocator, next_layer);
                    }
                }

                const out_layers = try allocator.alloc([]H.Hash, layers_bottom_up.items.len);
                var i: usize = 0;
                while (i < out_layers.len) : (i += 1) {
                    out_layers[i] = layers_bottom_up.items[out_layers.len - 1 - i];
                }
                self.* = undefined;
                return .{ .layers = out_layers, .layer_allocator = layer_alloc };
            }
        };

        /// `builtin.is_test` keeps structural tests close to their assertions
        /// without making these internals callable from production builds.
        pub const testing = if (builtin.is_test) struct {
            pub fn commitWithWorkerOverride(
                allocator: std.mem.Allocator,
                columns: []const []const M31,
                worker_override: ?usize,
            ) !Self {
                return Self.commitWithWorkerOverride(allocator, columns, worker_override);
            }

            pub fn buildLeaves(
                allocator: std.mem.Allocator,
                layer_alloc: std.mem.Allocator,
                sorted_columns: []const ColumnRef,
            ) ![]H.Hash {
                return Self.buildLeaves(allocator, layer_alloc, sorted_columns);
            }

            pub fn buildLeavesBatched(
                allocator: std.mem.Allocator,
                layer_alloc: std.mem.Allocator,
                sorted_columns: []const ColumnRef,
                batch_size: usize,
            ) ![]H.Hash {
                return Self.buildLeavesBatched(allocator, layer_alloc, sorted_columns, batch_size);
            }
        } else struct {};
    };
}
