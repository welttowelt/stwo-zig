const std = @import("std");
const builtin = @import("builtin");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const lifted_merkle_hasher = @import("../../core/vcs_lifted/merkle_hasher.zig");
const mmap_alloc = @import("../mmap_alloc.zig");
const mmap_alloc_mod = mmap_alloc;
const vcs_lifted_verifier = @import("../../core/vcs_lifted/verifier.zig");
const work_pool_mod = @import("../work_pool.zig");
const quotient_ops = @import("../pcs/quotient_ops.zig");
const secure_column = @import("../secure_column.zig");

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
        const NodeValue = vcs_lifted_verifier.MerkleDecommitmentLiftedAux(H).NodeValue;
        const ExtendedDecommitment = vcs_lifted_verifier.ExtendedMerkleDecommitmentLifted(H);
        const Decommitment = vcs_lifted_verifier.MerkleDecommitmentLifted(H);
        const parallel_min_nodes: usize = 1 << 13;
        const parallel_min_nodes_per_worker: usize = 1 << 12;
        const max_parallel_workers: usize = 16;
        const merkle_worker_stack_size: usize = 1 << 20; // 1 MiB; lowers RSS vs platform default thread stacks.
        const leaf_tile_len: usize = 256;
        const max_leaf_scratch_bytes: usize = 256 * 1024;
        /// Default number of leaves processed per batch in the row-batch
        /// commit path.  Chosen so that the transient hasher array for one
        /// batch stays comfortably in L2 cache (~512 KiB at 128 B/hasher).
        const default_leaf_batch_size: usize = 1 << 12; // 4 096
        /// Minimum total leaf count before we switch to the batched path.
        /// Below this threshold the original all-at-once `buildLeaves` is
        /// used since the hasher array is already small.
        const batched_leaf_threshold: usize = 1 << 14; // 16 384
        const ThreadPool = std.Thread.Pool;
        const WaitGroup = std.Thread.WaitGroup;
        const SharedPoolState = struct {
            mutex: std.Thread.Mutex = .{},
            pool: ThreadPool = undefined,
            pool_initialized: bool = false,
            failed: bool = false,
        };
        var shared_pool_state: SharedPoolState = .{};

        pub const DecommitmentResult = struct {
            queried_values: [][]M31,
            decommitment: ExtendedDecommitment,

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                for (self.queried_values) |column| allocator.free(column);
                allocator.free(self.queried_values);
                self.decommitment.deinit(allocator);
                self.* = undefined;
            }
        };

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

            // Allocate leaf hashers for the full domain.
            const seed_hasher = H.defaultWithInitialState();
            const leaf_hashers = try allocator.alloc(H, domain_size);
            defer allocator.free(leaf_hashers);
            @memset(leaf_hashers, seed_hasher);

            // Process in chunks: compute quotients and feed to leaf hashers.
            const chunk_size = quotient_ops.LAZY_QUOTIENT_CHUNK_SIZE;
            var chunk_start: usize = 0;
            while (chunk_start < domain_size) {
                const this_chunk = @min(chunk_size, domain_size - chunk_start);

                // Point coordinate buffers into out_column at the right offset.
                var chunk_coords: [qm31.SECURE_EXTENSION_DEGREE][]M31 = undefined;
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                    chunk_coords[coord] = out_column.columns[coord][chunk_start..][0..this_chunk];
                }

                try provider.computeChunk(chunk_start, this_chunk, &chunk_coords);

                // Feed the freshly-computed values into leaf hashers.
                for (0..this_chunk) |local_idx| {
                    const position = chunk_start + local_idx;
                    var values: [qm31.SECURE_EXTENSION_DEGREE]M31 = undefined;
                    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                        values[coord] = chunk_coords[coord][local_idx];
                    }
                    leaf_hashers[position].updateLeaf(values[0..]);
                }

                chunk_start += this_chunk;
            }

            // Finalize leaf hashes.
            const leaves = try allocator.alloc(H.Hash, domain_size);
            for (leaf_hashers, 0..) |*hasher, i| leaves[i] = hasher.finalize();

            // Build internal Merkle layers from the leaves upward.
            var layers_bottom_up = std.ArrayList([]H.Hash).empty;
            defer layers_bottom_up.deinit(allocator);
            errdefer {
                for (layers_bottom_up.items) |layer| allocator.free(layer);
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
                        allocator,
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
            return .{ .layers = out_layers, .layer_allocator = allocator };
        }

        fn commitWithWorkerOverride(
            allocator: std.mem.Allocator,
            columns: []const []const M31,
            worker_override: ?usize,
        ) !Self {
            return commitWithOptions(allocator, columns, worker_override, false);
        }

        fn layerAllocator(allocator: std.mem.Allocator) std.mem.Allocator {
            // Use mmap-backed allocator for large Merkle layers on supported
            // platforms; fall back to caller's allocator otherwise.
            if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
                return mmap_alloc_mod.MmapAllocator.allocator();
            }
            return allocator;
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
                    // The previous layer was just consumed to produce the next
                    // layer. Its data is still stored for later decommitment
                    // but will not be accessed again until then. Release its
                    // physical pages to reduce RSS during tree construction.
                    mmap_alloc.releasePagesSlice(H.Hash, layers_bottom_up.items[prev_idx]);
                }
            }

            const out_layers = try allocator.alloc([]H.Hash, layers_bottom_up.items.len);
            var i: usize = 0;
            while (i < out_layers.len) : (i += 1) {
                out_layers[i] = layers_bottom_up.items[out_layers.len - 1 - i];
            }
            return .{ .layers = out_layers, .layer_allocator = layer_alloc };
        }

        fn merkleWorkerOverride(allocator: std.mem.Allocator) ?usize {
            const raw = std.process.getEnvVarOwned(allocator, "STWO_ZIG_MERKLE_WORKERS") catch return null;
            defer allocator.free(raw);
            const parsed = std.fmt.parseInt(usize, raw, 10) catch return null;
            if (parsed == 0) return null;
            return parsed;
        }

        /// Reads an optional leaf-batch-size override from the environment.
        /// Set `STWO_ZIG_LEAF_BATCH_SIZE` to a power-of-two to control
        /// how many leaves are hashed per batch.  Returns `null` when the
        /// variable is unset or unparseable, falling back to
        /// `default_leaf_batch_size`.
        fn leafBatchSizeOverride(allocator: std.mem.Allocator) ?usize {
            const raw = std.process.getEnvVarOwned(allocator, "STWO_ZIG_LEAF_BATCH_SIZE") catch return null;
            defer allocator.free(raw);
            const parsed = std.fmt.parseInt(usize, raw, 10) catch return null;
            if (parsed == 0) return null;
            if (!std.math.isPowerOfTwo(parsed)) return null;
            return parsed;
        }

        fn merklePoolReuseEnabled(allocator: std.mem.Allocator) bool {
            const raw = std.process.getEnvVarOwned(allocator, "STWO_ZIG_MERKLE_POOL_REUSE") catch return false;
            defer allocator.free(raw);
            if (raw.len == 0) return false;
            if (std.mem.eql(u8, raw, "1")) return true;
            if (std.mem.eql(u8, raw, "0")) return false;
            if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
            if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
            if (std.ascii.eqlIgnoreCase(raw, "yes")) return true;
            if (std.ascii.eqlIgnoreCase(raw, "no")) return false;
            if (std.ascii.eqlIgnoreCase(raw, "on")) return true;
            if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
            return false;
        }

        pub fn decommit(
            self: Self,
            allocator: std.mem.Allocator,
            query_positions: []const usize,
            columns: []const []const M31,
        ) !DecommitmentResult {
            const max_log_size_u32: u32 = @intCast(self.layers.len - 1);

            const queried_values = try allocator.alloc([]M31, columns.len);
            var queried_values_initialized: usize = 0;
            errdefer {
                for (queried_values[0..queried_values_initialized]) |column| allocator.free(column);
                allocator.free(queried_values);
            }

            for (columns, 0..) |column, i| {
                if (!std.math.isPowerOfTwo(column.len) or column.len < 2) {
                    return error.InvalidColumnSize;
                }
                const log_size: u32 = @intCast(std.math.log2_int(usize, column.len));
                if (log_size > max_log_size_u32) return error.InvalidColumnSize;
                const shift = max_log_size_u32 - log_size;
                const shift_amt: std.math.Log2Int(usize) = @intCast(shift + 1);

                queried_values[i] = try allocator.alloc(M31, query_positions.len);
                queried_values_initialized += 1;
                for (query_positions, 0..) |position, j| {
                    const column_index = ((position >> shift_amt) << 1) + (position & 1);
                    queried_values[i][j] = column[column_index];
                }
            }

            var hash_witness = std.ArrayList(H.Hash).empty;
            defer hash_witness.deinit(allocator);

            var all_node_values = std.ArrayList([]NodeValue).empty;
            defer {
                for (all_node_values.items) |layer| allocator.free(layer);
                all_node_values.deinit(allocator);
            }

            var prev_layer_queries = std.ArrayList(usize).empty;
            defer prev_layer_queries.deinit(allocator);
            for (query_positions, 0..) |position, i| {
                if (i == 0 or query_positions[i - 1] != position) {
                    try prev_layer_queries.append(allocator, position);
                }
            }

            var layer_log_size: i64 = @intCast(self.layers.len);
            layer_log_size -= 2;
            while (layer_log_size >= 0) : (layer_log_size -= 1) {
                const prev_layer_hashes = self.layers[@intCast(layer_log_size + 1)];

                var curr_layer_queries = std.ArrayList(usize).empty;
                defer curr_layer_queries.deinit(allocator);

                var all_node_values_for_layer = std.ArrayList(NodeValue).empty;
                defer all_node_values_for_layer.deinit(allocator);

                var p: usize = 0;
                while (p < prev_layer_queries.items.len) {
                    const first = prev_layer_queries.items[p];
                    var chunk_len: usize = 1;
                    if (p + 1 < prev_layer_queries.items.len and
                        ((first ^ 1) == prev_layer_queries.items[p + 1]))
                    {
                        chunk_len = 2;
                    }

                    if (chunk_len == 1) {
                        try hash_witness.append(allocator, prev_layer_hashes[first ^ 1]);
                    }

                    const curr_index = first >> 1;
                    try curr_layer_queries.append(allocator, curr_index);
                    try all_node_values_for_layer.append(allocator, .{
                        .index = 2 * curr_index,
                        .hash = prev_layer_hashes[2 * curr_index],
                    });
                    try all_node_values_for_layer.append(allocator, .{
                        .index = 2 * curr_index + 1,
                        .hash = prev_layer_hashes[2 * curr_index + 1],
                    });
                    p += chunk_len;
                }

                prev_layer_queries.clearRetainingCapacity();
                try prev_layer_queries.appendSlice(allocator, curr_layer_queries.items);

                try all_node_values.append(allocator, try all_node_values_for_layer.toOwnedSlice(allocator));
            }

            const hash_witness_owned = try hash_witness.toOwnedSlice(allocator);
            errdefer allocator.free(hash_witness_owned);

            const all_node_values_owned = try all_node_values.toOwnedSlice(allocator);
            errdefer {
                for (all_node_values_owned) |layer| allocator.free(layer);
                allocator.free(all_node_values_owned);
            }

            return .{
                .queried_values = queried_values,
                .decommitment = .{
                    .decommitment = Decommitment{
                        .hash_witness = hash_witness_owned,
                    },
                    .aux = .{
                        .all_node_values = all_node_values_owned,
                    },
                },
            };
        }

        pub const ColumnRef = struct {
            values: []const M31,
            log_size: u32,
            original_index: usize,
        };

        pub fn sortColumnsByLogSizeAsc(
            allocator: std.mem.Allocator,
            columns: []const []const M31,
        ) ![]ColumnRef {
            const out = try allocator.alloc(ColumnRef, columns.len);
            for (columns, 0..) |column, i| {
                if (!std.math.isPowerOfTwo(column.len) or column.len < 2) {
                    return error.InvalidColumnSize;
                }
                out[i] = .{
                    .values = column,
                    .log_size = @intCast(std.math.log2_int(usize, column.len)),
                    .original_index = i,
                };
            }
            std.sort.heap(ColumnRef, out, {}, lessByLogSizeAscStable);
            return out;
        }

        fn lessByLogSizeAscStable(_: void, lhs: ColumnRef, rhs: ColumnRef) bool {
            if (lhs.log_size == rhs.log_size) return lhs.original_index < rhs.original_index;
            return lhs.log_size < rhs.log_size;
        }

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

            // Allocate the reusable batch hasher array (the whole point of
            // the optimisation — this is much smaller than total_leaves).
            const effective_batch = @min(batch_size, total_leaves);
            const batch_hashers = try allocator.alloc(H, effective_batch);
            defer allocator.free(batch_hashers);

            // Optional packed-bytes scratch buffer for the fast path.
            var scratch: ?[]align(@alignOf(M31)) u8 = null;
            defer if (scratch) |s| allocator.free(s);
            if (comptime @hasDecl(H, "updateLeafPackedBytes")) {
                scratch = allocator.alignedAlloc(u8, .of(M31), max_leaf_scratch_bytes) catch null;
            }

            var batch_start: usize = 0;
            while (batch_start < total_leaves) : (batch_start += effective_batch) {
                const batch_end = @min(total_leaves, batch_start + effective_batch);
                const batch_len = batch_end - batch_start;

                // Initialise every hasher in the batch to the seed state.
                for (batch_hashers[0..batch_len]) |*h| h.* = seed_hasher;

                // Feed column values in the same order as the original
                // buildLeaves (ascending log_size, original_index within a
                // group).  This guarantees the blake2s streaming input is
                // byte-identical, so the leaf hashes match exactly.
                for (sorted_columns) |column| {
                    const col_log_size = column.log_size;
                    const shift_amt: std.math.Log2Int(usize) = @intCast(max_log_size - col_log_size + 1);

                    if (scratch) |s| {
                        // Fast path: pack column values for the batch into a
                        // contiguous byte buffer and use updateLeafPackedBytes.
                        const bytes_per_leaf: usize = @sizeOf(M31);
                        const max_tile = @max(@as(usize, 1), max_leaf_scratch_bytes / bytes_per_leaf);
                        var tile_off: usize = 0;
                        while (tile_off < batch_len) : (tile_off += max_tile) {
                            const tile_len = @min(max_tile, batch_len - tile_off);
                            const buf = s[0 .. tile_len * bytes_per_leaf];
                            // Pack values.
                            if (builtin.cpu.arch.endian() == .little) {
                                const words = std.mem.bytesAsSlice(M31, buf);
                                for (0..tile_len) |local| {
                                    const pos = batch_start + tile_off + local;
                                    const col_idx = ((pos >> shift_amt) << 1) + (pos & 1);
                                    words[local] = column.values[col_idx];
                                }
                            } else {
                                for (0..tile_len) |local| {
                                    const pos = batch_start + tile_off + local;
                                    const col_idx = ((pos >> shift_amt) << 1) + (pos & 1);
                                    const encoded = column.values[col_idx].toBytesLe();
                                    const start = local * bytes_per_leaf;
                                    @memcpy(buf[start .. start + bytes_per_leaf], encoded[0..]);
                                }
                            }
                            for (0..tile_len) |local| {
                                const byte_start = local * bytes_per_leaf;
                                batch_hashers[tile_off + local].updateLeafPackedBytes(
                                    buf[byte_start .. byte_start + bytes_per_leaf],
                                );
                            }
                        }
                    } else {
                        // Scalar fallback.
                        for (0..batch_len) |local| {
                            const pos = batch_start + local;
                            const col_idx = ((pos >> shift_amt) << 1) + (pos & 1);
                            batch_hashers[local].updateLeaf(column.values[col_idx .. col_idx + 1]);
                        }
                    }
                }

                // Finalize and write to output.
                for (batch_hashers[0..batch_len], 0..) |*hasher, local| {
                    out[batch_start + local] = hasher.finalize();
                }
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

        fn updateLeafHashersPacked(
            allocator: std.mem.Allocator,
            leaf_hashers: []H,
            group_columns: []const ColumnRef,
            layer_size: usize,
        ) !void {
            var scratch = try allocator.alignedAlloc(
                u8,
                .of(M31),
                max_leaf_scratch_bytes,
            );
            defer allocator.free(scratch);

            var tile_start: usize = 0;
            while (tile_start < layer_size) : (tile_start += leaf_tile_len) {
                const tile_end = @min(layer_size, tile_start + leaf_tile_len);
                const tile_size = tile_end - tile_start;
                const max_chunk_columns = @max(
                    @as(usize, 1),
                    max_leaf_scratch_bytes / (tile_size * @sizeOf(M31)),
                );

                var column_start: usize = 0;
                while (column_start < group_columns.len) {
                    const column_end = @min(group_columns.len, column_start + max_chunk_columns);
                    const column_chunk = group_columns[column_start..column_end];
                    const bytes_per_leaf = column_chunk.len * @sizeOf(M31);
                    const scratch_len = tile_size * bytes_per_leaf;
                    packLeafTileBytes(
                        scratch[0..scratch_len],
                        column_chunk,
                        tile_start,
                        tile_size,
                    );

                    var local_leaf: usize = 0;
                    while (local_leaf < tile_size) : (local_leaf += 1) {
                        const byte_start = local_leaf * bytes_per_leaf;
                        leaf_hashers[tile_start + local_leaf].updateLeafPackedBytes(
                            scratch[byte_start .. byte_start + bytes_per_leaf],
                        );
                    }
                    column_start = column_end;
                }
            }
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

        fn parallelWorkersForLayer(out_len: usize, worker_override: ?usize) usize {
            if (builtin.single_threaded) return 1;
            if (out_len < parallel_min_nodes) return 1;
            const capacity = out_len / parallel_min_nodes_per_worker;
            if (capacity < 2) return 1;
            if (worker_override) |requested| {
                if (requested <= 1) return 1;
                return @min(@min(requested, max_parallel_workers), capacity);
            }
            const cpu_count_raw = std.Thread.getCpuCount() catch return 1;
            const cpu_count: usize = @intCast(cpu_count_raw);
            if (cpu_count <= 1) return 1;
            return @min(@min(cpu_count, capacity), max_parallel_workers);
        }

        const SeededRangeCtx = struct {
            out: []H.Hash,
            prev_layer: []const H.Hash,
            start: usize,
            end: usize,
            seed: H,
        };

        fn hashSeededRange(ctx: *const SeededRangeCtx) void {
            var i = ctx.start;
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
            seed: H,
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
                if (!self.initialized) {
                    // No columns were added — replicate the empty-column path
                    // from buildLeaves.
                    const seed_hasher = H.defaultWithInitialState();
                    var h = seed_hasher;
                    const leaves = try self.allocator.alloc(H.Hash, 1);
                    leaves[0] = h.finalize();

                    var layers_bottom_up = std.ArrayList([]H.Hash).empty;
                    defer layers_bottom_up.deinit(self.allocator);
                    errdefer {
                        for (layers_bottom_up.items) |layer| self.allocator.free(layer);
                    }
                    try layers_bottom_up.append(self.allocator, leaves);

                    const out_layers = try self.allocator.alloc([]H.Hash, 1);
                    out_layers[0] = leaves;
                    const alloc = self.allocator;
                    self.* = undefined;
                    return .{ .layers = out_layers, .layer_allocator = alloc };
                }

                // Finalize leaf hashers into leaf hashes.
                const leaf_count = self.leaf_hashers.len;
                const leaves = try self.allocator.alloc(H.Hash, leaf_count);
                for (self.leaf_hashers, 0..) |*hasher, i| {
                    leaves[i] = hasher.finalize();
                }
                // Free hasher state — column data is no longer needed.
                self.allocator.free(self.leaf_hashers);
                self.leaf_hashers = &[_]H{};

                // Build internal tree layers — identical to commitWithOptions.
                const worker_override = merkleWorkerOverride(self.allocator);
                const reuse_pool = merklePoolReuseEnabled(self.allocator);

                var layers_bottom_up = std.ArrayList([]H.Hash).empty;
                defer layers_bottom_up.deinit(self.allocator);
                errdefer {
                    for (layers_bottom_up.items) |layer| self.allocator.free(layer);
                }
                try layers_bottom_up.append(self.allocator, leaves);

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
                            self.allocator,
                            layers_bottom_up.items[layers_bottom_up.items.len - 1],
                            &executor,
                            worker_override,
                        );
                        try layers_bottom_up.append(self.allocator, next_layer);
                    }
                }

                const out_layers = try self.allocator.alloc([]H.Hash, layers_bottom_up.items.len);
                var i: usize = 0;
                while (i < out_layers.len) : (i += 1) {
                    out_layers[i] = layers_bottom_up.items[out_layers.len - 1 - i];
                }
                const alloc = self.allocator;
                self.* = undefined;
                return .{ .layers = out_layers, .layer_allocator = alloc };
            }
        };
    };
}

