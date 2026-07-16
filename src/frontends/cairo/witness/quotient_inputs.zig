const std = @import("std");
const arena_plan = @import("../../../backends/metal/arena_plan.zig");
const metal_runtime = @import("../../../backends/metal/runtime.zig");
const composition_bundle = @import("composition_bundle.zig");
const quotients = @import("../../../core/pcs/quotients.zig");
const twiddles = @import("../../../prover/poly/twiddles.zig");
const circle = @import("../../../core/circle.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;

const fixture_magic = "STWZQI01";
const fixture_version: u32 = 1;
const m31_prime: u32 = 0x7fff_ffff;

pub const Telemetry = struct {
    wall_ms: f64,
    gpu_ms: f64,
    sample_count: usize,
    column_count: usize,
    source_words_scanned: u64,
};

pub const ReferenceValidation = struct {
    quotient_digest: [32]u8,
    payload_bytes: u64,
};

const Span = struct { start: usize, end: usize };

const Masks = struct {
    allocator: std.mem.Allocator,
    preprocessed_used: []bool,
    base_offsets: []std.ArrayList(i32),
    interaction_offsets: []std.ArrayList(i32),

    fn deinit(self: *Masks) void {
        self.allocator.free(self.preprocessed_used);
        freeOffsetLists(self.allocator, self.base_offsets);
        freeOffsetLists(self.allocator, self.interaction_offsets);
        self.* = undefined;
    }
};

const SampleRange = struct { start: usize, len: usize };

const OwnedColumns = struct {
    allocator: std.mem.Allocator,
    bindings: []arena_plan.Binding,
    flat_samples: []quotients.SampleWithRandomness,
    samples: [][]const quotients.SampleWithRandomness,

    fn deinit(self: *OwnedColumns) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.flat_samples);
        self.allocator.free(self.bindings);
        self.* = undefined;
    }
};

const SavedPartial = struct {
    log_size: u32,
    coordinates: [4][]M31,

    fn init(
        allocator: std.mem.Allocator,
        resident_arena: *arena_plan.ResidentArena,
        partials: []const arena_plan.Binding,
        target: usize,
        log_size: u32,
    ) !SavedPartial {
        const word_count = @as(usize, 1) << @intCast(log_size);
        var coordinates: [4][]M31 = undefined;
        var initialized: usize = 0;
        errdefer for (coordinates[0..initialized]) |coordinate| allocator.free(coordinate);
        for (0..4) |coordinate| {
            const source = try bindingM31(resident_arena, partials[target * 4 + coordinate]);
            if (source.len < word_count) return error.InvalidQuotientInputShape;
            coordinates[coordinate] = try allocator.dupe(M31, source[0..word_count]);
            initialized += 1;
        }
        return .{ .log_size = log_size, .coordinates = coordinates };
    }

    fn deinit(self: *SavedPartial, allocator: std.mem.Allocator) void {
        for (self.coordinates) |coordinate| allocator.free(coordinate);
        self.* = undefined;
    }
};

fn liftAndAccumulateEvaluation(destination: []M31, previous: []const M31) !void {
    if (destination.len <= previous.len or
        !std.math.isPowerOfTwo(destination.len) or
        !std.math.isPowerOfTwo(previous.len))
        return error.InvalidQuotientPartialLogs;
    const log_ratio = std.math.log2_int(usize, destination.len) -
        std.math.log2_int(usize, previous.len);
    const lift_shift: std.math.Log2Int(usize) = @intCast(log_ratio + 1);
    for (destination, 0..) |*value, row| {
        const lifted_index = ((row >> lift_shift) << 1) + (row & 1);
        if (lifted_index >= previous.len) return error.InvalidQuotientPartialLogs;
        value.* = value.add(previous[lifted_index]);
    }
}

