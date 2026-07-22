//! SIMD- and row-parallel secure-composition evaluation for admitted CPU AIRs.

const std = @import("std");
const constraints = @import("stwo_core").constraints;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const canonic = @import("stwo_core").poly.circle.canonic;
const prover = @import("stwo_prover_impl");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const PackedM31 = m31.PackedM31;
const ComponentProver = prover.air.component_prover.ComponentProver;
const Trace = prover.air.component_prover.Trace;
const SecureColumnByCoords = prover.secure_column.SecureColumnByCoords;

// Keep short/small proofs on the reference loop: their fan-out cost is a
// meaningful fraction of the whole request. This admits trace logs >= 16.
const min_eval_log_size: u32 = 17;
const validation_unknown: u8 = 0;
const validation_accepted: u8 = 1;
const validation_rejected: u8 = 2;
var validation_mutex: std.Thread.Mutex = .{};
var validation_vtable: ?*const prover.air.component_prover.ComponentProverVTable = null;
var recurrence_validation: u8 = validation_unknown;

pub fn install() void {
    prover.air.component_prover.installCompositionValidationJoin(joinPendingValidation);
    prover.air.component_prover.installBackendCompositionEvaluationHook(
        evaluateLargeRecurrenceComposition,
    );
}

const RecurrenceShape = struct {
    first_column: [*]const M31,
    row_count: usize,
    column_count: usize,
    column_stride: usize,
    constraint_count: usize,
    eval_log_size: u32,
};

const PackedPower = struct {
    coordinates: [qm31.SECURE_EXTENSION_DEGREE]PackedM31,
};

const Worker = struct {
    first_column: [*]const M31,
    outputs: [qm31.SECURE_EXTENSION_DEGREE][*]M31,
    powers: []const PackedPower,
    denominator_inverses: [2]PackedM31,
    row_count: usize,
    column_count: usize,
    column_stride: usize,
    row_start: usize,
    row_end: usize,

    fn run(self: *Worker) void {
        const half = self.row_count / 2;
        var row = self.row_start;
        while (row < self.row_end) : (row += m31.PACK_WIDTH) {
            var a = m31.loadPacked(self.first_column + row);
            var b = m31.loadPacked(self.first_column + self.column_stride + row);
            var a_squared = m31.mulPacked(a, a);
            var b_squared = m31.mulPacked(b, b);
            var accumulators: [qm31.SECURE_EXTENSION_DEGREE]PackedM31 = .{
                @splat(0), @splat(0), @splat(0), @splat(0),
            };

            var column: usize = 2;
            while (column < self.column_count) : (column += 1) {
                const c = m31.loadPacked(self.first_column + column * self.column_stride + row);
                const expected = m31.addPacked(a_squared, b_squared);
                const recurrence = m31.subPacked(c, expected);
                const power = self.powers[self.column_count - 1 - column];
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                    accumulators[coordinate] = m31.addPacked(
                        accumulators[coordinate],
                        m31.mulPacked(recurrence, power.coordinates[coordinate]),
                    );
                }
                a = b;
                b = c;
                a_squared = b_squared;
                if (column + 1 < self.column_count) b_squared = m31.mulPacked(c, c);
            }

            const denominator = self.denominator_inverses[@intFromBool(row >= half)];
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                m31.storePacked(
                    self.outputs[coordinate] + row,
                    m31.mulPacked(accumulators[coordinate], denominator),
                );
            }
        }
    }
};