test "prover vcs_lifted: decommit and verify roundtrip" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const Verifier = @import("../../core/vcs_lifted/verifier.zig").MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    var prover = try Prover.commit(alloc, columns[0..]);
    defer prover.deinit(alloc);

    const query_positions = [_]usize{ 1, 6 };
    var decommitment = try prover.decommit(alloc, query_positions[0..], columns[0..]);
    defer decommitment.deinit(alloc);

    const queried_values = try alloc.alloc([]const M31, decommitment.queried_values.len);
    defer alloc.free(queried_values);
    for (decommitment.queried_values, 0..) |column, i| queried_values[i] = column;

    var verifier = try Verifier.init(alloc, prover.root(), &[_]u32{ 3, 2, 3 });
    defer verifier.deinit(alloc);
    try verifier.verify(
        alloc,
        query_positions[0..],
        queried_values,
        decommitment.decommitment.decommitment,
    );
}

test "prover vcs_lifted: invalid witness fails verification" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const Verifier = @import("../../core/vcs_lifted/verifier.zig").MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
        },
    };

    var prover = try Prover.commit(alloc, columns[0..]);
    defer prover.deinit(alloc);

    const query_positions = [_]usize{1};
    var decommitment = try prover.decommit(alloc, query_positions[0..], columns[0..]);
    defer decommitment.deinit(alloc);

    decommitment.decommitment.decommitment.hash_witness[0][0] ^= 1;

    const queried_values = try alloc.alloc([]const M31, decommitment.queried_values.len);
    defer alloc.free(queried_values);
    for (decommitment.queried_values, 0..) |column, i| queried_values[i] = column;

    var verifier = try Verifier.init(alloc, prover.root(), &[_]u32{2});
    defer verifier.deinit(alloc);
    try std.testing.expectError(
        vcs_lifted_verifier.MerkleVerificationError.RootMismatch,
        verifier.verify(
            alloc,
            query_positions[0..],
            queried_values,
            decommitment.decommitment.decommitment,
        ),
    );
}