/// Builds the 19 accumulated numerator inputs used by the quotient bottom.
/// Numerators are accumulated and transformed per source log, then lifted and
/// accumulated in evaluation space exactly like the Rust backend.
pub fn populate(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    bundle: composition_bundle.Bundle,
    preprocessed: []const arena_plan.Binding,
    base: []const arena_plan.Binding,
    interaction: []const arena_plan.Binding,
    composition: []const arena_plan.Binding,
    oods_challenge: arena_plan.Binding,
    quotient_random: arena_plan.Binding,
    sampled_values: arena_plan.Binding,
    partials: []const arena_plan.Binding,
    sample_points: arena_plan.Binding,
    first_linear_terms: arena_plan.Binding,
    forward_twiddles: arena_plan.Binding,
) !Telemetry {
    var timer = try std.time.Timer.start();
    if (composition.len != 8 or partials.len == 0 or partials.len % 4 != 0)
        return error.InvalidQuotientInputShape;
    const lifting_log_size = try validatedLiftingLogSize(bundle.max_evaluation_log_size);
    const max_trace_log_size = lifting_log_size - 1;
    const sample_count = partials.len / 4;
    if (sample_points.size_bytes != @as(u64, sample_count) * 8 * 4 or
        first_linear_terms.size_bytes != @as(u64, sample_count) * 4 * 4)
        return error.InvalidQuotientInputShape;

    const oods_words = try bindingWords(resident_arena, oods_challenge);
    const random_words = try bindingWords(resident_arena, quotient_random);
    const sampled_words = try bindingWords(resident_arena, sampled_values);
    if (oods_words.len < 4 or random_words.len < 4 or sampled_words.len % 4 != 0)
        return error.InvalidQuotientInputShape;
    try canonicalWords(oods_words[0..4]);
    try canonicalWords(random_words[0..4]);
    try canonicalWords(sampled_words);
    const oods_point = try pointFromParameter(secureFromWords(oods_words[0..4]));
    const random_coeff = secureFromWords(random_words[0..4]);

    var masks = try deriveMasks(allocator, bundle, preprocessed.len, base.len, interaction.len);
    defer masks.deinit();
    const log_stages = std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS");
    if (log_stages)
        std.debug.print(
            "quotient_inputs stage=masks preprocessed={} base={} interaction={}\n",
            .{ preprocessed.len, base.len, interaction.len },
        );
    var columns = try buildColumns(
        allocator,
        preprocessed,
        base,
        interaction,
        composition,
        masks,
        oods_point,
        sampled_words,
        random_coeff,
        lifting_log_size,
        max_trace_log_size,
    );
    defer columns.deinit();
    if (log_stages) {
        var maximum_end: u64 = 0;
        for (columns.bindings) |binding| maximum_end = @max(maximum_end, binding.offset_bytes + binding.size_bytes);
        std.debug.print(
            "quotient_inputs stage=columns columns={} samples={} maximum_end_bytes={}\n",
            .{ columns.bindings.len, columns.flat_samples.len, maximum_end },
        );
    }

    const batches = try quotients.ColumnSampleBatch.newVec(allocator, columns.samples);
    defer quotients.ColumnSampleBatch.deinitSlice(allocator, batches);
    if (batches.len != sample_count) return error.InvalidQuotientSampleCount;
    if (log_stages)
        std.debug.print("quotient_inputs stage=batches batches={}\n", .{batches.len});
    var constants = try quotients.quotientConstants(allocator, batches);
    defer constants.deinit(allocator);
    if (log_stages)
        std.debug.print("quotient_inputs stage=constants line_coeff_batches={}\n", .{constants.line_coeffs.len});

    const sample_output = try bindingWords(resident_arena, sample_points);
    const linear_output = try bindingWords(resident_arena, first_linear_terms);
    const assigned = try allocator.alloc(bool, sample_count);
    defer allocator.free(assigned);
    @memset(assigned, false);
    var targets_by_point = std.AutoHashMap(circle.CirclePointQM31, usize).init(allocator);
    defer targets_by_point.deinit();
    var source_words_scanned: u64 = 0;

    // Rust sorts the per-log accumulations by sample point before grouping and
    // lifting them. Preserve that order when assigning equal-sized bindings.
    const batch_order = try allocator.alloc(usize, batches.len);
    defer allocator.free(batch_order);
    for (batch_order, 0..) |*index, value| index.* = value;
    std.mem.sort(usize, batch_order, batches, struct {
        fn lessThan(all_batches: []quotients.ColumnSampleBatch, lhs: usize, rhs: usize) bool {
            return pointLessThan(all_batches[lhs].point, all_batches[rhs].point);
        }
    }.lessThan);

    // Establish the final point-to-binding geometry and linear terms. Partial
    // numerators are produced per source log below, as in the Rust backend.
    for (batch_order) |batch_index| {
        const batch = batches[batch_index];
        const line_coeffs = constants.line_coeffs[batch_index];
        if (batch.cols_vals_randpows.len == 0 or batch.cols_vals_randpows.len != line_coeffs.len)
            return error.InvalidQuotientInputShape;
        var maximum_source_words: u64 = 0;
        for (batch.cols_vals_randpows) |sample| {
            if (sample.column_index >= columns.bindings.len) return error.InvalidQuotientInputShape;
            maximum_source_words = @max(
                maximum_source_words,
                columns.bindings[sample.column_index].size_bytes / 4,
            );
        }
        if (maximum_source_words == 0 or !std.math.isPowerOfTwo(maximum_source_words))
            return error.InvalidQuotientInputShape;
        const row_words = maximum_source_words;
        var group: ?usize = null;
        for (0..sample_count) |candidate| {
            if (!assigned[candidate] and partials[candidate * 4].size_bytes / 4 == row_words) {
                group = candidate;
                break;
            }
        }
        const target = group orelse return error.InvalidQuotientPartialLogs;
        assigned[target] = true;
        var sum_a = QM31.zero();
        for (line_coeffs) |coeffs| {
            sum_a = sum_a.add(coeffs.a);
        }

        const point_words = batch.point.x.toM31Array() ++ batch.point.y.toM31Array();
        for (point_words, 0..) |word, coordinate| sample_output[target * 8 + coordinate] = word.v;
        const linear = sum_a.toM31Array();
        for (linear, 0..) |word, coordinate| linear_output[target * 4 + coordinate] = word.v;
        const point_entry = try targets_by_point.getOrPut(batch.point);
        if (point_entry.found_existing) return error.InvalidQuotientSampleCount;
        point_entry.value_ptr.* = target;
    }
    for (assigned) |value| if (!value) return error.InvalidQuotientPartialLogs;
    if (log_stages)
        std.debug.print("quotient_inputs stage=geometry points={}\n", .{targets_by_point.count()});

    const accumulated_logs = try allocator.alloc(?u32, sample_count);
    defer allocator.free(accumulated_logs);
    @memset(accumulated_logs, null);
    var gpu_ms: f64 = 0;
    _ = forward_twiddles;
    var source_log: u32 = 3;
    while (source_log <= max_trace_log_size) : (source_log += 1) {
        var group_bindings = std.ArrayList(arena_plan.Binding).empty;
        defer group_bindings.deinit(allocator);
        var group_samples = std.ArrayList([]const quotients.SampleWithRandomness).empty;
        defer group_samples.deinit(allocator);
        for (columns.bindings, columns.samples) |binding, column_samples| {
            if (column_samples.len == 0) continue;
            const word_count = binding.size_bytes / 4;
            if (word_count == 0 or !std.math.isPowerOfTwo(word_count))
                return error.InvalidQuotientInputShape;
            const coefficient_log = std.math.log2_int(u64, word_count);
            if (coefficient_log < 3 or coefficient_log > max_trace_log_size)
                return error.InvalidQuotientInputShape;
            if (coefficient_log != source_log) continue;
            try group_bindings.append(allocator, binding);
            try group_samples.append(allocator, column_samples);
        }
        if (group_bindings.items.len == 0) continue;

        const group_batches = try quotients.ColumnSampleBatch.newVec(allocator, group_samples.items);
        defer quotients.ColumnSampleBatch.deinitSlice(allocator, group_batches);
        if (group_batches.len == 0) continue;
        var group_constants = try quotients.quotientConstants(allocator, group_batches);
        defer group_constants.deinit(allocator);

        const targets = try allocator.alloc(usize, group_batches.len);
        defer allocator.free(targets);
        const tasks = try allocator.alloc(metal_runtime.QuotientCoefficientTask, group_batches.len);
        defer allocator.free(tasks);
        const coefficient_zero_oracles = try allocator.alloc(QM31, group_batches.len);
        defer allocator.free(coefficient_zero_oracles);
        const saved_partials = try allocator.alloc(?SavedPartial, group_batches.len);
        defer {
            for (saved_partials) |*saved| if (saved.*) |*partial| partial.deinit(allocator);
            allocator.free(saved_partials);
        }
        @memset(saved_partials, null);
        const row_starts = try allocator.alloc(u32, group_batches.len + 1);
        defer allocator.free(row_starts);
        row_starts[0] = 0;
        var terms = std.ArrayList(metal_runtime.QuotientCoefficientTerm).empty;
        defer terms.deinit(allocator);
        const row_words_u64 = @as(u64, 1) << @intCast(source_log);
        const row_words = std.math.cast(usize, row_words_u64) orelse
            return error.InvalidQuotientInputShape;

        for (group_batches, group_constants.line_coeffs, 0..) |batch, line_coeffs, batch_index| {
            if (batch.cols_vals_randpows.len == 0 or batch.cols_vals_randpows.len != line_coeffs.len)
                return error.InvalidQuotientInputShape;
            const target = targets_by_point.get(batch.point) orelse return error.InvalidQuotientSampleCount;
            targets[batch_index] = target;
            if (accumulated_logs[target]) |previous_log| {
                if (previous_log >= source_log) return error.InvalidQuotientPartialLogs;
                saved_partials[batch_index] = try SavedPartial.init(
                    allocator,
                    resident_arena,
                    partials,
                    target,
                    previous_log,
                );
            }

            var destinations: [4]u32 = undefined;
            for (0..4) |coordinate| {
                const partial = partials[target * 4 + coordinate];
                if (partial.size_bytes / 4 < row_words_u64 or partial.offset_bytes % 4 != 0)
                    return error.InvalidQuotientInputShape;
                destinations[coordinate] = std.math.cast(u32, partial.offset_bytes / 4) orelse {
                    if (log_stages)
                        std.debug.print("quotient_inputs invalid=destination_offset bytes={}\n", .{partial.offset_bytes});
                    return error.InvalidQuotientInputShape;
                };
            }

            const term_start = terms.items.len;
            var sum_b = QM31.zero();
            var coefficient_zero = QM31.zero();
            for (batch.cols_vals_randpows, line_coeffs) |sample, coeffs| {
                if (sample.column_index >= group_bindings.items.len)
                    return error.InvalidQuotientInputShape;
                const source = group_bindings.items[sample.column_index];
                if (source.offset_bytes % 4 != 0 or source.size_bytes / 4 != row_words_u64)
                    return error.InvalidQuotientInputShape;
                const value_coefficients = coeffs.c.toM31Array();
                try terms.append(allocator, .{
                    .source_word_offset = source.offset_bytes / 4,
                    .source_word_count = std.math.cast(u32, row_words_u64) orelse
                        return error.InvalidQuotientInputShape,
                    .value_coefficients = .{
                        value_coefficients[0].v,
                        value_coefficients[1].v,
                        value_coefficients[2].v,
                        value_coefficients[3].v,
                    },
                });
                source_words_scanned = std.math.add(u64, source_words_scanned, row_words_u64) catch
                    return error.InvalidQuotientInputShape;
                if (log_stages) {
                    const source_words = try bindingWords(resident_arena, source);
                    if (source_words.len == 0 or source_words[0] >= m31_prime)
                        return error.InvalidQuotientInputShape;
                    coefficient_zero = coefficient_zero.add(
                        coeffs.c.mulM31(M31.fromCanonical(source_words[0])),
                    );
                }
                sum_b = sum_b.add(coeffs.b);
            }
            coefficient_zero_oracles[batch_index] = coefficient_zero.sub(sum_b);
            const b = sum_b.toM31Array();
            tasks[batch_index] = .{
                .term_start = std.math.cast(u32, term_start) orelse return error.InvalidQuotientInputShape,
                .term_count = std.math.cast(u32, terms.items.len - term_start) orelse
                    return error.InvalidQuotientInputShape,
                .destination_word_offsets = destinations,
                .row_count = std.math.cast(u32, row_words_u64) orelse
                    return error.InvalidQuotientInputShape,
                .constant_terms = .{ b[0].v, b[1].v, b[2].v, b[3].v },
            };
            row_starts[batch_index + 1] = std.math.add(
                u32,
                row_starts[batch_index],
                std.math.cast(u32, row_words_u64) orelse return error.InvalidQuotientInputShape,
            ) catch return error.InvalidQuotientInputShape;
        }

        gpu_ms += try metal.accumulateQuotientCoefficientsResident(
            resident_arena.buffer,
            terms.items,
            tasks,
            row_starts,
        );
        if (log_stages) for (targets, coefficient_zero_oracles) |target, expected_value| {
            const expected = expected_value.toM31Array();
            for (0..4) |coordinate| {
                const actual = (try bindingWords(resident_arena, partials[target * 4 + coordinate]))[0];
                if (actual != expected[coordinate].v) {
                    std.debug.print(
                        "quotient_inputs mismatch=coefficient_zero log={} target={} coordinate={} expected={} actual={}\n",
                        .{ source_log, target, coordinate, expected[coordinate].v, actual },
                    );
                    return error.QuotientCoefficientParityMismatch;
                }
            }
        };

        var transform_columns = std.ArrayList([]M31).empty;
        defer transform_columns.deinit(allocator);
        for (targets) |target| for (0..4) |coordinate| {
            const destination = try bindingM31(resident_arena, partials[target * 4 + coordinate]);
            if (destination.len < row_words) return error.InvalidQuotientInputShape;
            try transform_columns.append(allocator, destination[0..row_words]);
        };
        var split = try canonic.CanonicCoset.new(source_log + 1).circleDomain().split(allocator, 1);
        defer split.deinit(allocator);
        var split_twiddles = try twiddles.precomputeM31(allocator, split.subdomain.half_coset);
        defer twiddles.deinitM31(allocator, &split_twiddles);
        gpu_ms += try metal.transformCircle(
            allocator,
            transform_columns.items,
            split_twiddles.twiddles,
            source_log,
            false,
        );

        // Rust's lift_and_accumulate uses this bit-reversed evaluation index.
        for (targets, saved_partials) |target, *saved_slot| {
            if (saved_slot.*) |*saved| {
                if (saved.log_size >= source_log) return error.InvalidQuotientPartialLogs;
                for (0..4) |coordinate| {
                    const destination_all = try bindingM31(resident_arena, partials[target * 4 + coordinate]);
                    const destination = destination_all[0..row_words];
                    try liftAndAccumulateEvaluation(destination, saved.coordinates[coordinate]);
                }
            }
            accumulated_logs[target] = source_log;
        }
        if (log_stages)
            std.debug.print(
                "quotient_inputs stage=source_log log={} columns={} batches={} terms={}\n",
                .{ source_log, group_bindings.items.len, group_batches.len, terms.items.len },
            );
    }

    for (accumulated_logs, 0..) |accumulated_log, target| {
        const expected_log = std.math.log2_int(u64, partials[target * 4].size_bytes / 4);
        if (accumulated_log == null or accumulated_log.? != expected_log)
            return error.InvalidQuotientPartialLogs;
    }

    return .{
        .wall_ms = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms,
        .gpu_ms = gpu_ms,
        .sample_count = batches.len,
        .column_count = columns.bindings.len,
        .source_words_scanned = source_words_scanned,
    };
}

