const std = @import("std");
const M31 = @import("../../core/fields/m31.zig").M31;
const QM31 = @import("../../core/fields/qm31.zig").QM31;
const canonic = @import("../../core/poly/circle/canonic.zig");
const core_utils = @import("../../core/utils.zig");
const circle_poly = @import("../../prover/poly/circle/poly.zig");
const twiddles_mod = @import("../../prover/poly/twiddles.zig");
const arena_plan = @import("arena_plan.zig");
const recovery = @import("recovery.zig");
const runtime = @import("runtime.zig");
const blake2s_channel = @import("../../core/channel/blake2s.zig");
const blake2_hash = @import("../../core/vcs/blake2_hash.zig");
const fri_geometry = @import("../../core/fri/geometry.zig");
const cairo_merkle = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sPlainMerkleHasher;
const aot_witness = @import("recipes/aot_witness.zig");
const circle_recipes = @import("recipes/circle.zig");
const compact = @import("recipes/compact.zig");
const composition = @import("recipes/composition.zig");
const ec_op = @import("recipes/ec_op.zig");
const fixed_tables = @import("recipes/fixed_tables.zig");
const merkle_recipes = @import("recipes/merkle.zig");
const proof_assembly = @import("recipes/proof_assembly.zig");
const relation = @import("recipes/relation.zig");
const witness_feed = @import("recipes/witness_feed.zig");

const cairo_domain_prefix_bytes = cairo_merkle.domainPrefixBytes();

pub const FriGeometry = fri_geometry.FriGeometry;
pub const AotWitnessInvocation = aot_witness.Invocation;
pub const AotWorkspaceWrite = aot_witness.WorkspaceWrite;
pub const AotWitnessBatchRecipe = aot_witness.BatchRecipe;
pub const CircleTransformRecipe = circle_recipes.TransformRecipe;
pub const CircleLdeRecipe = circle_recipes.LdeRecipe;
pub const CircleIfftRecipe = circle_recipes.IfftRecipe;
pub const CompactBindings = compact.Bindings;
pub const CompactRecipe = compact.Recipe;
pub const CompositionFinalizeRecipe = composition.FinalizeRecipe;
pub const CompositionRecipe = composition.Recipe;
pub const EcOpBindings = ec_op.Bindings;
pub const EcOpOutputMode = ec_op.OutputMode;
pub const EcOpRecipe = ec_op.Recipe;
pub const FixedTableBindings = fixed_tables.Bindings;
pub const FixedTableBatchRecipe = fixed_tables.BatchRecipe;
pub const MerkleParentChainRecipe = merkle_recipes.ParentChainRecipe;
pub const MerkleCommitRecipe = merkle_recipes.CommitRecipe;
pub const ProofCopy = proof_assembly.ProofCopy;
pub const ProofAssemblyRecipe = proof_assembly.ProofAssemblyRecipe;
pub const RelationInstanceBindings = relation.RelationInstanceBindings;
pub const RelationRecipe = relation.RelationRecipe;
pub const DestinationColumns = witness_feed.DestinationColumns;
pub const BoundWitnessFeed = witness_feed.BoundWitnessFeed;
pub const WitnessFeedRecipe = witness_feed.WitnessFeedRecipe;
pub const WitnessFeedBatchEntry = witness_feed.WitnessFeedBatchEntry;
pub const WitnessFeedBatchRecipe = witness_feed.WitnessFeedBatchRecipe;

pub const CopyRecipe = struct {
    access: recovery.BufferAccess,
    source: arena_plan.Binding,

    pub fn recipe(self: *CopyRecipe, logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        const self: *CopyRecipe = @ptrCast(@alignCast(raw));
        const source = try self.access.bytes(self.source);
        if (source.len != destination.len) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(destination, source);
    }
};

/// Restores deterministic adapter/witness seeds from compact host ownership.
/// This is recomputation input, not a second Metal allocation.
pub const HostCopyRecipe = struct {
    source: []const u8,

    pub fn recipe(self: *HostCopyRecipe, logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        const self: *HostCopyRecipe = @ptrCast(@alignCast(raw));
        if (self.source.len != destination.len) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(destination, self.source);
    }
};

pub const ZeroRecipe = struct {
    pub fn recipe(logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = undefined, .run = run };
    }

    fn run(_: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        @memset(destination, 0);
    }
};