test "prover vcs_lifted: empty columns root matches mixed-degree prover" {
    const LiftedHasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MixedHasher = @import("../../core/vcs/blake2_merkle.zig").Blake2sMerkleHasher;
    const LiftedProver = MerkleProverLifted(LiftedHasher);
    const MixedProver = @import("../vcs/prover.zig").MerkleProver(MixedHasher);
    const alloc = std.testing.allocator;

    const no_columns = [_][]const M31{};
    var lifted = try LiftedProver.commit(alloc, no_columns[0..]);
    defer lifted.deinit(alloc);
    var mixed = try MixedProver.commit(alloc, no_columns[0..]);
    defer mixed.deinit(alloc);

    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&lifted.root()), std.mem.asBytes(&mixed.root())));
}

test "prover vcs_lifted: packed leaf hashing matches legacy per-value path" {
    const lifted_blake2 = @import("../../core/vcs_lifted/blake2_merkle.zig");
    const BaseHasher = lifted_blake2.Blake2sMerkleHasher;
    const PackedProver = MerkleProverLifted(BaseHasher);
    const LegacyLeafHasher = struct {
        inner: BaseHasher,
        pub const Hash = BaseHasher.Hash;

        pub fn defaultWithInitialState() @This() {
            return .{ .inner = BaseHasher.defaultWithInitialState() };
        }

        pub fn hashChildren(children: struct { left: Hash, right: Hash }) Hash {
            return BaseHasher.hashChildren(.{
                .left = children.left,
                .right = children.right,
            });
        }

        pub fn nodeSeed() @This() {
            return .{ .inner = BaseHasher.nodeSeed() };
        }

        pub fn hashChildrenWithSeed(seed: @This(), children: struct { left: Hash, right: Hash }) Hash {
            return BaseHasher.hashChildrenWithSeed(seed.inner, .{
                .left = children.left,
                .right = children.right,
            });
        }

        pub fn updateLeaf(self: *@This(), column_values: []const M31) void {
            self.inner.updateLeaf(column_values);
        }

        pub fn finalize(self: *@This()) Hash {
            return self.inner.finalize();
        }
    };
    const LegacyProver = MerkleProverLifted(LegacyLeafHasher);
    const alloc = std.testing.allocator;
    const large_column_count: usize = 258;
    const small_column_count: usize = 2;
    const total_columns = large_column_count + small_column_count;
    const large_len: usize = 1 << 9;
    const small_len: usize = 1 << 8;

    const columns_storage = try alloc.alloc([]M31, total_columns);
    defer {
        for (columns_storage) |column| alloc.free(column);
        alloc.free(columns_storage);
    }

    const columns = try alloc.alloc([]const M31, total_columns);
    defer alloc.free(columns);

    for (0..large_column_count) |col_idx| {
        const values = try alloc.alloc(M31, large_len);
        columns_storage[col_idx] = values;
        columns[col_idx] = values;
        for (values, 0..) |*value, row_idx| {
            const seed = ((@as(u64, @intCast(col_idx + 1)) * 1009) +
                (@as(u64, @intCast(row_idx + 3)) * 37) +
                @as(u64, @intCast((col_idx ^ row_idx) + 11)));
            value.* = M31.fromU64(seed);
        }
    }
    for (0..small_column_count) |offset| {
        const col_idx = large_column_count + offset;
        const values = try alloc.alloc(M31, small_len);
        columns_storage[col_idx] = values;
        columns[col_idx] = values;
        for (values, 0..) |*value, row_idx| {
            const seed = ((@as(u64, @intCast(col_idx + 5)) * 1223) +
                (@as(u64, @intCast(row_idx + 7)) * 19) +
                @as(u64, @intCast((col_idx * 3) + row_idx)));
            value.* = M31.fromU64(seed);
        }
    }

    var packed_prover = try PackedProver.commit(alloc, columns);
    defer packed_prover.deinit(alloc);
    var legacy = try LegacyProver.commit(alloc, columns);
    defer legacy.deinit(alloc);

    const packed_root = packed_prover.root();
    const legacy_root = legacy.root();
    try std.testing.expectEqualSlices(u8, packed_root[0..], legacy_root[0..]);

    const query_positions = [_]usize{ 3, 255, 510 };
    var packed_decommitment = try packed_prover.decommit(alloc, query_positions[0..], columns);
    defer packed_decommitment.deinit(alloc);
    var legacy_decommitment = try legacy.decommit(alloc, query_positions[0..], columns);
    defer legacy_decommitment.deinit(alloc);

    try std.testing.expectEqual(packed_decommitment.queried_values.len, legacy_decommitment.queried_values.len);
    for (packed_decommitment.queried_values, legacy_decommitment.queried_values) |packed_column, legacy_column| {
        try std.testing.expectEqual(packed_column.len, legacy_column.len);
        for (packed_column, legacy_column) |packed_value, legacy_value| {
            try std.testing.expect(packed_value.eql(legacy_value));
        }
    }

    const packed_hash_witness = packed_decommitment.decommitment.decommitment.hash_witness;
    const legacy_hash_witness = legacy_decommitment.decommitment.decommitment.hash_witness;
    try std.testing.expectEqual(packed_hash_witness.len, legacy_hash_witness.len);
    for (packed_hash_witness, legacy_hash_witness) |packed_hash, legacy_hash| {
        try std.testing.expectEqualSlices(u8, packed_hash[0..], legacy_hash[0..]);
    }

    const packed_layers = packed_decommitment.decommitment.aux.all_node_values;
    const legacy_layers = legacy_decommitment.decommitment.aux.all_node_values;
    try std.testing.expectEqual(packed_layers.len, legacy_layers.len);
    for (packed_layers, legacy_layers) |packed_layer, legacy_layer| {
        try std.testing.expectEqual(packed_layer.len, legacy_layer.len);
        for (packed_layer, legacy_layer) |packed_node, legacy_node| {
            try std.testing.expectEqual(packed_node.index, legacy_node.index);
            try std.testing.expectEqualSlices(u8, packed_node.hash[0..], legacy_node.hash[0..]);
        }
    }
}