/// Validates the immutable quotient-input fixture against already-populated
/// resident inputs. This function never writes to the arena. The fixture is a
/// parity oracle only; malformed, non-canonical, truncated, or trailing data
/// fails closed before the quotient bottom executes.
pub fn validateReferenceFixture(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    bundle: composition_bundle.Bundle,
    partials: []const arena_plan.Binding,
    sample_points: arena_plan.Binding,
    first_linear_terms: arena_plan.Binding,
    subdomain_values: arena_plan.Binding,
    quotient_values: arena_plan.Binding,
    path: []const u8,
) !ReferenceValidation {
    if (partials.len == 0 or partials.len % 4 != 0) return error.InvalidQuotientReference;
    const lifting_log_size = validatedLiftingLogSize(bundle.max_evaluation_log_size) catch
        return error.InvalidQuotientReference;
    const expected_subdomain_log = lifting_log_size - 1;
    const sample_count = partials.len / 4;
    if (sample_points.size_bytes != @as(u64, sample_count) * 8 * 4 or
        first_linear_terms.size_bytes != @as(u64, sample_count) * 4 * 4 or
        subdomain_values.size_bytes == 0 or subdomain_values.size_bytes % 16 != 0 or
        quotient_values.size_bytes == 0 or quotient_values.size_bytes % 16 != 0)
        return error.InvalidQuotientReference;

    const partial_bytes = try allocator.alloc([]const u8, partials.len);
    defer allocator.free(partial_bytes);
    for (partials, partial_bytes) |partial, *bytes| {
        if (partial.size_bytes == 0 or partial.size_bytes % 4 != 0 or
            !std.math.isPowerOfTwo(partial.size_bytes / 4))
            return error.InvalidQuotientReference;
        bytes.* = try resident_arena.bytes(partial);
    }
    const sample_bytes = try resident_arena.bytes(sample_points);
    const linear_bytes = try resident_arena.bytes(first_linear_terms);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var file_reader = file.reader(&buffer);
    const reader = &file_reader.interface;
    const actual_subdomain_log = std.math.log2_int(u64, subdomain_values.size_bytes / 16);
    const actual_quotient_log = std.math.log2_int(u64, quotient_values.size_bytes / 16);
    try validateReferenceLogs(
        expected_subdomain_log,
        lifting_log_size,
        actual_subdomain_log,
        actual_quotient_log,
    );
    return validateReferenceReader(
        allocator,
        reader,
        partial_bytes,
        sample_bytes,
        linear_bytes,
        expected_subdomain_log,
        lifting_log_size,
    );
}

