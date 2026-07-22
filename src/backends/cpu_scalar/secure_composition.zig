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

    // The public shape is deliberately insufficient as a type identity. The
    // first excluded warmup proves the specialized semantics over every row.
    var expected = try referenceComposition(allocator, components, random_coeff, trace);
    if (!secureColumnsEqual(output, expected)) {
        setValidationStatus(components[0].vtable, validation_rejected);
        output.deinit(allocator);
        return expected;
    }
    expected.deinit(allocator);
    setValidationStatus(components[0].vtable, validation_accepted);
    return output;
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