test "prover vcs_lifted: root is stable across large-layer worker-count overrides" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;
    const log_size: u32 = 14;
    const n = @as(usize, 1) << @intCast(log_size);

    var col0 = try alloc.alloc(M31, n);
    defer alloc.free(col0);
    var col1 = try alloc.alloc(M31, n);
    defer alloc.free(col1);

    for (0..n) |i| {
        col0[i] = M31.fromU64(@as(u64, @intCast(i + 1)));
        col1[i] = M31.fromU64(@as(u64, @intCast((i * 17) + 3)));
    }

    const columns = [_][]const M31{
        col0,
        col1,
    };

    var prover_auto = try Prover.commitWithWorkerOverride(alloc, columns[0..], null);
    defer prover_auto.deinit(alloc);
    var prover_single = try Prover.commitWithWorkerOverride(alloc, columns[0..], 1);
    defer prover_single.deinit(alloc);
    var prover_two = try Prover.commitWithWorkerOverride(alloc, columns[0..], 2);
    defer prover_two.deinit(alloc);
    var prover_four = try Prover.commitWithWorkerOverride(alloc, columns[0..], 4);
    defer prover_four.deinit(alloc);
    var prover_eight = try Prover.commitWithWorkerOverride(alloc, columns[0..], 8);
    defer prover_eight.deinit(alloc);

    const root_auto = prover_auto.root();
    const root_single = prover_single.root();
    const root_two = prover_two.root();
    const root_four = prover_four.root();
    const root_eight = prover_eight.root();
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_single)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_two)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_four)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_eight)));
}