fn validateReferenceLogs(
    expected_subdomain_log: u32,
    expected_quotient_log: u32,
    actual_subdomain_log: u32,
    actual_quotient_log: u32,
) !void {
    if (actual_subdomain_log != expected_subdomain_log or
        actual_quotient_log != expected_quotient_log or
        expected_quotient_log != expected_subdomain_log + 1)
        return error.InvalidQuotientReference;
}

fn validateReferenceReader(
    allocator: std.mem.Allocator,
    reader: anytype,
    partials: []const []const u8,
    sample_points: []const u8,
    first_linear_terms: []const u8,
    expected_subdomain_log: u32,
    expected_quotient_log: u32,
) !ReferenceValidation {
    if (partials.len == 0 or partials.len % 4 != 0) return error.InvalidQuotientReference;
    const sample_count = partials.len / 4;
    const expected_sample_bytes = std.math.mul(usize, sample_count, 8 * 4) catch
        return error.InvalidQuotientReference;
    const expected_linear_bytes = std.math.mul(usize, sample_count, 4 * 4) catch
        return error.InvalidQuotientReference;
    if (sample_count > std.math.maxInt(u32) or
        sample_points.len != expected_sample_bytes or
        first_linear_terms.len != expected_linear_bytes or
        expected_subdomain_log >= 63 or expected_quotient_log >= 63 or
        expected_quotient_log <= expected_subdomain_log)
        return error.InvalidQuotientReference;
    if (!std.mem.eql(u8, try reader.takeArray(8), fixture_magic) or
        try reader.takeInt(u32, .little) != fixture_version or
        try reader.takeInt(u32, .little) != sample_count or
        try reader.takeInt(u32, .little) != expected_subdomain_log or
        try reader.takeInt(u32, .little) != expected_quotient_log)
        return error.InvalidQuotientReference;
    var digest: [32]u8 = undefined;
    try reader.readSliceAll(&digest);

    const populated = try allocator.alloc(bool, sample_count);
    defer allocator.free(populated);
    @memset(populated, false);
    var payload_bytes: u64 = 0;
    for (0..sample_count) |fixture_index| {
        const partial_log = try reader.takeInt(u32, .little);
        if (partial_log > expected_subdomain_log) return error.InvalidQuotientReference;
        const partial_byte_len = try checkedPartialByteLength(partial_log);
        var target: ?usize = null;
        for (0..sample_count) |candidate| {
            if (!populated[candidate] and partials[candidate * 4].len == partial_byte_len) {
                target = candidate;
                break;
            }
        }
        const sample = target orelse return error.InvalidQuotientReference;
        populated[sample] = true;
        compareCanonical(
            reader,
            sample_points[sample * 8 * 4 ..][0 .. 8 * 4],
            &payload_bytes,
        ) catch |err| {
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
                std.debug.print("quotient_reference mismatch=sample_point fixture_index={} target={} log={}\n", .{ fixture_index, sample, partial_log });
            return err;
        };
        compareCanonical(
            reader,
            first_linear_terms[sample * 4 * 4 ..][0 .. 4 * 4],
            &payload_bytes,
        ) catch |err| {
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
                std.debug.print("quotient_reference mismatch=linear_term fixture_index={} target={} log={}\n", .{ fixture_index, sample, partial_log });
            return err;
        };
        for (0..4) |coordinate| {
            const partial = partials[sample * 4 + coordinate];
            if (partial.len != partial_byte_len) return error.InvalidQuotientReference;
            compareCanonical(reader, partial, &payload_bytes) catch |err| {
                if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
                    std.debug.print(
                        "quotient_reference mismatch=partial fixture_index={} target={} log={} coordinate={}\n",
                        .{ fixture_index, sample, partial_log, coordinate },
                    );
                return err;
            };
        }
    }
    for (populated) |value| if (!value) return error.InvalidQuotientReference;
    var trailing: [1]u8 = undefined;
    if (try reader.readSliceShort(&trailing) != 0) return error.InvalidQuotientReference;
    return .{ .quotient_digest = digest, .payload_bytes = payload_bytes };
}

fn compareCanonical(reader: anytype, actual: []const u8, total: *u64) !void {
    if (actual.len % 4 != 0) return error.InvalidQuotientReference;
    var scratch: [64 * 1024]u8 align(4) = undefined;
    var cursor: usize = 0;
    while (cursor < actual.len) {
        const len = @min(scratch.len, actual.len - cursor);
        const expected = scratch[0..len];
        try reader.readSliceAll(expected);
        try canonicalWords(std.mem.bytesAsSlice(u32, expected));
        if (!std.mem.eql(u8, expected, actual[cursor .. cursor + len])) {
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
                const expected_words = std.mem.bytesAsSlice(u32, expected);
                const actual_bytes: []align(4) const u8 = @alignCast(actual[cursor .. cursor + len]);
                const actual_words = std.mem.bytesAsSlice(u32, actual_bytes);
                var mismatch: usize = 0;
                while (mismatch < expected_words.len and expected_words[mismatch] == actual_words[mismatch]) : (mismatch += 1) {}
                std.debug.print(
                    "quotient_reference first_word={} expected={} actual={} chunk_word_count={}\n",
                    .{ cursor / 4 + mismatch, expected_words[mismatch], actual_words[mismatch], expected_words.len },
                );
            }
            return error.QuotientReferenceMismatch;
        }
        cursor += len;
        total.* = std.math.add(u64, total.*, len) catch return error.InvalidQuotientReference;
    }
}