/// One circle-to-line or line-to-line FRI fold with every operand resident in
/// the shared arena. The challenge and inverse-coordinate column are bindings,
/// so replay never uploads control data or reads the folded column back.
pub const FriFoldRecipe = struct {
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    prepared: runtime.FriFoldPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        source: arena_plan.Binding,
        inverse_coordinates: arena_plan.Binding,
        challenge: arena_plan.Binding,
        destination: arena_plan.Binding,
        source_count: u32,
        circle: bool,
    ) !FriFoldRecipe {
        const destination_count = source_count / 2;
        if (source_count < 2 or source_count & 1 != 0 or
            source.offset_bytes % 4 != 0 or inverse_coordinates.offset_bytes % 4 != 0 or
            challenge.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or
            source.size_bytes < @as(u64, source_count) * 16 or
            inverse_coordinates.size_bytes < @as(u64, destination_count) * 4 or
            challenge.size_bytes < 16 or destination.size_bytes < @as(u64, destination_count) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .metal = metal,
            .arena = resident_arena,
            .destination = destination,
            .prepared = try metal.prepareFriFold(
                std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, inverse_coordinates.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, challenge.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                source_count,
                circle,
            ),
        };
    }

    pub fn deinit(self: *FriFoldRecipe) void {
        self.prepared.deinit();
        self.* = undefined;
    }

    pub fn recipe(self: *FriFoldRecipe) recovery.Recipe {
        return .{ .logical_id = self.destination.logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *FriFoldRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        self.accumulated_gpu_ms += try self.metal.friFoldPrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

/// Prepared quotient bottom: combine mixed-log secure numerators on the
/// quotient subdomain, interpolate its four coordinates in place, then LDE
/// directly into the full-domain planar buffer consumed by FRI.
pub const QuotientRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    partials: []arena_plan.Binding,
    sample_points: arena_plan.Binding,
    first_linear_terms: arena_plan.Binding,
    subdomain_values: arena_plan.Binding,
    inverse_subdomain_twiddles: arena_plan.Binding,
    subdomain_log: u32,
    quotient_log: u32,
    combine: runtime.QuotientCombinePlan,
    interpolate: runtime.CircleIfftPlan,
    evaluate: runtime.CircleLdePlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        partials_source_major: []const arena_plan.Binding,
        sample_points: arena_plan.Binding,
        first_linear_terms: arena_plan.Binding,
        denominator_scratch: arena_plan.Binding,
        subdomain_values: arena_plan.Binding,
        quotient_values: arena_plan.Binding,
        inverse_subdomain_twiddles: arena_plan.Binding,
        forward_twiddles: arena_plan.Binding,
    ) !QuotientRecipe {
        if (partials_source_major.len == 0 or partials_source_major.len % 4 != 0 or
            sample_points.offset_bytes % 4 != 0 or first_linear_terms.offset_bytes % 4 != 0 or
            denominator_scratch.offset_bytes % 4 != 0 or subdomain_values.offset_bytes % 4 != 0 or
            quotient_values.offset_bytes % 4 != 0 or inverse_subdomain_twiddles.offset_bytes % 4 != 0 or
            forward_twiddles.offset_bytes % 4 != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const sample_count = partials_source_major.len / 4;
        if (sample_points.size_bytes != @as(u64, sample_count) * 8 * 4 or
            first_linear_terms.size_bytes != @as(u64, sample_count) * 4 * 4 or
            subdomain_values.size_bytes % 16 != 0 or quotient_values.size_bytes % 16 != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const subdomain_rows = subdomain_values.size_bytes / 16;
        const quotient_rows = quotient_values.size_bytes / 16;
        if (!std.math.isPowerOfTwo(subdomain_rows) or !std.math.isPowerOfTwo(quotient_rows) or quotient_rows <= subdomain_rows)
            return recovery.RecoveryError.BindingSizeMismatch;
        const subdomain_log: u32 = std.math.log2_int(u64, subdomain_rows);
        const quotient_log: u32 = std.math.log2_int(u64, quotient_rows);
        if (denominator_scratch.size_bytes != subdomain_rows * sample_count * 8 or
            inverse_subdomain_twiddles.size_bytes < subdomain_rows / 2 * 4 or
            forward_twiddles.size_bytes < quotient_rows / 2 * 4)
            return recovery.RecoveryError.BindingSizeMismatch;

        const offsets = try allocator.alloc(u32, partials_source_major.len);
        defer allocator.free(offsets);
        const logs = try allocator.alloc(u32, sample_count);
        defer allocator.free(logs);
        for (0..sample_count) |source| {
            const first = partials_source_major[source * 4];
            if (first.size_bytes < 4 or first.size_bytes % 4 != 0 or !std.math.isPowerOfTwo(first.size_bytes / 4))
                return recovery.RecoveryError.BindingSizeMismatch;
            logs[source] = std.math.log2_int(u64, first.size_bytes / 4);
            if (logs[source] > subdomain_log) return recovery.RecoveryError.BindingSizeMismatch;
            for (0..4) |coordinate| {
                const partial = partials_source_major[source * 4 + coordinate];
                if (partial.size_bytes != first.size_bytes or partial.offset_bytes % 4 != 0)
                    return recovery.RecoveryError.BindingSizeMismatch;
                offsets[coordinate * sample_count + source] = std.math.cast(u32, partial.offset_bytes / 4) orelse
                    return recovery.RecoveryError.BindingSizeMismatch;
            }
        }
        const subdomain_offset = std.math.cast(u32, subdomain_values.offset_bytes / 4) orelse
            return recovery.RecoveryError.BindingSizeMismatch;
        const quotient_offset = quotient_values.offset_bytes / 4;
        const initial_index = @as(u32, 1) << @intCast(30 - quotient_log);
        const step_size = @as(u32, 1) << @intCast(32 - subdomain_log);
        var combine = try metal.prepareQuotientCombine(
            offsets,
            logs,
            std.math.cast(u32, sample_points.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, first_linear_terms.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, denominator_scratch.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            subdomain_offset,
            subdomain_log,
            initial_index,
            step_size,
        );
        errdefer combine.deinit();
        var subdomain_offsets: [4]u64 = undefined;
        var quotient_offsets: [4]u64 = undefined;
        for (0..4) |coordinate| {
            subdomain_offsets[coordinate] = subdomain_offset + @as(u64, @intCast(coordinate)) * subdomain_rows;
            quotient_offsets[coordinate] = quotient_offset + @as(u64, @intCast(coordinate)) * quotient_rows;
        }
        const scale = @import("../../core/fields/m31.zig").M31.fromCanonical(@intCast(subdomain_rows)).inv() catch
            return recovery.RecoveryError.BindingSizeMismatch;
        var interpolate = try metal.prepareCircleIfft(
            &subdomain_offsets,
            &subdomain_offsets,
            subdomain_log,
            std.math.cast(u32, inverse_subdomain_twiddles.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            scale.v,
        );
        errdefer interpolate.deinit();
        const forward_words = forward_twiddles.size_bytes / 4;
        const quotient_twiddle_words = quotient_rows / 2;
        const forward_twiddle_offset = std.math.add(
            u64,
            forward_twiddles.offset_bytes / 4,
            forward_words - quotient_twiddle_words,
        ) catch return recovery.RecoveryError.BindingSizeMismatch;
        var evaluate = try metal.prepareCircleLde(
            &subdomain_offsets,
            &quotient_offsets,
            subdomain_log,
            quotient_log,
            std.math.cast(u32, forward_twiddle_offset) orelse return recovery.RecoveryError.BindingSizeMismatch,
        );
        errdefer evaluate.deinit();
        const owned_partials = try allocator.dupe(arena_plan.Binding, partials_source_major);
        errdefer allocator.free(owned_partials);
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destination = quotient_values,
            .partials = owned_partials,
            .sample_points = sample_points,
            .first_linear_terms = first_linear_terms,
            .subdomain_values = subdomain_values,
            .inverse_subdomain_twiddles = inverse_subdomain_twiddles,
            .subdomain_log = subdomain_log,
            .quotient_log = quotient_log,
            .combine = combine,
            .interpolate = interpolate,
            .evaluate = evaluate,
        };
    }

    pub fn deinit(self: *QuotientRecipe) void {
        self.evaluate.deinit();
        self.interpolate.deinit();
        self.combine.deinit();
        self.allocator.free(self.partials);
        self.* = undefined;
    }

    pub fn recipe(self: *QuotientRecipe) recovery.Recipe {
        return .{ .logical_id = self.destination.logical_id, .context = self, .run = run };
    }

    pub fn execute(self: *QuotientRecipe) !void {
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
            try self.validateInverseTwiddles();
        self.accumulated_gpu_ms += try self.metal.quotientCombinePrepared(self.arena.buffer, self.combine);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
            try self.validateCombineSamples();
            self.logDigest("combine", self.subdomain_values) catch {};
        }
        self.accumulated_gpu_ms += try self.metal.circleIfftPrepared(self.arena.buffer, self.interpolate);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
            self.logDigest("ifft", self.subdomain_values) catch {};
            try self.validateIfftAtRow(0);
        }
        self.accumulated_gpu_ms += try self.metal.circleLdePrepared(self.arena.buffer, self.evaluate);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
            self.logDigest("lde", self.destination) catch {};
            try self.validateLdeAtRow(0);
        }
    }

    fn logDigest(self: *QuotientRecipe, stage: []const u8, binding: arena_plan.Binding) !void {
        const bytes = try self.arena.bytes(binding);
        const digest = blake2_hash.Blake2sHasher.hash(bytes);
        const aligned: []align(4) const u8 = @alignCast(bytes);
        const words = std.mem.bytesAsSlice(u32, aligned);
        std.debug.print(
            "quotient stage={s} digest={x} first={},{},{},{}\n",
            .{ stage, digest, words[0], words[1], words[2], words[3] },
        );
    }

    fn validateInverseTwiddles(self: *QuotientRecipe) !void {
        const actual_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.inverse_subdomain_twiddles));
        const actual_words = std.mem.bytesAsSlice(u32, actual_bytes);
        var split = try canonic.CanonicCoset.new(self.quotient_log).circleDomain().split(
            self.allocator,
            self.quotient_log - self.subdomain_log,
        );
        defer split.deinit(self.allocator);
        var expected = try twiddles_mod.precomputeM31(self.allocator, split.subdomain.half_coset);
        defer twiddles_mod.deinitM31(self.allocator, &expected);
        if (actual_words.len != expected.itwiddles.len)
            return error.QuotientInverseTwiddleParityMismatch;
        for (actual_words, expected.itwiddles, 0..) |actual, wanted, index| {
            if (actual != wanted.v) {
                std.debug.print(
                    "quotient inverse_twiddles mismatch index={} expected={} actual={}\n",
                    .{ index, wanted.v, actual },
                );
                return error.QuotientInverseTwiddleParityMismatch;
            }
        }
        const actual_digest = blake2_hash.Blake2sHasher.hash(actual_bytes);
        const expected_digest = blake2_hash.Blake2sHasher.hash(std.mem.sliceAsBytes(expected.itwiddles));
        std.debug.print(
            "quotient inverse_twiddles exact words={} digest={x} expected_digest={x} first={},{},{},{} last={} offset_words={}\n",
            .{
                actual_words.len,
                actual_digest,
                expected_digest,
                actual_words[0],
                actual_words[1],
                actual_words[2],
                actual_words[3],
                actual_words[actual_words.len - 1],
                self.inverse_subdomain_twiddles.offset_bytes / 4,
            },
        );
    }

    fn expectedCombineAtRow(self: *QuotientRecipe, row: usize) !QM31 {
        const sample_count = self.partials.len / 4;
        const sample_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.sample_points));
        const linear_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.first_linear_terms));
        const sample_words = std.mem.bytesAsSlice(u32, sample_bytes);
        const linear_words = std.mem.bytesAsSlice(u32, linear_bytes);
        var split = try canonic.CanonicCoset.new(self.quotient_log).circleDomain().split(
            self.allocator,
            self.quotient_log - self.subdomain_log,
        );
        defer split.deinit(self.allocator);
        const point = split.subdomain.at(core_utils.bitReverseIndex(row, self.subdomain_log));
        var expected = QM31.zero();
        for (0..sample_count) |sample| {
            const sample_base = sample * 8;
            const sample_x = QM31.fromU32Unchecked(
                sample_words[sample_base],
                sample_words[sample_base + 1],
                sample_words[sample_base + 2],
                sample_words[sample_base + 3],
            );
            const sample_y = QM31.fromU32Unchecked(
                sample_words[sample_base + 4],
                sample_words[sample_base + 5],
                sample_words[sample_base + 6],
                sample_words[sample_base + 7],
            );
            const denominator = sample_x.c0.subM31(point.x).mul(sample_y.c1).sub(
                sample_y.c0.subM31(point.y).mul(sample_x.c1),
            );
            const inverse = try denominator.inv();
            const partial_log = std.math.log2_int(u64, self.partials[sample * 4].size_bytes / 4);
            const log_ratio = self.subdomain_log - partial_log;
            const lifted = (row >> @intCast(log_ratio + 1) << 1) + (row & 1);
            var partial_coordinates: [4]M31 = undefined;
            for (0..4) |coordinate| {
                const partial_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.partials[sample * 4 + coordinate]));
                const partial_words = std.mem.bytesAsSlice(u32, partial_bytes);
                partial_coordinates[coordinate] = M31.fromCanonical(partial_words[lifted]);
            }
            const linear_base = sample * 4;
            const first = QM31.fromU32Unchecked(
                linear_words[linear_base],
                linear_words[linear_base + 1],
                linear_words[linear_base + 2],
                linear_words[linear_base + 3],
            );
            expected = expected.add(
                QM31.fromM31Array(partial_coordinates).sub(first.mulM31(point.y)).mulCM31(inverse),
            );
        }
        return expected;
    }

    fn validateCombineSamples(self: *QuotientRecipe) !void {
        const output_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.subdomain_values));
        const output_words = std.mem.bytesAsSlice(u32, output_bytes);
        const row_count = @as(usize, 1) << @intCast(self.subdomain_log);
        const sample_rows = [_]usize{
            0,                 1,                 2,                 3,                 7,
            row_count / 16,    row_count / 8,     row_count / 4,     row_count / 2 - 1, row_count / 2,
            row_count / 2 + 1, 3 * row_count / 4, 7 * row_count / 8, row_count - 8,     row_count - 4,
            row_count - 2,     row_count - 1,
        };
        for (sample_rows) |row| {
            const expected = try self.expectedCombineAtRow(row);
            const actual = QM31.fromU32Unchecked(
                output_words[row],
                output_words[row_count + row],
                output_words[2 * row_count + row],
                output_words[3 * row_count + row],
            );
            if (!actual.eql(expected)) {
                std.debug.print(
                    "quotient stage=combine mismatch row={} expected={any} actual={any}\n",
                    .{ row, expected.toM31Array(), actual.toM31Array() },
                );
                return error.QuotientCombineParityMismatch;
            }
        }
        std.debug.print("quotient stage=combine cpu_samples=exact rows={}\n", .{sample_rows.len});
    }

    fn coefficientsAtPoint(self: *QuotientRecipe, point: @import("../../core/circle.zig").CirclePointM31) !QM31 {
        const coefficient_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.subdomain_values));
        const coefficient_words = std.mem.bytesAsSlice(u32, coefficient_bytes);
        const row_count = @as(usize, 1) << @intCast(self.subdomain_log);
        var partial_evals: [4]QM31 = undefined;
        for (0..4) |coordinate| {
            const words = coefficient_words[coordinate * row_count .. (coordinate + 1) * row_count];
            const coefficients = try self.allocator.alloc(M31, row_count);
            defer self.allocator.free(coefficients);
            for (words, coefficients) |word, *coefficient| coefficient.* = M31.fromCanonical(word);
            const polynomial = try circle_poly.CircleCoefficients.initBorrowed(coefficients);
            partial_evals[coordinate] = polynomial.evalAtPoint(.{
                .x = QM31.fromBase(point.x),
                .y = QM31.fromBase(point.y),
            });
        }
        return QM31.fromPartialEvals(partial_evals);
    }

    fn validateIfftAtRow(self: *QuotientRecipe, row: usize) !void {
        var split = try canonic.CanonicCoset.new(self.quotient_log).circleDomain().split(
            self.allocator,
            self.quotient_log - self.subdomain_log,
        );
        defer split.deinit(self.allocator);
        const point = split.subdomain.at(core_utils.bitReverseIndex(row, self.subdomain_log));
        const expected = try self.expectedCombineAtRow(row);
        const actual = try self.coefficientsAtPoint(point);
        if (!actual.eql(expected)) {
            std.debug.print("quotient stage=ifft mismatch row={} expected={any} actual={any}\n", .{
                row, expected.toM31Array(), actual.toM31Array(),
            });
            return error.QuotientIfftParityMismatch;
        }
        std.debug.print("quotient stage=ifft scalar_eval=exact row={}\n", .{row});
    }

    fn validateLdeAtRow(self: *QuotientRecipe, row: usize) !void {
        const point = canonic.CanonicCoset.new(self.quotient_log).circleDomain().at(
            core_utils.bitReverseIndex(row, self.quotient_log),
        );
        const expected = try self.coefficientsAtPoint(point);
        const output_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.destination));
        const output_words = std.mem.bytesAsSlice(u32, output_bytes);
        const row_count = @as(usize, 1) << @intCast(self.quotient_log);
        const actual = QM31.fromU32Unchecked(
            output_words[row],
            output_words[row_count + row],
            output_words[2 * row_count + row],
            output_words[3 * row_count + row],
        );
        if (!actual.eql(expected)) {
            std.debug.print("quotient stage=lde mismatch row={} expected={any} actual={any}\n", .{
                row, expected.toM31Array(), actual.toM31Array(),
            });
            return error.QuotientLdeParityMismatch;
        }
        std.debug.print("quotient stage=lde scalar_eval=exact row={}\n", .{row});
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *QuotientRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        try self.execute();
        self.last_tick = tick;
    }
};