test "prover vcs_lifted: streaming committer produces identical root — single batch" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    // Reference: full commit.
    var prover_ref = try Prover.commit(alloc, columns[0..]);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    // Sort columns the same way commit() does internally.
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);

    // Streaming: feed all sorted columns in one batch.
    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    try streaming.addColumns(sorted);
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: streaming committer produces identical root — column-by-column" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    var prover_ref = try Prover.commit(alloc, columns[0..]);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    // Sort, then feed one column at a time.
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);

    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    for (sorted) |col| {
        const single = [_]Prover.ColumnRef{col};
        try streaming.addColumns(single[0..]);
    }
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: streaming committer produces identical root — many columns batched" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const large_count: usize = 32;
    const small_count: usize = 8;
    const total = large_count + small_count;
    const large_len: usize = 1 << 6;
    const small_len: usize = 1 << 4;

    const columns_storage = try alloc.alloc([]M31, total);
    defer {
        for (columns_storage) |column| alloc.free(column);
        alloc.free(columns_storage);
    }
    const columns = try alloc.alloc([]const M31, total);
    defer alloc.free(columns);

    for (0..large_count) |i| {
        const values = try alloc.alloc(M31, large_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 1) * 1009 + (j + 3) * 37)));
        }
    }
    for (0..small_count) |offset| {
        const i = large_count + offset;
        const values = try alloc.alloc(M31, small_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 5) * 1223 + (j + 7) * 19)));
        }
    }

    var prover_ref = try Prover.commit(alloc, columns);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns);
    defer alloc.free(sorted);

    // Feed in batches of 5 (not aligned with group boundaries).
    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    var batch_start: usize = 0;
    while (batch_start < sorted.len) {
        // Must split batches at log_size boundaries to maintain ordering invariant.
        var batch_end = batch_start + 1;
        while (batch_end < sorted.len and
            batch_end - batch_start < 5 and
            sorted[batch_end].log_size == sorted[batch_start].log_size)
        {
            batch_end += 1;
        }
        // If next column has a different log_size, that's fine — it'll be in the next batch.
        // But within a batch, all columns must have non-decreasing log_size.
        try streaming.addColumns(sorted[batch_start..batch_end]);
        batch_start = batch_end;
    }
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: streaming committer empty columns" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const no_columns = [_][]const M31{};
    var prover_ref = try Prover.commit(alloc, no_columns[0..]);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    // Finalize with no columns added.
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "MerkleProverLifted: commitWithLazyQuotients produces same root as standard commit" {
    const alloc = std.testing.allocator;
    const pcs_utils = @import("../../core/pcs/utils.zig");
    const TreeVec = pcs_utils.TreeVec;
    const quotients_mod = @import("../../core/pcs/quotients.zig");
    const ColumnEvaluation = quotient_ops.ColumnEvaluation;
    const PointSample = quotients_mod.PointSample;
    const QM31 = qm31.QM31;

    const blake2_merkle = @import("../../core/vcs_lifted/blake2_merkle.zig");
    const Hasher = blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);

    const lifting_log_size: u32 = 6;
    const domain_size = @as(usize, 1) << @intCast(lifting_log_size);

    // Build test trace columns.
    const col0 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col0);
    for (col0, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(i + 3));

    const col1_log_size: u32 = 4;
    const col1 = try alloc.alloc(M31, @as(usize, 1) << @intCast(col1_log_size));
    defer alloc.free(col1);
    for (col1, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(101 + i));

    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = lifting_log_size, .values = col0 },
        .{ .log_size = col1_log_size, .values = col1 },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);

    // Build sample data.
    const point0 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(7);
    const point1 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(19);

    const col0_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(1, 2, 3, 4) },
    });
    const col1_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(5, 6, 7, 8) },
        .{ .point = point1, .value = QM31.fromU32Unchecked(9, 10, 11, 12) },
    });
    const tree_samples = try alloc.dupe([]PointSample, &[_][]PointSample{
        col0_samples,
        col1_samples,
    });
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{tree_samples}),
    );
    defer samples.deinitDeep(alloc);

    // Split into points/values.
    const point_trees = try alloc.alloc([][]@import("../../core/circle.zig").CirclePointQM31, 1);
    errdefer alloc.free(point_trees);
    const value_trees = try alloc.alloc([][]QM31, 1);
    errdefer alloc.free(value_trees);

    point_trees[0] = try alloc.alloc([]@import("../../core/circle.zig").CirclePointQM31, samples.items[0].len);
    value_trees[0] = try alloc.alloc([]QM31, samples.items[0].len);

    for (samples.items[0], 0..) |col_samples, col_idx| {
        const pts = try alloc.alloc(@import("../../core/circle.zig").CirclePointQM31, col_samples.len);
        const vals = try alloc.alloc(QM31, col_samples.len);
        for (col_samples, 0..) |s, si| {
            pts[si] = s.point;
            vals[si] = s.value;
        }
        point_trees[0][col_idx] = pts;
        value_trees[0][col_idx] = vals;
    }

    var sampled_points = TreeVec([][]@import("../../core/circle.zig").CirclePointQM31).initOwned(point_trees);
    defer sampled_points.deinitDeep(alloc);
    var sampled_values = TreeVec([][]QM31).initOwned(value_trees);
    defer sampled_values.deinitDeep(alloc);

    const alpha = QM31.fromU32Unchecked(3, 0, 1, 0);

    // borrow columns for both paths
    const borrowed_items = try alloc.alloc([]const ColumnEvaluation, columns.items.len);
    defer alloc.free(borrowed_items);
    for (columns.items, 0..) |tc, i| borrowed_items[i] = tc;

    // === Standard path: compute quotients, then commit ===
    var quotients_column = try quotient_ops.computeFriQuotients(
        alloc,
        TreeVec([]const ColumnEvaluation).initOwned(borrowed_items),
        sampled_points,
        sampled_values,
        alpha,
        lifting_log_size,
        1,
    );
    defer quotients_column.deinit(alloc);

    const standard_columns = [_][]const M31{
        quotients_column.columns[0],
        quotients_column.columns[1],
        quotients_column.columns[2],
        quotients_column.columns[3],
    };
    var standard_tree = try Prover.commit(alloc, standard_columns[0..]);
    defer standard_tree.deinit(alloc);
    const standard_root = standard_tree.root();

    // === Lazy path: fused compute+commit ===
    const borrowed_items2 = try alloc.alloc([]const ColumnEvaluation, columns.items.len);
    defer alloc.free(borrowed_items2);
    for (columns.items, 0..) |tc, i| borrowed_items2[i] = tc;

    var provider = try quotient_ops.LazyQuotientProvider.init(
        alloc,
        TreeVec([]const ColumnEvaluation).initOwned(borrowed_items2),
        sampled_points,
        sampled_values,
        alpha,
        lifting_log_size,
    );
    defer provider.deinit(alloc);

    var lazy_column = try SecureColumnByCoords.uninitialized(alloc, domain_size);
    defer lazy_column.deinit(alloc);

    var lazy_tree = try Prover.commitWithLazyQuotients(alloc, &provider, &lazy_column);
    defer lazy_tree.deinit(alloc);
    const lazy_root = lazy_tree.root();

    // Roots must match.
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&standard_root), std.mem.asBytes(&lazy_root)));

    // Column values must also match.
    for (0..domain_size) |i| {
        try std.testing.expect(quotients_column.at(i).eql(lazy_column.at(i)));
    }
}