fn evaluateLargeRecurrenceComposition(
    allocator: std.mem.Allocator,
    components: []const ComponentProver,
    random_coeff: QM31,
    trace: *const Trace,
) !?SecureColumnByCoords {
    // A previous prove's deferred validation must fully settle before any
    // decision here reads the tri-state.
    _ = joinPendingValidation();
    const shape = recurrenceShape(components, trace) orelse return null;
    if (validationStatus(components[0].vtable) == validation_rejected) return null;

    const powers = try prover.air.accumulation.generateSecurePowers(
        allocator,
        random_coeff,
        shape.constraint_count,
    );
    defer allocator.free(powers);
    const packed_powers = try allocator.alloc(PackedPower, powers.len);
    defer allocator.free(packed_powers);
    for (powers, packed_powers) |power, *packed_power| {
        const coordinates = power.toM31Array();
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            packed_power.coordinates[coordinate] = m31.splatPacked(coordinates[coordinate]);
        }
    }

    const eval_domain = canonic.CanonicCoset.new(shape.eval_log_size).circleDomain();
    const trace_coset = canonic.CanonicCoset.new(shape.eval_log_size - 1).coset();
    const denominator_scalars = [2]M31{
        try constraints.cosetVanishing(M31, trace_coset, eval_domain.at(0)).inv(),
        try constraints.cosetVanishing(M31, trace_coset, eval_domain.at(1)).inv(),
    };
    const denominators = [2]PackedM31{
        m31.splatPacked(denominator_scalars[0]),
        m31.splatPacked(denominator_scalars[1]),
    };

    var output = try SecureColumnByCoords.uninitialized(allocator, shape.row_count);
    errdefer output.deinit(allocator);
    var output_pointers: [qm31.SECURE_EXTENSION_DEGREE][*]M31 = undefined;
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        output_pointers[coordinate] = output.columns[coordinate].ptr;
    }

    const pool = prover.work_pool.getGlobalPool();
    const requested_workers = if (pool) |active| active.workerCount() else 1;
    const packed_rows = shape.row_count / m31.PACK_WIDTH;
    const worker_count = @min(requested_workers, packed_rows);
    const workers = try allocator.alloc(Worker, worker_count);
    defer allocator.free(workers);
    for (workers, 0..) |*worker, index| {
        const start_batch = packed_rows * index / worker_count;
        const end_batch = packed_rows * (index + 1) / worker_count;
        worker.* = .{
            .first_column = shape.first_column,
            .outputs = output_pointers,
            .powers = packed_powers,
            .denominator_inverses = denominators,
            .row_count = shape.row_count,
            .column_count = shape.column_count,
            .column_stride = shape.column_stride,
            .row_start = start_batch * m31.PACK_WIDTH,
            .row_end = end_batch * m31.PACK_WIDTH,
        };
    }

    if (pool) |active| {
        var wait_group = std.Thread.WaitGroup{};
        for (workers[1..]) |*worker| active.spawnWg(&wait_group, Worker.run, .{worker});
        Worker.run(&workers[0]);
        wait_group.wait();
    } else {
        Worker.run(&workers[0]);
    }

    if (validationStatus(components[0].vtable) == validation_accepted) return output;

    // Deferred-overlap validation (design ruling 07-23): the byte-identical
    // serial reference still checks EVERY row of the first prove, but runs
    // on a dedicated thread overlapped with the prove's post-composition
    // stages. prove() joins before any proof is returned. The fast output
    // is committed to a digest here (RSS rider: 32 bytes retained, never a
    // column copy); the worker compares the reference digest against it.
    // On mismatch the join reports it, the tri-state latches rejected, and
    // the driver re-proves on the safe path — deferred validation can
    // still only reject, never accept a wrong column.
    const fast_digest = digestSecureColumn(output);
    spawnDeferredValidation(allocator, components, random_coeff, trace, fast_digest) catch {
        // Spawn failure: fall back to the original synchronous check.
        var expected = try referenceComposition(allocator, components, random_coeff, trace);
        if (!secureColumnsEqual(output, expected)) {
            setValidationStatus(components[0].vtable, validation_rejected);
            output.deinit(allocator);
            return expected;
        }
        expected.deinit(allocator);
        setValidationStatus(components[0].vtable, validation_accepted);
        return output;
    };
    return output;
}

const Blake2s256 = std.crypto.hash.blake2.Blake2s256;