fn validateFriCardinalities(
    geometry: FriGeometry,
    retained_count: usize,
    challenge_count: usize,
    merkle_layer_count: usize,
) !void {
    const round_count = std.math.add(usize, retained_count, 1) catch
        return recovery.RecoveryError.BindingSizeMismatch;
    if (round_count != geometry.roundCount() or
        challenge_count != geometry.roundCount() or
        merkle_layer_count != geometry.totalLayerCount() or
        geometry.terminalLog() != geometry.finalLog())
        return recovery.RecoveryError.BindingSizeMismatch;
}

fn validateFriOpeningRound(geometry: FriGeometry, round: usize, leaf_log: u32) !void {
    if (round >= geometry.roundCount() or leaf_log != try geometry.leafLog(round))
        return recovery.RecoveryError.BindingSizeMismatch;
}

test "Metal FRI cardinalities accept seven-round Fib and eight-round SN2 geometry" {
    const sn2 = try FriGeometry.init(24);
    try validateFriCardinalities(sn2, 7, 8, 100);
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriCardinalities(sn2, 6, 8, 100),
    );

    const fib = try FriGeometry.initRuntime(21, .{
        .round_count = 7,
        .fold_step = 3,
        .final_log = 1,
        .packed_log = 2,
    });
    try validateFriCardinalities(fib, 6, 7, 77);
    for (0..fib.roundCount()) |round| try validateFriOpeningRound(fib, round, try fib.leafLog(round));
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriCardinalities(fib, 6, 8, 77),
    );
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriCardinalities(fib, 6, 7, 78),
    );
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriOpeningRound(fib, 6, 2),
    );
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriOpeningRound(fib, 7, 0),
    );
}