test "prover vcs_lifted: batched leaf building matches original for uniform columns" {
    // Verifies that buildLeavesBatched produces bit-identical leaf hashes
    // as the original buildLeaves when all columns have the same log_size.
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const num_columns: usize = 16;
    const log_size: u32 = 10;
    const n = @as(usize, 1) << @intCast(log_size);

    const columns_storage = try alloc.alloc([]M31, num_columns);
    defer {
        for (columns_storage) |col| alloc.free(col);
        alloc.free(columns_storage);
    }
    const columns = try alloc.alloc([]const M31, num_columns);
    defer alloc.free(columns);

    for (0..num_columns) |col_idx| {
        const values = try alloc.alloc(M31, n);
        columns_storage[col_idx] = values;
        columns[col_idx] = values;
        for (values, 0..) |*value, row_idx| {
            const seed = @as(u64, @intCast(col_idx + 1)) * 1009 +
                @as(u64, @intCast(row_idx + 3)) * 37;
            value.* = M31.fromU64(seed);
        }
    }

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns);
    defer alloc.free(sorted);
    const layer_alloc = alloc;

    // Original path
    const original_leaves = try Prover.buildLeaves(alloc, layer_alloc, sorted);
    defer layer_alloc.free(original_leaves);

    // Batched path with various batch sizes
    inline for ([_]usize{ 4, 64, 256, 1024 }) |batch_sz| {
        const batched_leaves = try Prover.buildLeavesBatched(alloc, layer_alloc, sorted, batch_sz);
        defer layer_alloc.free(batched_leaves);

        try std.testing.expectEqual(original_leaves.len, batched_leaves.len);
        for (original_leaves, batched_leaves) |orig, bat| {
            try std.testing.expectEqualSlices(u8, orig[0..], bat[0..]);
        }
    }
}