fn digestSecureColumn(column: SecureColumnByCoords) [Blake2s256.digest_length]u8 {
    var hasher = Blake2s256.init(.{});
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        hasher.update(std.mem.sliceAsBytes(column.columns[coordinate]));
    }
    var digest: [Blake2s256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const JoinVerdict = prover.air.component_prover.JoinVerdict;

const PendingValidation = struct {
    thread: std.Thread,
    verdict: JoinVerdict = .none,
};

var pending_mutex: std.Thread.Mutex = .{};
var pending_validation: ?*PendingValidation = null;
var pending_allocator: std.mem.Allocator = undefined;

const Poly = prover.air.component_prover.Poly;

/// Deferred-validation context (values-steal, ruling 2 07-23). We STEAL the
/// trace's Poly value slices — the referee owns and frees them on join, and
/// empty slices are swapped into the live trace so prove.zig's block-scoped
/// `deinitDeep` frees only empty shells + the (unneeded, unread-downstream)
/// coefficients. Zero copy, zero RSS delta. Sound because: (a) `trace` is
/// block-scoped in prove.zig with no post-composition reader of its VALUES
/// (verified by scope + the digest-identical A/B); (b) the underlying local
/// is `var trace`, so the one @constCast to swap the slices is legal.
const DeferredCtx = struct {
    allocator: std.mem.Allocator,
    components: []const ComponentProver,
    random_coeff: QM31,
    stolen_values: [][]const M31, // freed by the referee on join
    trace_headers: [][]const Poly, // owned header arrays (point at stolen values)
    trace_value: Trace,
    fast_digest: [Blake2s256.digest_length]u8,
    slot: *PendingValidation,

    fn deinitStolen(self: *DeferredCtx) void {
        for (self.stolen_values) |vals| self.allocator.free(@constCast(vals));
        self.allocator.free(self.stolen_values);
        for (self.trace_headers) |inner| self.allocator.free(inner);
        self.allocator.free(self.trace_headers);
    }
};

fn spawnDeferredValidation(
    allocator: std.mem.Allocator,
    components: []const ComponentProver,
    random_coeff: QM31,
    trace: *const Trace,
    fast_digest: [Blake2s256.digest_length]u8,
) !void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    if (pending_validation != null) return error.ValidationAlreadyPending;
    const slot = try allocator.create(PendingValidation);
    errdefer allocator.destroy(slot);
    const ctx = try allocator.create(DeferredCtx);
    errdefer allocator.destroy(ctx);

    // Count total columns and steal every Poly value slice.
    var total_cols: usize = 0;
    for (trace.polys.items) |inner| total_cols += inner.len;
    const stolen = try allocator.alloc([]const M31, total_cols);
    errdefer allocator.free(stolen);
    const headers = try allocator.alloc([]const Poly, trace.polys.items.len);
    errdefer allocator.free(headers);
    var built: usize = 0;
    errdefer for (headers[0..built]) |inner| allocator.free(inner);

    // The referee needs the value slices AND matching headers with those
    // slices; steal both. @constCast(trace): the underlying prove.zig local
    // is `var trace` (precondition b) — this is the one sanctioned cast.
    const mutable_items = @constCast(trace.polys.items);
    var col: usize = 0;
    for (mutable_items, 0..) |inner, i| {
        const dup = try allocator.dupe(Poly, inner);
        headers[i] = dup;
        const mutable_inner = @constCast(inner);
        for (mutable_inner, 0..) |*poly, j| {
            stolen[col] = poly.values; // take ownership of the real slice
            dup[j].values = poly.values; // referee's header points at it
            poly.values = &[_]M31{}; // swap empty: deinitDeep frees nothing
            col += 1;
        }
        built += 1;
    }

    ctx.* = .{
        .allocator = allocator,
        .components = components,
        .random_coeff = random_coeff,
        .stolen_values = stolen,
        .trace_headers = headers,
        .trace_value = .{ .polys = .{ .items = @constCast(headers) } },
        .fast_digest = fast_digest,
        .slot = slot,
    };
    slot.* = .{ .thread = try std.Thread.spawn(.{}, deferredValidationMain, .{ctx}) };
    pending_validation = slot;
    pending_allocator = allocator;
}