fn checkedPartialByteLength(log_size: u32) !usize {
    if (log_size >= @bitSizeOf(usize) - 2) return error.InvalidQuotientReference;
    return @as(usize, 1) << @intCast(log_size + 2);
}

fn canonicalWords(words: []const u32) !void {
    for (words) |word| if (word >= m31_prime) return error.NonCanonicalQuotientReference;
}

const SliceReader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn takeArray(self: *SliceReader, count: usize) ![]const u8 {
        const end = std.math.add(usize, self.cursor, count) catch return error.EndOfStream;
        if (end > self.bytes.len) return error.EndOfStream;
        defer self.cursor = end;
        return self.bytes[self.cursor..end];
    }

    fn takeInt(self: *SliceReader, comptime T: type, endian: std.builtin.Endian) !T {
        const bytes = try self.takeArray(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
    }

    fn readSliceAll(self: *SliceReader, destination: []u8) !void {
        @memcpy(destination, try self.takeArray(destination.len));
    }

    fn readSliceShort(self: *SliceReader, destination: []u8) !usize {
        const count = @min(destination.len, self.bytes.len - self.cursor);
        @memcpy(destination[0..count], self.bytes[self.cursor .. self.cursor + count]);
        self.cursor += count;
        return count;
    }
};

fn deriveMasks(
    allocator: std.mem.Allocator,
    bundle: composition_bundle.Bundle,
    preprocessed_count: usize,
    base_count: usize,
    interaction_count: usize,
) !Masks {
    const preprocessed_used = try allocator.alloc(bool, preprocessed_count);
    errdefer allocator.free(preprocessed_used);
    @memset(preprocessed_used, false);
    const base_offsets = try allocateOffsetLists(allocator, base_count);
    errdefer freeOffsetLists(allocator, base_offsets);
    const interaction_offsets = try allocateOffsetLists(allocator, interaction_count);
    errdefer freeOffsetLists(allocator, interaction_offsets);

    for (bundle.components) |component| {
        const base_span = try componentSpan(component, 1, base_count);
        const interaction_span = try componentSpan(component, 2, interaction_count);
        for (component.parts) |part| for (part.program.base_insts) |instruction| switch (instruction.op) {
            .preprocessed_col => {
                if (instruction.a >= component.preprocessed_indices.len) return error.InvalidQuotientMask;
                const column = component.preprocessed_indices[instruction.a];
                if (column >= preprocessed_used.len) return error.InvalidQuotientMask;
                preprocessed_used[column] = true;
            },
            .trace_col => switch (instruction.interaction) {
                0 => {
                    if (instruction.a >= component.preprocessed_indices.len) return error.InvalidQuotientMask;
                    const column = component.preprocessed_indices[instruction.a];
                    if (column >= preprocessed_used.len) return error.InvalidQuotientMask;
                    preprocessed_used[column] = true;
                },
                1 => try appendUnique(
                    allocator,
                    &base_offsets[base_span.start + instruction.a],
                    instruction.imm,
                    base_span,
                    instruction.a,
                ),
                2 => try appendUnique(
                    allocator,
                    &interaction_offsets[interaction_span.start + instruction.a],
                    instruction.imm,
                    interaction_span,
                    instruction.a,
                ),
                else => return error.InvalidQuotientMask,
            },
            else => {},
        };
    }
    return .{
        .allocator = allocator,
        .preprocessed_used = preprocessed_used,
        .base_offsets = base_offsets,
        .interaction_offsets = interaction_offsets,
    };
}

fn buildColumns(
    allocator: std.mem.Allocator,
    preprocessed: []const arena_plan.Binding,
    base: []const arena_plan.Binding,
    interaction: []const arena_plan.Binding,
    composition: []const arena_plan.Binding,
    masks: Masks,
    oods_point: circle.CirclePointQM31,
    sampled_words: []const u32,
    random_coeff: QM31,
    lifting_log_size: u32,
    max_trace_log_size: u32,
) !OwnedColumns {
    var bindings = std.ArrayList(arena_plan.Binding).empty;
    defer bindings.deinit(allocator);
    var ranges = std.ArrayList(SampleRange).empty;
    defer ranges.deinit(allocator);
    var flat_samples = std.ArrayList(quotients.SampleWithRandomness).empty;
    defer flat_samples.deinit(allocator);
    var value_cursor: usize = 0;
    var random_pow = QM31.one();
    const trace_step_m31 = canonic.CanonicCoset.new(max_trace_log_size).step();
    const trace_step = pointM31IntoQM31(trace_step_m31);
    const lifting_generator = canonic.CanonicCoset.new(lifting_log_size).step();

    for (preprocessed, masks.preprocessed_used) |binding, used| {
        var points: [1]circle.CirclePointQM31 = .{oods_point};
        try appendColumn(
            allocator,
            &bindings,
            &ranges,
            &flat_samples,
            binding,
            if (used) &points else &.{},
            sampled_words,
            &value_cursor,
            &random_pow,
            random_coeff,
            lifting_generator,
            lifting_log_size,
        );
    }
    for (base, masks.base_offsets) |binding, offsets| {
        if (offsets.items.len == 0 or offsets.items.len > 2) return error.InvalidQuotientMask;
        var points: [2]circle.CirclePointQM31 = undefined;
        for (offsets.items, 0..) |offset, index| points[index] = oods_point.add(trace_step.mulSigned(offset));
        try appendColumn(
            allocator,
            &bindings,
            &ranges,
            &flat_samples,
            binding,
            points[0..offsets.items.len],
            sampled_words,
            &value_cursor,
            &random_pow,
            random_coeff,
            lifting_generator,
            lifting_log_size,
        );
    }
    for (interaction, masks.interaction_offsets) |binding, offsets| {
        if (offsets.items.len == 0 or offsets.items.len > 2) return error.InvalidQuotientMask;
        var points: [2]circle.CirclePointQM31 = undefined;
        for (offsets.items, 0..) |offset, index| points[index] = oods_point.add(trace_step.mulSigned(offset));
        try appendColumn(
            allocator,
            &bindings,
            &ranges,
            &flat_samples,
            binding,
            points[0..offsets.items.len],
            sampled_words,
            &value_cursor,
            &random_pow,
            random_coeff,
            lifting_generator,
            lifting_log_size,
        );
    }
    for (composition) |binding| {
        var points: [1]circle.CirclePointQM31 = .{oods_point};
        try appendColumn(
            allocator,
            &bindings,
            &ranges,
            &flat_samples,
            binding,
            &points,
            sampled_words,
            &value_cursor,
            &random_pow,
            random_coeff,
            lifting_generator,
            lifting_log_size,
        );
    }
    if (value_cursor * 4 != sampled_words.len) return error.InvalidQuotientSampleCount;

    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    const owned_samples = try flat_samples.toOwnedSlice(allocator);
    errdefer allocator.free(owned_samples);
    const views = try allocator.alloc([]const quotients.SampleWithRandomness, ranges.items.len);
    for (ranges.items, views) |range, *view| view.* = owned_samples[range.start .. range.start + range.len];
    return .{
        .allocator = allocator,
        .bindings = owned_bindings,
        .flat_samples = owned_samples,
        .samples = views,
    };
}