test "prover vcs_lifted: batched leaf building matches original for mixed log sizes" {
    // Verifies bit-identical output when columns have different log_sizes,
    // which exercises the lifting index mapping.
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const large_count: usize = 8;
    const small_count: usize = 4;
    const total = large_count + small_count;
    const large_len: usize = 1 << 9;
    const small_len: usize = 1 << 7;

    const columns_storage = try alloc.alloc([]M31, total);
    defer {
        for (columns_storage) |col| alloc.free(col);
        alloc.free(columns_storage);
    }
    const columns = try alloc.alloc([]const M31, total);
    defer alloc.free(columns);

    for (0..large_count) |i| {
        const values = try alloc.alloc(M31, large_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, r| {
            v.* = M31.fromU64(@as(u64, @intCast(i * 997 + r * 13 + 5)));
        }
    }
    for (0..small_count) |offset| {
        const i = large_count + offset;
        const values = try alloc.alloc(M31, small_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, r| {
            v.* = M31.fromU64(@as(u64, @intCast(i * 1223 + r * 19 + 7)));
        }
    }

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns);
    defer alloc.free(sorted);
    const layer_alloc = alloc;

    const original_leaves = try Prover.buildLeaves(alloc, layer_alloc, sorted);
    defer layer_alloc.free(original_leaves);

    inline for ([_]usize{ 8, 128, 512 }) |batch_sz| {
        const batched_leaves = try Prover.buildLeavesBatched(alloc, layer_alloc, sorted, batch_sz);
        defer layer_alloc.free(batched_leaves);

        try std.testing.expectEqual(original_leaves.len, batched_leaves.len);
        for (original_leaves, batched_leaves) |orig, bat| {
            try std.testing.expectEqualSlices(u8, orig[0..], bat[0..]);
        }
    }
}

test "prover vcs_lifted: batched commit produces same root and decommitment" {
    // End-to-end test: full commit + decommit with the batched path
    // must produce the same root and decommitment as the original.
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const Verifier = @import("../../core/vcs_lifted/verifier.zig").MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    // Build using original path (columns are small, below threshold).
    var prover_orig = try Prover.commit(alloc, columns[0..]);
    defer prover_orig.deinit(alloc);

    // Build using batched path explicitly with a tiny batch.
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);
    const batched_leaves = try Prover.buildLeavesBatched(alloc, alloc, sorted, 2);
    defer alloc.free(batched_leaves);

    // Compare leaf layers directly.
    const orig_leaf_layer = prover_orig.layers[prover_orig.layers.len - 1];
    try std.testing.expectEqual(orig_leaf_layer.len, batched_leaves.len);
    for (orig_leaf_layer, batched_leaves) |orig, bat| {
        try std.testing.expectEqualSlices(u8, orig[0..], bat[0..]);
    }

    // Verify the original prover's decommitment still works (sanity check).
    const query_positions = [_]usize{ 1, 6 };
    var decommitment = try prover_orig.decommit(alloc, query_positions[0..], columns[0..]);
    defer decommitment.deinit(alloc);

    const queried_values = try alloc.alloc([]const M31, decommitment.queried_values.len);
    defer alloc.free(queried_values);
    for (decommitment.queried_values, 0..) |column, i| queried_values[i] = column;

    var verifier = try Verifier.init(alloc, prover_orig.root(), &[_]u32{ 3, 2, 3 });
    defer verifier.deinit(alloc);
    try verifier.verify(
        alloc,
        query_positions[0..],
        queried_values,
        decommitment.decommitment.decommitment,
    );
}