fn deferredValidationMain(ctx: *DeferredCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.deinitStolen();
    var expected = referenceComposition(
        ctx.allocator,
        ctx.components,
        ctx.random_coeff,
        &ctx.trace_value,
    ) catch {
        // Reference failed to run: refuse to trust; latch rejected.
        setValidationStatus(ctx.components[0].vtable, validation_rejected);
        ctx.slot.verdict = .mismatch;
        return;
    };
    defer expected.deinit(ctx.allocator);
    const reference_digest = digestSecureColumn(expected);
    if (std.mem.eql(u8, &reference_digest, &ctx.fast_digest)) {
        setValidationStatus(ctx.components[0].vtable, validation_accepted);
        ctx.slot.verdict = .accepted;
    } else {
        setValidationStatus(ctx.components[0].vtable, validation_rejected);
        ctx.slot.verdict = .mismatch;
    }
}

/// Registered into the prover's join surface; also called on hook
/// re-entry so a second prove can never race a pending validation.
pub fn joinPendingValidation() JoinVerdict {
    pending_mutex.lock();
    const slot = pending_validation orelse {
        pending_mutex.unlock();
        return .none;
    };
    pending_validation = null;
    pending_mutex.unlock();
    slot.thread.join();
    const verdict = slot.verdict;
    pending_allocator.destroy(slot);
    return verdict;
}

fn recurrenceShape(components: []const ComponentProver, trace: *const Trace) ?RecurrenceShape {
    if (components.len != 1 or trace.polys.items.len != 2) return null;
    const component = components[0];
    if (trace.polys.items[0].len != 0) return null;
    const columns = trace.polys.items[1];
    if (columns.len < 64 or component.nConstraints() != columns.len - 2) return null;
    const eval_log_size = component.maxConstraintLogDegreeBound();
    if (eval_log_size < min_eval_log_size or eval_log_size >= @bitSizeOf(usize)) return null;
    const row_count = @as(usize, 1) << @intCast(eval_log_size);
    if (row_count % m31.PACK_WIDTH != 0) return null;
    for (columns) |column| {
        if (column.log_size != eval_log_size or column.values.len != row_count) return null;
    }

    const first_address = @intFromPtr(columns[0].values.ptr);
    const second_address = @intFromPtr(columns[1].values.ptr);
    if (second_address <= first_address) return null;
    const stride_bytes = second_address - first_address;
    if (stride_bytes % @sizeOf(M31) != 0) return null;
    const column_stride = stride_bytes / @sizeOf(M31);
    if (column_stride < row_count) return null;
    for (columns, 0..) |column, index| {
        const offset = std.math.mul(usize, index, stride_bytes) catch return null;
        const expected = std.math.add(usize, first_address, offset) catch return null;
        if (@intFromPtr(column.values.ptr) != expected) return null;
    }
    return .{
        .first_column = columns[0].values.ptr,
        .row_count = row_count,
        .column_count = columns.len,
        .column_stride = column_stride,
        .constraint_count = columns.len - 2,
        .eval_log_size = eval_log_size,
    };
}

fn validationStatus(vtable: *const prover.air.component_prover.ComponentProverVTable) u8 {
    validation_mutex.lock();
    defer validation_mutex.unlock();
    return if (validation_vtable == vtable) recurrence_validation else validation_unknown;
}

fn setValidationStatus(
    vtable: *const prover.air.component_prover.ComponentProverVTable,
    status: u8,
) void {
    validation_mutex.lock();
    defer validation_mutex.unlock();
    validation_vtable = vtable;
    recurrence_validation = status;
}

fn referenceComposition(
    allocator: std.mem.Allocator,
    components: []const ComponentProver,
    random_coeff: QM31,
    trace: *const Trace,
) !SecureColumnByCoords {
    var accumulator = try prover.air.accumulation.DomainEvaluationAccumulator.init(
        allocator,
        random_coeff,
        components[0].maxConstraintLogDegreeBound(),
        components[0].nConstraints(),
    );
    defer accumulator.deinit();
    try components[0].evaluateConstraintQuotientsOnDomain(trace, &accumulator);
    return accumulator.finalize();
}

fn secureColumnsEqual(lhs: SecureColumnByCoords, rhs: SecureColumnByCoords) bool {
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        if (!std.mem.eql(
            u8,
            std.mem.sliceAsBytes(lhs.columns[coordinate]),
            std.mem.sliceAsBytes(rhs.columns[coordinate]),
        )) return false;
    }
    return true;
}