fn appendColumn(
    allocator: std.mem.Allocator,
    bindings: *std.ArrayList(arena_plan.Binding),
    ranges: *std.ArrayList(SampleRange),
    flat_samples: *std.ArrayList(quotients.SampleWithRandomness),
    binding: arena_plan.Binding,
    points: []const circle.CirclePointQM31,
    sampled_words: []const u32,
    value_cursor: *usize,
    random_pow: *QM31,
    random_coeff: QM31,
    lifting_generator: circle.CirclePointM31,
    lifting_log_size: u32,
) !void {
    if (binding.size_bytes == 0 or binding.size_bytes % 4 != 0 or
        !std.math.isPowerOfTwo(binding.size_bytes / 4) or points.len > 2)
        return error.InvalidQuotientInputShape;
    const coefficient_log_size: u32 = std.math.log2_int(u64, binding.size_bytes / 4);
    // Tree 0 contains preprocessed columns larger than the FRI lifting domain.
    // They are valid here when the AIR mask does not sample them: upstream keeps
    // those columns in the tree shape but produces no quotient contribution.
    if (points.len != 0 and coefficient_log_size >= lifting_log_size)
        return error.InvalidQuotientInputShape;
    const column_log_size = coefficient_log_size + 1;
    const start = flat_samples.items.len;
    var values: [2]QM31 = undefined;
    for (points, 0..) |_, index| {
        const word_start = (value_cursor.* + index) * 4;
        if (word_start + 4 > sampled_words.len) return error.InvalidQuotientSampleCount;
        values[index] = secureFromWords(sampled_words[word_start .. word_start + 4]);
    }
    if (points.len == 2) {
        const periodic_point = points[1].add(
            pointM31IntoQM31(lifting_generator.repeatedDouble(column_log_size)),
        );
        try flat_samples.append(allocator, .{
            .point = periodic_point,
            .value = values[1],
            .random_coeff = nextRandomPower(random_pow, random_coeff),
        });
    }
    for (points, values[0..points.len]) |point, value| try flat_samples.append(allocator, .{
        .point = point,
        .value = value,
        .random_coeff = nextRandomPower(random_pow, random_coeff),
    });
    value_cursor.* += points.len;
    try bindings.append(allocator, binding);
    try ranges.append(allocator, .{ .start = start, .len = flat_samples.items.len - start });
}

fn validatedLiftingLogSize(lifting_log_size: u32) !u32 {
    if (lifting_log_size <= 3 or lifting_log_size > circle.M31_CIRCLE_LOG_ORDER)
        return error.InvalidQuotientInputShape;
    return lifting_log_size;
}

fn componentSpan(component: composition_bundle.Component, tree: u32, tree_len: usize) !Span {
    var found: ?Span = null;
    for (component.trace_spans) |span| {
        if (span.tree != tree) continue;
        if (found != null or span.start > span.end or span.end > tree_len) return error.InvalidQuotientMask;
        found = .{ .start = span.start, .end = span.end };
    }
    return found orelse error.InvalidQuotientMask;
}

fn allocateOffsetLists(allocator: std.mem.Allocator, count: usize) ![]std.ArrayList(i32) {
    const lists = try allocator.alloc(std.ArrayList(i32), count);
    for (lists) |*list| list.* = .empty;
    return lists;
}

fn freeOffsetLists(allocator: std.mem.Allocator, lists: []std.ArrayList(i32)) void {
    for (lists) |*list| list.deinit(allocator);
    allocator.free(lists);
}

fn appendUnique(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(i32),
    offset: i32,
    span: Span,
    local_column: u32,
) !void {
    if (local_column >= span.end - span.start) return error.InvalidQuotientMask;
    for (list.items) |existing| if (existing == offset) return;
    try list.append(allocator, offset);
}

fn bindingWords(resident_arena: *arena_plan.ResidentArena, binding: arena_plan.Binding) ![]align(4) u32 {
    const bytes: []align(4) u8 = @alignCast(try resident_arena.bytes(binding));
    if (bytes.len % 4 != 0 or binding.offset_bytes % 4 != 0) return error.InvalidQuotientInputShape;
    return std.mem.bytesAsSlice(u32, bytes);
}

fn bindingM31(resident_arena: *arena_plan.ResidentArena, binding: arena_plan.Binding) ![]M31 {
    const words = try bindingWords(resident_arena, binding);
    return std.mem.bytesAsSlice(M31, std.mem.sliceAsBytes(words));
}

fn secureFromWords(words: []const u32) QM31 {
    std.debug.assert(words.len == 4);
    return QM31.fromU32Unchecked(words[0], words[1], words[2], words[3]);
}

fn nextRandomPower(power: *QM31, random_coeff: QM31) QM31 {
    const result = power.*;
    power.* = power.mul(random_coeff);
    return result;
}

fn pointFromParameter(parameter: QM31) !circle.CirclePointQM31 {
    const square = parameter.square();
    const inverse = square.add(QM31.one()).inv() catch return error.InvalidOodsPoint;
    return .{
        .x = QM31.one().sub(square).mul(inverse),
        .y = parameter.add(parameter).mul(inverse),
    };
}

fn pointM31IntoQM31(point: circle.CirclePointM31) circle.CirclePointQM31 {
    return .{ .x = QM31.fromBase(point.x), .y = QM31.fromBase(point.y) };
}

fn pointLessThan(lhs: circle.CirclePointQM31, rhs: circle.CirclePointQM31) bool {
    const lhs_words = lhs.x.toM31Array() ++ lhs.y.toM31Array();
    const rhs_words = rhs.x.toM31Array() ++ rhs.y.toM31Array();
    for (lhs_words, rhs_words) |lhs_word, rhs_word| {
        if (lhs_word.v != rhs_word.v) return lhs_word.v < rhs_word.v;
    }
    return false;
}