/// Exact STWO FRI bottom with planar secure evaluations and four rows per leaf.
/// Transcript control calls
/// `commitTree` and `foldRound` alternately so each device root can be mixed
/// before its resident challenge is consumed.
pub const FriRecipe = struct {
    pub const FinalDegreeError = error{
        FinalDegreeNotComputed,
        FinalDegreeExceeded,
    };

    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    rounds: [FriGeometry.max_round_count]runtime.FriRoundPlan,
    trees: [FriGeometry.max_round_count]runtime.FriTreePlan,
    final: runtime.FriFinalPlan,
    roots: [FriGeometry.max_round_count]arena_plan.Binding,
    round_count: usize = FriGeometry.round_count,
    initialized_rounds: usize,
    initialized_trees: usize,
    initialized_final: bool,
    final_degree_error: arena_plan.Binding,
    finalized: bool = false,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        quotient: arena_plan.Binding,
        retained: []const arena_plan.Binding,
        challenges: []const arena_plan.Binding,
        inverse_twiddles: arena_plan.Binding,
        final_evaluation: arena_plan.Binding,
        final_coefficients: arena_plan.Binding,
        final_degree_error: arena_plan.Binding,
        merkle_layers_root_first: []const arena_plan.Binding,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !FriRecipe {
        if (quotient.offset_bytes % 4 != 0 or quotient.size_bytes < 16 or quotient.size_bytes % 16 != 0 or
            !std.math.isPowerOfTwo(quotient.size_bytes / 16))
            return recovery.RecoveryError.BindingSizeMismatch;
        const geometry = try FriGeometry.init(std.math.log2_int(u64, quotient.size_bytes / 16));
        return initWithGeometry(
            metal,
            resident_arena,
            geometry,
            quotient,
            retained,
            challenges,
            inverse_twiddles,
            final_evaluation,
            final_coefficients,
            final_degree_error,
            merkle_layers_root_first,
            leaf_seed,
            node_seed,
        );
    }

    pub fn initWithGeometry(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        geometry: FriGeometry,
        quotient: arena_plan.Binding,
        retained: []const arena_plan.Binding,
        challenges: []const arena_plan.Binding,
        inverse_twiddles: arena_plan.Binding,
        final_evaluation: arena_plan.Binding,
        final_coefficients: arena_plan.Binding,
        final_degree_error: arena_plan.Binding,
        merkle_layers_root_first: []const arena_plan.Binding,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !FriRecipe {
        if (quotient.offset_bytes % 4 != 0 or quotient.size_bytes < 16 or quotient.size_bytes % 16 != 0 or
            !std.math.isPowerOfTwo(quotient.size_bytes / 16) or
            std.math.log2_int(u64, quotient.size_bytes / 16) != geometry.startLog() or
            geometry.finalLog() != 1 or geometry.packedLog() != 2)
            return recovery.RecoveryError.BindingSizeMismatch;
        try validateFriCardinalities(geometry, retained.len, challenges.len, merkle_layers_root_first.len);
        if (inverse_twiddles.offset_bytes % 4 != 0 or inverse_twiddles.size_bytes != geometry.inverseTwiddleWords() * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        var self = FriRecipe{
            .metal = metal,
            .arena = resident_arena,
            .rounds = undefined,
            .trees = undefined,
            .final = undefined,
            .roots = undefined,
            .round_count = geometry.roundCount(),
            .initialized_rounds = 0,
            .initialized_trees = 0,
            .initialized_final = false,
            .final_degree_error = final_degree_error,
        };
        errdefer self.deinitInitialized();

        var evaluations: [FriGeometry.max_round_count]arena_plan.Binding = undefined;
        evaluations[0] = quotient;
        @memcpy(evaluations[1..geometry.roundCount()], retained);
        var layer_cursor: usize = 0;
        for (evaluations[0..geometry.roundCount()], 0..) |evaluation, tree| {
            const log_size = try geometry.evaluationLog(tree);
            const layer_count = try geometry.layerCount(tree);
            const rows = @as(u64, 1) << @intCast(log_size);
            if (evaluation.offset_bytes % 4 != 0 or evaluation.size_bytes != rows * 16)
                return recovery.RecoveryError.BindingSizeMismatch;
            var layer_offsets: [32]u32 = undefined;
            const group = merkle_layers_root_first[layer_cursor .. layer_cursor + layer_count];
            for (0..layer_count) |bottom_index| {
                const binding = group[layer_count - 1 - bottom_index];
                const expected_hashes = (@as(u64, 1) << @intCast(log_size - 2)) >> @intCast(bottom_index);
                if (binding.offset_bytes % 4 != 0 or binding.size_bytes != expected_hashes * 32)
                    return recovery.RecoveryError.BindingSizeMismatch;
                layer_offsets[bottom_index] = std.math.cast(u32, binding.offset_bytes / 4) orelse
                    return recovery.RecoveryError.BindingSizeMismatch;
            }
            self.roots[tree] = group[0];
            self.trees[tree] = try metal.prepareFriTree(
                std.math.cast(u32, evaluation.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                @intCast(rows),
                @intCast(rows),
                2,
                layer_offsets[0..layer_count],
                leaf_seed,
                node_seed,
                cairo_domain_prefix_bytes,
            );
            self.initialized_trees += 1;
            layer_cursor += layer_count;
        }

        const twiddle_base = std.math.cast(u32, inverse_twiddles.offset_bytes / 4) orelse
            return recovery.RecoveryError.BindingSizeMismatch;
        const twiddle_words: u32 = @intCast(inverse_twiddles.size_bytes / 4);
        for (0..geometry.roundCount()) |round| {
            const source = evaluations[round];
            const source_rows = @as(u32, 1) << @intCast(try geometry.evaluationLog(round));
            const fold_count = try geometry.roundFold(round);
            const output = if (round + 1 == geometry.roundCount()) final_evaluation else evaluations[round + 1];
            const output_rows = source_rows >> @intCast(fold_count);
            if (challenges[round].offset_bytes % 4 != 0 or challenges[round].size_bytes < 16 or
                output.offset_bytes % 4 != 0 or output.size_bytes < @as(u64, output_rows) * 16)
                return recovery.RecoveryError.BindingSizeMismatch;
            self.rounds[round] = try metal.prepareFriRound(
                twiddle_base,
                twiddle_words,
                std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                source_rows,
                std.math.cast(u32, challenges[round].offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, output.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                output_rows,
                source_rows,
                fold_count,
                round == 0,
            );
            self.initialized_rounds += 1;
        }
        if (final_coefficients.offset_bytes % 4 != 0 or final_coefficients.size_bytes != 32 or
            final_degree_error.offset_bytes % 4 != 0 or final_degree_error.size_bytes != 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const final_x = @import("../../core/circle.zig").Coset.halfOdds(1).initial.x;
        const inverse_x = final_x.inv() catch return recovery.RecoveryError.BindingSizeMismatch;
        self.final = try metal.prepareFriFinal(
            std.math.cast(u32, final_evaluation.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            2,
            inverse_x.v,
            std.math.cast(u32, final_coefficients.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, final_degree_error.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
        );
        self.initialized_final = true;
        return self;
    }

    fn deinitInitialized(self: *FriRecipe) void {
        if (self.initialized_final) self.final.deinit();
        for (self.rounds[0..self.initialized_rounds]) |*plan| plan.deinit();
        for (self.trees[0..self.initialized_trees]) |*plan| plan.deinit();
    }

    pub fn deinit(self: *FriRecipe) void {
        self.deinitInitialized();
        self.* = undefined;
    }

    pub fn commitTree(self: *FriRecipe, tree: usize) !arena_plan.Binding {
        if (tree >= self.round_count) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.friTreePrepared(self.arena.buffer, self.trees[tree]);
        return self.roots[tree];
    }

    pub fn foldRound(self: *FriRecipe, round: usize) !void {
        if (round >= self.round_count) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.friRoundPrepared(self.arena.buffer, self.rounds[round]);
    }

    pub fn finalize(self: *FriRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.friFinalPrepared(self.arena.buffer, self.final);
        self.finalized = true;
        try self.validateFinalDegree();
    }

    pub fn validateFinalDegree(self: *FriRecipe) !void {
        if (!self.finalized) return FinalDegreeError.FinalDegreeNotComputed;
        const bytes = try self.arena.bytes(self.final_degree_error);
        if (bytes.len != @sizeOf(u32)) return recovery.RecoveryError.BindingSizeMismatch;
        const aligned: []align(@alignOf(u32)) u8 = @alignCast(bytes);
        if (std.mem.bytesAsValue(u32, aligned).* != 0)
            return FinalDegreeError.FinalDegreeExceeded;
    }
};

pub const TranscriptBinding = struct {
    ordinal: u32,
    binding: arena_plan.Binding,
};

fn bindingWordOffset(binding: arena_plan.Binding) !u64 {
    if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
    return binding.offset_bytes / 4;
}

const PendingTraceGather = struct {
    column_offsets: u64,
    column_logs: u64,
    column_count: u32,
    lifting_log: u32,
    first_column: u32,
    stride: u32,
    values: u64,
};

/// Query-normalization and FRI coset preparation for a validated Cairo opening
/// schedule. All FRI trees reuse the same epoch-local workspaces; only their
/// authenticated cumulative fold differs.
pub const DecommitQueryRecipe = struct {
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    raw_queries: arena_plan.Binding,
    unique_queries: arena_plan.Binding,
    mapped_queries: arena_plan.Binding,
    expanded_positions: arena_plan.Binding,
    walk_queries: arena_plan.Binding,
    walk_scratch: arena_plan.Binding,
    sparse_indices: arena_plan.Binding,
    sparse_hashes: arena_plan.Binding,
    counts: arena_plan.Binding,
    assembly: arena_plan.Binding,
    tree_count: u32,
    fri_geometry: FriGeometry,
    pending_trace_gather: ?PendingTraceGather = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        raw_queries: arena_plan.Binding,
        unique_queries: arena_plan.Binding,
        mapped_queries: arena_plan.Binding,
        expanded_positions: arena_plan.Binding,
        walk_queries: arena_plan.Binding,
        walk_scratch: arena_plan.Binding,
        sparse_indices: arena_plan.Binding,
        sparse_hashes: arena_plan.Binding,
        counts: arena_plan.Binding,
        assembly: arena_plan.Binding,
        tree_count: u32,
        fri_start_log: u32,
    ) !DecommitQueryRecipe {
        return initWithGeometry(
            metal,
            resident_arena,
            raw_queries,
            unique_queries,
            mapped_queries,
            expanded_positions,
            walk_queries,
            walk_scratch,
            sparse_indices,
            sparse_hashes,
            counts,
            assembly,
            tree_count,
            try FriGeometry.init(fri_start_log),
        );
    }

    pub fn initWithGeometry(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        raw_queries: arena_plan.Binding,
        unique_queries: arena_plan.Binding,
        mapped_queries: arena_plan.Binding,
        expanded_positions: arena_plan.Binding,
        walk_queries: arena_plan.Binding,
        walk_scratch: arena_plan.Binding,
        sparse_indices: arena_plan.Binding,
        sparse_hashes: arena_plan.Binding,
        counts: arena_plan.Binding,
        assembly: arena_plan.Binding,
        tree_count: u32,
        geometry: FriGeometry,
    ) !DecommitQueryRecipe {
        for ([_]arena_plan.Binding{ raw_queries, unique_queries, mapped_queries, expanded_positions, walk_queries, walk_scratch, sparse_indices, sparse_hashes, counts }) |binding| {
            if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
        }
        if (raw_queries.size_bytes != 70 * 4 or unique_queries.size_bytes < raw_queries.size_bytes or tree_count == 0 or
            mapped_queries.size_bytes < raw_queries.size_bytes or expanded_positions.size_bytes < 560 * 4 or
            walk_queries.size_bytes < 560 * 4 or walk_scratch.size_bytes < walk_queries.size_bytes or sparse_indices.size_bytes < 560 * 4 or counts.size_bytes < 4 * 4 or
            assembly.offset_bytes % 4 != 0 or assembly.size_bytes / 4 > std.math.maxInt(u32))
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .metal = metal,
            .arena = resident_arena,
            .raw_queries = raw_queries,
            .unique_queries = unique_queries,
            .mapped_queries = mapped_queries,
            .expanded_positions = expanded_positions,
            .walk_queries = walk_queries,
            .walk_scratch = walk_scratch,
            .sparse_indices = sparse_indices,
            .sparse_hashes = sparse_hashes,
            .counts = counts,
            .assembly = assembly,
            .tree_count = tree_count,
            .fri_geometry = geometry,
        };
    }

    pub fn normalize(self: *DecommitQueryRecipe) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitNormalizeQueries(
            self.arena.buffer,
            try bindingWordOffset(self.raw_queries),
            70,
            self.fri_geometry.start_log,
            try bindingWordOffset(self.unique_queries),
            count_base,
            self.tree_count,
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }

    pub fn prepareFri(self: *DecommitQueryRecipe, round: usize) !void {
        if (self.pending_trace_gather != null or round >= self.fri_geometry.roundCount())
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitPrepareFriQueries(
            self.arena.buffer,
            try bindingWordOffset(self.unique_queries),
            count_base,
            70,
            try self.fri_geometry.cumulativeFold(round),
            try self.fri_geometry.roundFold(round),
            self.fri_geometry.packedLog(),
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            try bindingWordOffset(self.walk_queries),
            count_base + 2,
        );
    }

    /// Encodes query preparation, coordinate gathering, and proof assembly for
    /// one FRI tree into a single command buffer. There is no host dependency
    /// between these kernels; separate encoders preserve their device ordering.
    pub fn executeFriRound(
        self: *DecommitQueryRecipe,
        round: usize,
        tree_index: u32,
        leaf_log: u32,
        coordinate_offsets: arena_plan.Binding,
        retained_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        try validateFriOpeningRound(self.fri_geometry, round, leaf_log);
        if (coordinate_offsets.size_bytes < 8 * @sizeOf(u32) or
            retained_offsets.size_bytes < @as(u64, leaf_log + 1) * 2 * @sizeOf(u32) or
            values.size_bytes < self.expanded_positions.size_bytes * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitFriRound(
            self.arena.buffer,
            .{
                .unique_base = try bindingWordOffset(self.unique_queries),
                .unique_count_base = count_base,
                .tree_queries_base = try bindingWordOffset(self.mapped_queries),
                .tree_count_base = count_base + 1,
                .expanded_base = try bindingWordOffset(self.expanded_positions),
                .expanded_count_base = count_base + 3,
                .walk_base = try bindingWordOffset(self.walk_queries),
                .walk_count_base = count_base + 2,
                .coordinate_bases = try bindingWordOffset(coordinate_offsets),
                .values_base = try bindingWordOffset(values),
                .walk_scratch_base = try bindingWordOffset(self.walk_scratch),
                .retained_offsets = try bindingWordOffset(retained_offsets),
                .assembly_base = try bindingWordOffset(self.assembly),
                .max_queries = 70,
                .cumulative_fold = try self.fri_geometry.cumulativeFold(round),
                .fold_step = try self.fri_geometry.roundFold(round),
                .packed_log = self.fri_geometry.packedLog(),
                .max_positions = @intCast(self.expanded_positions.size_bytes / @sizeOf(u32)),
                .tree_index = tree_index,
                .leaf_log = leaf_log,
                .assembly_capacity = @intCast(self.assembly.size_bytes / @sizeOf(u32)),
            },
        );
    }

    pub fn prepareTrace(
        self: *DecommitQueryRecipe,
        source_log: u32,
        tree_log: u32,
        leaf_log: u32,
        unretained: u32,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitPrepareTraceQueries(
            self.arena.buffer,
            try bindingWordOffset(self.unique_queries),
            count_base,
            70,
            source_log,
            tree_log,
            leaf_log,
            unretained,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.walk_queries),
            count_base + 2,
            try bindingWordOffset(self.sparse_indices),
            count_base + 4,
        );
    }

    pub fn gatherTraceValues(
        self: *DecommitQueryRecipe,
        column_offsets: arena_plan.Binding,
        column_logs: arena_plan.Binding,
        column_count: u32,
        lifting_log: u32,
        first_column: u32,
        stride: u32,
        values: arena_plan.Binding,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (column_count == 0 or lifting_log >= 31 or stride < 70 or
            column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            values.size_bytes < (@as(u64, first_column) + column_count) * stride * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        self.pending_trace_gather = .{
            .column_offsets = try bindingWordOffset(column_offsets),
            .column_logs = try bindingWordOffset(column_logs),
            .column_count = column_count,
            .lifting_log = lifting_log,
            .first_column = first_column,
            .stride = stride,
            .values = try bindingWordOffset(values),
        };
    }

    pub fn sparseParent(
        self: *DecommitQueryRecipe,
        distance: u32,
        child_offset: u32,
        child_capacity: u32,
        parent_offset: u32,
        node_seed: [8]u32,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (distance == 0 or child_capacity < 2 or parent_offset >= self.sparse_indices.size_bytes / 4 or
            @as(u64, child_offset + child_capacity) * 4 > self.sparse_indices.size_bytes or
            @as(u64, child_offset + child_capacity) * 32 > self.sparse_hashes.size_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitSparseParent(
            self.arena.buffer,
            try bindingWordOffset(self.sparse_indices) + child_offset,
            try bindingWordOffset(self.sparse_hashes) + child_offset * 8,
            count_base + 4 + distance - 1,
            child_capacity,
            try bindingWordOffset(self.sparse_indices) + parent_offset,
            try bindingWordOffset(self.sparse_hashes) + parent_offset * 8,
            count_base + 4 + distance,
            node_seed,
            cairo_domain_prefix_bytes,
        );
    }

    pub fn sparseLeaves(
        self: *DecommitQueryRecipe,
        column_offsets: arena_plan.Binding,
        column_logs: arena_plan.Binding,
        column_count: u32,
        leaf_log: u32,
        max_leaf_count: u32,
        leaf_seed: [8]u32,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            @as(u64, max_leaf_count) * 4 > self.sparse_indices.size_bytes or
            @as(u64, max_leaf_count) * 32 > self.sparse_hashes.size_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitSparseLeaves(
            self.arena.buffer,
            try bindingWordOffset(column_offsets),
            try bindingWordOffset(column_logs),
            column_count,
            leaf_log,
            try bindingWordOffset(self.sparse_indices),
            count_base + 4,
            max_leaf_count,
            try bindingWordOffset(self.sparse_hashes),
            leaf_seed,
            cairo_domain_prefix_bytes,
        );
    }

    pub fn sparseLeafGroup(
        self: *DecommitQueryRecipe,
        column_offsets: arena_plan.Binding,
        column_logs: arena_plan.Binding,
        column_count: u32,
        first_column: u32,
        total_columns: u32,
        lifting_log: u32,
        max_leaf_count: u32,
        leaf_seed: [8]u32,
    ) !void {
        if (column_count == 0 or column_count > 16 or first_column >= total_columns or
            column_count > total_columns - first_column or first_column % 16 != 0 or
            (first_column + column_count < total_columns and column_count % 16 != 0) or
            column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            @as(u64, max_leaf_count) * 4 > self.sparse_indices.size_bytes or
            @as(u64, max_leaf_count) * 32 > self.sparse_hashes.size_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const pending = self.pending_trace_gather orelse return recovery.RecoveryError.BindingSizeMismatch;
        const column_offsets_words = try bindingWordOffset(column_offsets);
        const column_logs_words = try bindingWordOffset(column_logs);
        if (pending.column_offsets != column_offsets_words or pending.column_logs != column_logs_words or
            pending.column_count != column_count or pending.first_column != first_column or
            pending.lifting_log != lifting_log)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitTraceGroup(
            self.arena.buffer,
            .{
                .column_offsets = pending.column_offsets,
                .column_logs = pending.column_logs,
                .queries = try bindingWordOffset(self.mapped_queries),
                .query_count_at = count_base + 1,
                .values = pending.values,
                .leaf_indices = try bindingWordOffset(self.sparse_indices),
                .leaf_count_at = count_base + 4,
                .output_hashes = try bindingWordOffset(self.sparse_hashes),
                .column_count = column_count,
                .lifting_log = lifting_log,
                .max_queries = 70,
                .first_column = first_column,
                .stride = pending.stride,
                .total_columns = total_columns,
                .max_leaf_count = max_leaf_count,
                .domain_prefix_bytes = cairo_domain_prefix_bytes,
                .leaf_seed = leaf_seed,
            },
        );
        self.pending_trace_gather = null;
    }

    pub fn assembleTrace(
        self: *DecommitQueryRecipe,
        tree_index: u32,
        role: u32,
        leaf_log: u32,
        unretained: u32,
        column_count: u32,
        retained_offsets: arena_plan.Binding,
        sparse_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (unretained > leaf_log or retained_offsets.size_bytes < @as(u64, leaf_log - unretained + 1) * 4 or
            sparse_offsets.size_bytes < @as(u64, unretained) * 4 or values.size_bytes < @as(u64, column_count) * 70 * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitAssembleTrace(
            self.arena.buffer,
            tree_index,
            role,
            leaf_log,
            leaf_log - unretained,
            column_count,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            70,
            try bindingWordOffset(self.walk_queries),
            try bindingWordOffset(self.walk_scratch),
            count_base + 2,
            try bindingWordOffset(values),
            try bindingWordOffset(retained_offsets),
            try bindingWordOffset(self.sparse_indices),
            try bindingWordOffset(self.sparse_hashes),
            try bindingWordOffset(sparse_offsets),
            count_base + 4,
            unretained,
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }

    pub fn gatherFriValues(
        self: *DecommitQueryRecipe,
        coordinate_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        if (coordinate_offsets.size_bytes < 16 or values.size_bytes < self.expanded_positions.size_bytes * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitGatherFriValues(
            self.arena.buffer,
            try bindingWordOffset(coordinate_offsets),
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            @intCast(self.expanded_positions.size_bytes / 4),
            try bindingWordOffset(values),
        );
    }

    pub fn assembleFri(
        self: *DecommitQueryRecipe,
        tree_index: u32,
        leaf_log: u32,
        coordinate_offsets: arena_plan.Binding,
        retained_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        try self.gatherFriValues(coordinate_offsets, values);
        if (retained_offsets.size_bytes < @as(u64, leaf_log + 1) * 4) return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitAssembleFri(
            self.arena.buffer,
            tree_index,
            leaf_log,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            try bindingWordOffset(values),
            try bindingWordOffset(self.walk_queries),
            try bindingWordOffset(self.walk_scratch),
            count_base + 2,
            try bindingWordOffset(retained_offsets),
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }
};

/// Exact Cairo transcript controller. Blake2s absorption and rejection-sampled
/// challenge/query draws execute in the resident arena; the host only orders
/// true protocol dependencies and grinds the two proof-of-work nonces.
pub const PowExecutionMode = enum {
    not_run,
    self_ground,
    fixture_forced,
    mixed,
};

/// CPU-only timing around nonce search or validation. Transcript-state
/// readback, nonce absorption, and subsequent Metal draws are deliberately
/// excluded so diagnostic nonce validation cannot masquerade as search cost.
pub const PowTelemetry = struct {
    mode: PowExecutionMode = .not_run,
    pow_bits: u32 = 0,
    invocations: u32 = 0,
    wall_ns: u64 = 0,

    pub fn wallSeconds(self: PowTelemetry) ?f64 {
        if (self.invocations == 0) return null;
        return @as(f64, @floatFromInt(self.wall_ns)) /
            @as(f64, @floatFromInt(std.time.ns_per_s));
    }

    pub fn modeName(self: PowTelemetry) ?[]const u8 {
        return if (self.mode == .not_run) null else @tagName(self.mode);
    }

    fn record(self: *PowTelemetry, mode: PowExecutionMode, pow_bits: u32, elapsed_ns: u64) void {
        if (self.invocations == 0) {
            self.mode = mode;
            self.pow_bits = pow_bits;
        } else if (self.mode != mode or self.pow_bits != pow_bits) {
            self.mode = .mixed;
        }
        self.invocations += 1;
        self.wall_ns +|= elapsed_ns;
    }
};

test "PoW telemetry separates search from forced validation" {
    var telemetry = PowTelemetry{};
    try std.testing.expectEqual(@as(?f64, null), telemetry.wallSeconds());
    try std.testing.expectEqual(@as(?[]const u8, null), telemetry.modeName());

    telemetry.record(.self_ground, 24, std.time.ns_per_ms * 3);
    try std.testing.expectEqualStrings("self_ground", telemetry.modeName().?);
    try std.testing.expectEqual(@as(u32, 24), telemetry.pow_bits);
    try std.testing.expectEqual(@as(u32, 1), telemetry.invocations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), telemetry.wallSeconds().?, 1e-12);

    telemetry.record(.self_ground, 24, std.time.ns_per_ms * 2);
    try std.testing.expectEqual(@as(u32, 2), telemetry.invocations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), telemetry.wallSeconds().?, 1e-12);

    telemetry.record(.fixture_forced, 24, 1);
    try std.testing.expectEqualStrings("mixed", telemetry.modeName().?);
}

pub const TranscriptRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    state: arena_plan.Binding,
    query_log: u32,
    inputs: []TranscriptBinding,
    outputs: []TranscriptBinding,
    accumulated_gpu_ms: f64 = 0,
    interaction_pow: PowTelemetry = .{},
    query_pow: PowTelemetry = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        state: arena_plan.Binding,
        query_log: u32,
        inputs: []const TranscriptBinding,
        outputs: []const TranscriptBinding,
    ) !TranscriptRecipe {
        if (state.offset_bytes % 4 != 0 or state.size_bytes < 40 or query_log >= 31 or
            inputs.len == 0 or outputs.len == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .state = state,
            .query_log = query_log,
            .inputs = try allocator.dupe(TranscriptBinding, inputs),
            .outputs = try allocator.dupe(TranscriptBinding, outputs),
        };
    }

    pub fn deinit(self: *TranscriptRecipe) void {
        self.allocator.free(self.inputs);
        self.allocator.free(self.outputs);
        self.* = undefined;
    }

    pub fn initialize(self: *TranscriptRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.transcriptInit(self.arena.buffer, try wordOffset(self.state));
    }

    pub fn publishInput(self: *TranscriptRecipe, ordinal: u32, source: arena_plan.Binding, words: u32) !void {
        const destination = try self.find(self.inputs, ordinal);
        if (source.size_bytes < @as(u64, words) * 4 or destination.size_bytes < @as(u64, words) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const source_bytes = try self.arena.bytes(source);
        const destination_bytes = try self.arena.bytes(destination);
        @memcpy(destination_bytes[0 .. @as(usize, words) * 4], source_bytes[0 .. @as(usize, words) * 4]);
    }

    /// Loads a parity fixture directly into one transcript input binding.
    pub fn loadInputWords(self: *TranscriptRecipe, ordinal: u32, words: []const u32) !void {
        const destination = try self.find(self.inputs, ordinal);
        if (destination.size_bytes != @as(u64, words.len) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const destination_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(destination));
        @memcpy(std.mem.bytesAsSlice(u32, destination_bytes), words);
    }

    /// Fails closed when a resident transcript draw differs from the reference.
    pub fn expectOutputWords(self: TranscriptRecipe, ordinal: u32, expected: []const u32) !void {
        const output_binding = try self.find(self.outputs, ordinal);
        if (output_binding.size_bytes < @as(u64, expected.len) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const output_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(output_binding));
        const actual = std.mem.bytesAsSlice(u32, output_bytes);
        if (!std.mem.eql(u32, actual[0..expected.len], expected)) {
            std.debug.print(
                "transcript output parity mismatch ordinal={} actual={any} expected={any}\n",
                .{ ordinal, actual[0..expected.len], expected },
            );
            return error.TranscriptParityMismatch;
        }
    }

    pub fn expectInputWords(self: TranscriptRecipe, ordinal: u32, expected: []const u32) !void {
        const input_binding = try self.find(self.inputs, ordinal);
        if (input_binding.size_bytes != @as(u64, expected.len) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const input_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(input_binding));
        const actual = std.mem.bytesAsSlice(u32, input_bytes);
        if (!std.mem.eql(u32, actual, expected)) {
            std.debug.print(
                "transcript input parity mismatch ordinal={} actual={any} expected={any}\n",
                .{ ordinal, actual, expected },
            );
            return error.TranscriptParityMismatch;
        }
    }

    pub fn bootstrapThroughBase(self: *TranscriptRecipe) !void {
        for ([_]u32{ 1, 2, 3, 10, 11, 12, 13, 14, 15, 16, 20 }) |input| try self.mixInput(input);
    }

    pub fn interactionPowAndLookup(self: *TranscriptRecipe) !u64 {
        const nonce = try self.grindAndMix(21, 24, &self.interaction_pow);
        try self.drawSecure(1, 2);
        return nonce;
    }

    /// Uses and validates the Rust reference nonce for transcript parity. Rust
    /// and Zig search valid nonces in different orders, so local grinding is
    /// not expected to reproduce the same transcript suffix.
    pub fn interactionPowAndLookupNonce(self: *TranscriptRecipe, nonce: u64) !void {
        try self.validateAndMixNonce(21, 24, nonce, &self.interaction_pow);
        try self.drawSecure(1, 2);
    }

    pub fn interactionAndComposition(self: *TranscriptRecipe) !void {
        try self.mixInput(22);
        try self.mixInput(23);
        try self.drawSecure(2, 1);
    }

    pub fn compositionAndOods(self: *TranscriptRecipe) !void {
        try self.mixInput(24);
        try self.drawSecure(3, 1);
    }

    pub fn oodsAndQuotient(self: *TranscriptRecipe) !void {
        try self.mixInput(25);
        try self.drawSecure(4, 1);
    }

    pub fn friLayer(
        self: *TranscriptRecipe,
        layer: u32,
        root: arena_plan.Binding,
        challenge: arena_plan.Binding,
    ) !void {
        const input_ordinal = 65536 + layer * 4;
        const output_ordinal = input_ordinal + 1;
        try self.publishInput(input_ordinal, root, 8);
        try self.mixInput(input_ordinal);
        try self.drawSecure(output_ordinal, 1);
        const drawn = try self.find(self.outputs, output_ordinal);
        const output_bytes = try self.arena.bytes(drawn);
        const challenge_bytes = try self.arena.bytes(challenge);
        if (challenge_bytes.len < 16) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(challenge_bytes[0..16], output_bytes[0..16]);
    }

    pub fn lastLayer(self: *TranscriptRecipe, coefficients: arena_plan.Binding) !void {
        try self.publishInput(30, coefficients, 4);
        try self.mixInput(30);
    }

    pub fn queryPowAndPositions(self: *TranscriptRecipe) !u64 {
        const nonce = try self.grindAndMix(31, 26, &self.query_pow);
        try self.drawQueryPositions();
        return nonce;
    }

    pub fn queryPowAndPositionsNonce(self: *TranscriptRecipe, nonce: u64) !void {
        try self.validateAndMixNonce(31, 26, nonce, &self.query_pow);
        try self.drawQueryPositions();
    }

    fn drawQueryPositions(self: *TranscriptRecipe) !void {
        const queries = try self.find(self.outputs, 5);
        self.accumulated_gpu_ms += try self.metal.transcriptDrawQueries(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(queries),
            self.query_log,
            70,
        );
    }

    pub fn output(self: TranscriptRecipe, ordinal: u32) !arena_plan.Binding {
        return self.find(self.outputs, ordinal);
    }

    fn mixInput(self: *TranscriptRecipe, ordinal: u32) !void {
        const input = try self.find(self.inputs, ordinal);
        if (input.size_bytes == 0 or input.size_bytes % 4 != 0 or input.size_bytes / 4 > std.math.maxInt(u32))
            return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.transcriptMix(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(input),
            @intCast(input.size_bytes / 4),
        );
    }

    fn drawSecure(self: *TranscriptRecipe, ordinal: u32, felt_count: u32) !void {
        const output_binding = try self.find(self.outputs, ordinal);
        if (output_binding.size_bytes < @as(u64, felt_count) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.transcriptDrawSecure(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(output_binding),
            felt_count,
        );
    }

    fn grindAndMix(
        self: *TranscriptRecipe,
        input_ordinal: u32,
        pow_bits: u32,
        telemetry: *PowTelemetry,
    ) !u64 {
        const channel = try self.channelFromState();
        var timer = try std.time.Timer.start();
        const nonce = channel.grind(pow_bits);
        telemetry.record(.self_ground, pow_bits, timer.read());
        try self.writeAndMixNonce(input_ordinal, nonce);
        return nonce;
    }

    fn validateAndMixNonce(
        self: *TranscriptRecipe,
        input_ordinal: u32,
        pow_bits: u32,
        nonce: u64,
        telemetry: *PowTelemetry,
    ) !void {
        const channel = try self.channelFromState();
        var timer = try std.time.Timer.start();
        const valid = channel.verifyPowNonce(pow_bits, nonce);
        telemetry.record(.fixture_forced, pow_bits, timer.read());
        if (!valid) return error.InvalidReferencePowNonce;
        try self.writeAndMixNonce(input_ordinal, nonce);
    }

    fn writeAndMixNonce(self: *TranscriptRecipe, input_ordinal: u32, nonce: u64) !void {
        const destination = try self.find(self.inputs, input_ordinal);
        const destination_bytes = try self.arena.bytes(destination);
        if (destination_bytes.len < 8) return recovery.RecoveryError.BindingSizeMismatch;
        std.mem.writeInt(u64, destination_bytes[0..8], nonce, .little);
        try self.mixInput(input_ordinal);
    }

    fn channelFromState(self: TranscriptRecipe) !blake2s_channel.Blake2sChannel {
        const state_bytes = try self.arena.bytes(self.state);
        if (state_bytes.len < 9 * 4) return recovery.RecoveryError.BindingSizeMismatch;
        const state_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(state_bytes)));
        var channel = blake2s_channel.Blake2sChannel{};
        @memcpy(&channel.digest, std.mem.sliceAsBytes(state_words[0..8]));
        channel.n_draws = state_words[8];
        return channel;
    }

    fn find(_: TranscriptRecipe, bindings: []const TranscriptBinding, ordinal: u32) !arena_plan.Binding {
        for (bindings) |binding| if (binding.ordinal == ordinal) return binding.binding;
        return recovery.RecoveryError.MissingRecipe;
    }

    fn wordOffset(binding: arena_plan.Binding) !u32 {
        if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
        return std.math.cast(u32, binding.offset_bytes / 4) orelse recovery.RecoveryError.BindingSizeMismatch;
    }
};

test "Metal protocol recovery: copy recipe writes the destination binding" {
    const Access = struct {
        source: []u8,
        fn bytes(raw: *anyopaque, _: arena_plan.Binding) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.source;
        }
    };
    var source = [_]u8{ 1, 2, 3, 4 };
    var access_context = Access{ .source = &source };
    const binding = arena_plan.Binding{
        .logical_id = 1,
        .slot = 0,
        .offset_bytes = 0,
        .size_bytes = 4,
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };
    var copy = CopyRecipe{ .access = .{ .context = &access_context, .bytes_fn = Access.bytes }, .source = binding };
    var destination = [_]u8{0} ** 4;
    try copy.recipe(2).run(&copy, 1, binding, &destination);
    try std.testing.expectEqualSlices(u8, &source, &destination);
}
