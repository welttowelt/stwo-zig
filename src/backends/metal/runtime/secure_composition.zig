//! Large secure-composition transforms installed at Metal runtime startup.

const std = @import("std");
const constraints = @import("stwo_core").constraints;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const canonic = @import("stwo_core").poly.circle.canonic;
const domain_mod = @import("stwo_core").poly.circle.domain;
const prover = @import("stwo_prover_impl");
const prover_air = prover.air;
const prover_poly = prover.poly;
const shared_runtime = @import("../shared_runtime.zig");
const telemetry = @import("../telemetry.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CircleDomain = domain_mod.CircleDomain;
const ComponentProver = prover_air.component_prover.ComponentProver;
const Trace = prover_air.component_prover.Trace;
const SecureColumnByCoords = prover.secure_column.SecureColumnByCoords;
const TwiddleTree = prover_poly.twiddles.TwiddleTree([]const M31);
const min_secure_ifft_log_size: u32 = 19;
const min_recurrence_log_size: u32 = 15;
const min_recurrence_columns: usize = 32;
const validation_unknown: u8 = 0;
const validation_accepted: u8 = 1;
const validation_rejected: u8 = 2;
var validation_mutex: std.Thread.Mutex = .{};
var validation_vtable: ?*const prover_air.component_prover.ComponentProverVTable = null;
var recurrence_validation: u8 = validation_unknown;

pub fn install() void {
    prover_poly.circle.secure_poly.installBackendCircleIfftHook(
        interpolateLargeSecureComposition,
        min_secure_ifft_log_size,
    );
    prover_air.component_prover.installBackendCompositionEvaluationHook(
        evaluateLargeRecurrenceComposition,
    );
}

fn interpolateLargeSecureComposition(
    allocator: std.mem.Allocator,
    values: []const []M31,
    domain: CircleDomain,
    twiddle_tree: TwiddleTree,
) !bool {
    if (domain.logSize() < min_secure_ifft_log_size) return false;
    var lease = shared_runtime.acquireExisting() catch return false;
    defer lease.deinit();
    _ = try lease.runtime.transformCircle(
        allocator,
        values,
        twiddle_tree.itwiddles,
        domain.logSize(),
        true,
    );
    telemetry.record(.metal_circle_transform_dispatch);
    return true;
}

fn evaluateLargeRecurrenceComposition(
    allocator: std.mem.Allocator,
    components: []const ComponentProver,
    random_coeff: QM31,
    trace: *const Trace,
) !?SecureColumnByCoords {
    const shape = recurrenceShape(components, trace) orelse return null;
    if (validationStatus(components[0].vtable) == validation_rejected) return null;

    const powers = try prover_air.accumulation.generateSecurePowers(
        allocator,
        random_coeff,
        shape.constraint_count,
    );
    defer allocator.free(powers);
    const power_words = try allocator.alloc(u32, powers.len * 4);
    defer allocator.free(power_words);
    for (powers, 0..) |power, index| {
        const coordinates = power.toM31Array();
        inline for (0..4) |coordinate| {
            power_words[index * 4 + coordinate] = coordinates[coordinate].toU32();
        }
    }

    const eval_domain = canonic.CanonicCoset.new(shape.eval_log_size).circleDomain();
    const trace_coset = canonic.CanonicCoset.new(shape.eval_log_size - 1).coset();
    const denominator_inverses = [2]u32{
        (try constraints.cosetVanishing(M31, trace_coset, eval_domain.at(0)).inv()).toU32(),
        (try constraints.cosetVanishing(M31, trace_coset, eval_domain.at(1)).inv()).toU32(),
    };

    var lease = shared_runtime.acquireExisting() catch return null;
    defer lease.deinit();
    var output = try SecureColumnByCoords.uninitialized(allocator, shape.row_count);
    errdefer output.deinit(allocator);
    const output_values = output.columns[0].ptr[0 .. shape.row_count * 4];
    const gpu_ms = lease.runtime.evaluateRecurrenceComposition(
        shape.first_column,
        shape.row_count,
        shape.column_count,
        shape.column_stride,
        power_words,
        denominator_inverses,
        output_values,
    ) catch {
        output.deinit(allocator);
        return null;
    };
    std.log.debug("Metal recurrence composition: {d:.3}ms", .{gpu_ms});

    if (validationStatus(components[0].vtable) == validation_accepted) return output;

    // Admission is semantic, not a guessed type cast: the first excluded
    // warmup evaluates both implementations and requires byte identity over
    // the complete domain before this vtable is allowed onto the GPU fast path.
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

const RecurrenceShape = struct {
    first_column: [*]const M31,
    row_count: usize,
    column_count: usize,
    column_stride: usize,
    constraint_count: usize,
    eval_log_size: u32,
};

fn recurrenceShape(components: []const ComponentProver, trace: *const Trace) ?RecurrenceShape {
    if (components.len != 1 or trace.polys.items.len != 2) return null;
    const component = components[0];
    if (trace.polys.items[0].len != 0) return null;
    const columns = trace.polys.items[1];
    if (columns.len < min_recurrence_columns or component.nConstraints() != columns.len - 2) return null;
    const eval_log_size = component.maxConstraintLogDegreeBound();
    if (eval_log_size < min_recurrence_log_size or eval_log_size >= @bitSizeOf(usize)) return null;
    const row_count = @as(usize, 1) << @intCast(eval_log_size);
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

fn validationStatus(vtable: *const prover_air.component_prover.ComponentProverVTable) u8 {
    validation_mutex.lock();
    defer validation_mutex.unlock();
    return if (validation_vtable == vtable) recurrence_validation else validation_unknown;
}

fn setValidationStatus(
    vtable: *const prover_air.component_prover.ComponentProverVTable,
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
    var accumulator = try prover_air.accumulation.DomainEvaluationAccumulator.init(
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
    inline for (0..4) |coordinate| {
        if (!std.mem.eql(
            u8,
            std.mem.sliceAsBytes(lhs.columns[coordinate]),
            std.mem.sliceAsBytes(rhs.columns[coordinate]),
        )) return false;
    }
    return true;
}