test "metal: quotient evaluation lift matches Rust bit-reversed indexing" {
    const previous = [_]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(2),
    };
    var destination = [_]M31{
        M31.fromCanonical(10),
        M31.fromCanonical(11),
        M31.fromCanonical(12),
        M31.fromCanonical(13),
        M31.fromCanonical(14),
        M31.fromCanonical(15),
        M31.fromCanonical(16),
        M31.fromCanonical(17),
    };
    const expected = [_]u32{ 11, 13, 13, 15, 15, 17, 17, 19 };

    try liftAndAccumulateEvaluation(&destination, &previous);
    for (destination, expected) |actual, expected_word|
        try std.testing.expectEqual(expected_word, actual.v);
}

test "metal: unsampled preprocessed columns may exceed the FRI lifting domain" {
    const allocator = std.testing.allocator;
    const lifting_log_size: u32 = 24;
    var bindings = std.ArrayList(arena_plan.Binding).empty;
    defer bindings.deinit(allocator);
    var ranges = std.ArrayList(SampleRange).empty;
    defer ranges.deinit(allocator);
    var samples = std.ArrayList(quotients.SampleWithRandomness).empty;
    defer samples.deinit(allocator);
    var value_cursor: usize = 0;
    var random_pow = QM31.one();
    const binding = arena_plan.Binding{
        .logical_id = 1,
        .slot = 0,
        .offset_bytes = 0,
        .size_bytes = @as(u64, 4) << 25,
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };

    try appendColumn(
        allocator,
        &bindings,
        &ranges,
        &samples,
        binding,
        &.{},
        &.{},
        &value_cursor,
        &random_pow,
        QM31.one(),
        canonic.CanonicCoset.new(lifting_log_size).step(),
        lifting_log_size,
    );

    try std.testing.expectEqual(@as(usize, 1), bindings.items.len);
    try std.testing.expectEqual(@as(usize, 1), ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), ranges.items[0].len);
    try std.testing.expectEqual(@as(usize, 0), samples.items.len);
    try std.testing.expectEqual(@as(usize, 0), value_cursor);
}

test "metal: SN2 quotient mask has 19 sample batches with the reference partial logs" {
    @setEvalBranchQuota(10_000);
    var bundle = try composition_bundle.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer bundle.deinit();
    const lifting_log_size = try validatedLiftingLogSize(bundle.max_evaluation_log_size);
    const max_trace_log_size = lifting_log_size - 1;
    var masks = try deriveMasks(std.testing.allocator, bundle, 161, 3449, 2268);
    defer masks.deinit();

    var oods_count: usize = 8;
    for (masks.preprocessed_used) |used| oods_count += @intFromBool(used);
    for (masks.base_offsets) |offsets| oods_count += offsets.items.len;
    for (masks.interaction_offsets) |offsets| oods_count += offsets.items.len;
    try std.testing.expectEqual(@as(usize, 6110), oods_count);

    const base_logs = try traceLogs(std.testing.allocator, bundle, 1, masks.base_offsets.len);
    defer std.testing.allocator.free(base_logs);
    const interaction_logs = try traceLogs(std.testing.allocator, bundle, 2, masks.interaction_offsets.len);
    defer std.testing.allocator.free(interaction_logs);
    const parameter = QM31.fromU32Unchecked(846579577, 1914966500, 886709583, 1440664798);
    const oods_point = try pointFromParameter(parameter);
    const trace_step = pointM31IntoQM31(canonic.CanonicCoset.new(max_trace_log_size).step());
    const lifting_generator = canonic.CanonicCoset.new(lifting_log_size).step();
    var logs_by_point = std.AutoHashMap(circle.CirclePointQM31, u32).init(std.testing.allocator);
    defer logs_by_point.deinit();
    try updatePointLog(&logs_by_point, oods_point, max_trace_log_size);
    for (masks.base_offsets, base_logs) |offsets, log_size| {
        for (offsets.items) |offset| try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offset)),
            log_size,
        );
        if (offsets.items.len == 2) try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offsets.items[1])).add(
                pointM31IntoQM31(lifting_generator.repeatedDouble(log_size + 1)),
            ),
            log_size,
        );
    }
    for (masks.interaction_offsets, interaction_logs) |offsets, log_size| {
        for (offsets.items) |offset| try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offset)),
            log_size,
        );
        if (offsets.items.len == 2) try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offsets.items[1])).add(
                pointM31IntoQM31(lifting_generator.repeatedDouble(log_size + 1)),
            ),
            log_size,
        );
    }
    var found_logs = try std.testing.allocator.alloc(u32, logs_by_point.count());
    defer std.testing.allocator.free(found_logs);
    var iterator = logs_by_point.valueIterator();
    var index: usize = 0;
    while (iterator.next()) |log_size| : (index += 1) found_logs[index] = log_size.*;
    std.mem.sort(u32, found_logs, {}, std.sort.asc(u32));
    const expected = [_]u32{ 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 23, 23 };
    try std.testing.expectEqualSlices(u32, &expected, found_logs);

    const reference_points = [_][9]u32{
        .{ 14, 445372541, 1092951465, 1937492379, 1741050069, 121692003, 1608055819, 1454547682, 1593254727 },
        .{ 4, 484424958, 59829562, 256131572, 1338900763, 900826934, 1604527622, 108623509, 526566284 },
        .{ 21, 525035803, 1088825149, 323592314, 192277391, 1058980337, 1019540402, 1169599338, 638809582 },
        .{ 6, 767508393, 2115198925, 1843087753, 2025960515, 751518033, 1141333622, 1947451246, 421367053 },
        .{ 15, 779763653, 1636038482, 192064866, 527045910, 196438127, 1298266339, 1660792984, 1380706413 },
        .{ 13, 974335912, 1795692920, 1772739649, 565152841, 1859874711, 577277296, 2096796993, 1804450951 },
        .{ 12, 1062229442, 1534487438, 417657836, 1813561061, 914272876, 1566962871, 1617148800, 503065456 },
        .{ 23, 1088503310, 1127943245, 977884309, 1508674065, 525035803, 1088825149, 323592314, 192277391 },
        .{ 8, 1147498412, 1682502947, 604657200, 1934484738, 748490768, 683428971, 1237496906, 501711744 },
        .{ 10, 1186089343, 1858683932, 1377241751, 450379047, 569783259, 43759836, 1092348743, 124278569 },
        .{ 16, 1257102701, 1252171081, 1925056363, 1723107290, 2046002179, 784376680, 826551315, 280272916 },
        .{ 20, 1402265644, 432374817, 2055720338, 986735970, 361127530, 225967531, 636639488, 817803657 },
        .{ 18, 1492953197, 1087151664, 1115585517, 1137606051, 555855364, 1753831263, 763591256, 1744387696 },
        .{ 11, 1549526234, 1184890108, 1723548676, 144693332, 2130289263, 331389383, 400976595, 445526442 },
        .{ 19, 1615873698, 2128601643, 415723873, 1776882859, 1609276372, 643677304, 2070842543, 438095759 },
        .{ 17, 1863123986, 1607251448, 1434703069, 1731883500, 970243058, 1030755838, 253489516, 645254088 },
        .{ 9, 1977806255, 2147059310, 1300592184, 1048430120, 1746574005, 1138685808, 171335228, 437360123 },
        .{ 7, 2045635317, 1095316091, 1249771119, 677632478, 1784052439, 1242092662, 1337741234, 1650121225 },
        .{ 23, 2100911427, 2110974293, 1566596213, 79180041, 592238137, 1137599031, 141723729, 555328319 },
    };
    for (reference_points) |entry| {
        const point = circle.CirclePointQM31{
            .x = secureFromWords(entry[1..5]),
            .y = secureFromWords(entry[5..9]),
        };
        try std.testing.expectEqual(entry[0], logs_by_point.get(point) orelse return error.MissingReferencePoint);
    }
}

test "metal: quotient protocol and reference geometry supports lifting logs 24 and 25" {
    try std.testing.expectEqual(@as(u32, 24), try validatedLiftingLogSize(24));
    try std.testing.expectEqual(@as(u32, 25), try validatedLiftingLogSize(25));
    try validateReferenceLogs(23, 24, 23, 24);
    try validateReferenceLogs(24, 25, 24, 25);
    try std.testing.expectError(
        error.InvalidQuotientReference,
        validateReferenceLogs(24, 25, 23, 24),
    );
    try std.testing.expectError(error.InvalidQuotientInputShape, validatedLiftingLogSize(3));
}

test "metal: quotient reference fixture validates without restoring resident inputs" {
    const allocator = std.testing.allocator;
    const sample_words = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const linear_words = [_]u32{ 21, 22, 23, 24, 25, 26, 27, 28 };
    const p00 = [_]u32{ 31, 32, 33, 34 };
    const p01 = [_]u32{ 35, 36, 37, 38 };
    const p02 = [_]u32{ 39, 40, 41, 42 };
    const p03 = [_]u32{ 43, 44, 45, 46 };
    const p10 = [_]u32{ 51, 52 };
    const p11 = [_]u32{ 53, 54 };
    const p12 = [_]u32{ 55, 56 };
    const p13 = [_]u32{ 57, 58 };
    const partials = [_][]const u8{
        std.mem.sliceAsBytes(p00[0..]),
        std.mem.sliceAsBytes(p01[0..]),
        std.mem.sliceAsBytes(p02[0..]),
        std.mem.sliceAsBytes(p03[0..]),
        std.mem.sliceAsBytes(p10[0..]),
        std.mem.sliceAsBytes(p11[0..]),
        std.mem.sliceAsBytes(p12[0..]),
        std.mem.sliceAsBytes(p13[0..]),
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);
    const writer = encoded.writer(allocator);
    try writer.writeAll(fixture_magic);
    try writer.writeInt(u32, fixture_version, .little);
    try writer.writeInt(u32, 2, .little);
    try writer.writeInt(u32, 3, .little);
    try writer.writeInt(u32, 4, .little);
    try writer.writeAll(&[_]u8{0xa5} ** 32);
    try writer.writeInt(u32, 2, .little);
    try writer.writeAll(std.mem.sliceAsBytes(sample_words[0..8]));
    try writer.writeAll(std.mem.sliceAsBytes(linear_words[0..4]));
    for (partials[0..4]) |partial| try writer.writeAll(partial);
    try writer.writeInt(u32, 1, .little);
    try writer.writeAll(std.mem.sliceAsBytes(sample_words[8..16]));
    try writer.writeAll(std.mem.sliceAsBytes(linear_words[4..8]));
    for (partials[4..8]) |partial| try writer.writeAll(partial);

    var reader = SliceReader{ .bytes = encoded.items };
    const validation = try validateReferenceReader(
        allocator,
        &reader,
        &partials,
        std.mem.sliceAsBytes(sample_words[0..]),
        std.mem.sliceAsBytes(linear_words[0..]),
        3,
        4,
    );
    try std.testing.expectEqual(@as(u64, 192), validation.payload_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa5} ** 32, &validation.quotient_digest);

    const mutated = try allocator.dupe(u8, encoded.items);
    defer allocator.free(mutated);
    std.mem.writeInt(u32, mutated[60..64], 99, .little);
    reader = .{ .bytes = mutated };
    try std.testing.expectError(
        error.QuotientReferenceMismatch,
        validateReferenceReader(
            allocator,
            &reader,
            &partials,
            std.mem.sliceAsBytes(sample_words[0..]),
            std.mem.sliceAsBytes(linear_words[0..]),
            3,
            4,
        ),
    );
    std.mem.writeInt(u32, mutated[60..64], m31_prime, .little);
    reader = .{ .bytes = mutated };
    try std.testing.expectError(
        error.NonCanonicalQuotientReference,
        validateReferenceReader(
            allocator,
            &reader,
            &partials,
            std.mem.sliceAsBytes(sample_words[0..]),
            std.mem.sliceAsBytes(linear_words[0..]),
            3,
            4,
        ),
    );
    std.mem.writeInt(u32, mutated[56..60], 63, .little);
    reader = .{ .bytes = mutated };
    try std.testing.expectError(
        error.InvalidQuotientReference,
        validateReferenceReader(
            allocator,
            &reader,
            &partials,
            std.mem.sliceAsBytes(sample_words[0..]),
            std.mem.sliceAsBytes(linear_words[0..]),
            3,
            4,
        ),
    );
}

fn traceLogs(
    allocator: std.mem.Allocator,
    bundle: composition_bundle.Bundle,
    tree: u32,
    count: usize,
) ![]u32 {
    const logs = try allocator.alloc(u32, count);
    errdefer allocator.free(logs);
    @memset(logs, 0);
    for (bundle.components) |component| {
        const span = try componentSpan(component, tree, count);
        for (logs[span.start..span.end]) |*log_size| {
            if (log_size.* != 0) return error.InvalidQuotientMask;
            log_size.* = component.trace_log_size;
        }
    }
    for (logs) |log_size| if (log_size == 0) return error.InvalidQuotientMask;
    return logs;
}

fn updatePointLog(
    logs: *std.AutoHashMap(circle.CirclePointQM31, u32),
    point: circle.CirclePointQM31,
    log_size: u32,
) !void {
    const entry = try logs.getOrPut(point);
    if (!entry.found_existing) entry.value_ptr.* = log_size else entry.value_ptr.* = @max(entry.value_ptr.*, log_size);
}
