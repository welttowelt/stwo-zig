const std = @import("std");
const core_air_accumulation = @import("../../../core/air/accumulation.zig");
const core_air_components = @import("../../../core/air/components.zig");
const circle = @import("../../../core/circle.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;
const pcs = @import("../../../core/pcs/mod.zig");
const prover_air_accumulation = @import("../../../prover/air/accumulation.zig");
const prover_component = @import("../../../prover/air/component_prover.zig");
const ClockUpdateComponent = @import("clock_update_component.zig").ClockUpdateComponent;
const interaction = @import("clock_update_interaction.zig");
const infra = @import("../infra_trace.zig");
const state_chain = @import("../runner/state_chain.zig");
const counter = @import("lookups/tables/counter.zig");
const relations_mod = @import("relation_challenges.zig");

const TestMain = struct {
    columns: [interaction.N_MAIN_COLUMNS][]M31,

    fn deinit(self: *TestMain, allocator: std.mem.Allocator) void {
        for (self.columns) |column| allocator.free(column);
        self.* = undefined;
    }
};

fn testMain(allocator: std.mem.Allocator, log_size: u32) !TestMain {
    const size = @as(usize, 1) << @intCast(log_size);
    var result: TestMain = undefined;
    var initialized: usize = 0;
    errdefer for (result.columns[0..initialized]) |column| allocator.free(column);
    for (&result.columns) |*column| {
        column.* = try allocator.alloc(M31, size);
        @memset(column.*, M31.zero());
        initialized += 1;
    }
    const placement = try infra.BitReversalTable.init(allocator, log_size);
    defer placement.deinit(allocator);
    const row = placement.map(0);
    const values = [_]u32{ 1, 1, 0x1000, 7, 0x11, 0x22, 0x33, 0x44 };
    for (&result.columns, values) |column, value| column[row] = M31.fromU64(value);
    return result;
}

fn q(value: u32) QM31 {
    return QM31.fromBase(M31.fromU64(value));
}

fn secureAt(columns: []const []const M31, row: usize) QM31 {
    return QM31.fromM31(columns[0][row], columns[1][row], columns[2][row], columns[3][row]);
}

test "clock update exposes the exact memory pair and no range20 source" {
    const row = try interaction.Row.fromMain(&.{
        QM31.one(), q(1), q(0x1000), q(7), q(0x11), q(0x22), q(0x33), q(0x44),
    });
    const entries = interaction.orderedEntries(row);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 1), entries.batchCount());
    try std.testing.expectEqual(interaction.RANGE_CHECK_20_ENTRIES_PER_ROW, @as(usize, 0));
    for (entries.entries[0..entries.len]) |relation_entry| {
        try std.testing.expectEqual(@import("lookups/entry.zig").Domain.memory_access, relation_entry.domain);
    }
    try std.testing.expect(entries.entries[0].numerator.eql(QM31.one().neg()));
    try std.testing.expect(entries.entries[1].numerator.eql(QM31.one()));
    try std.testing.expect(entries.entries[0].values[2].eql(q(7)));
    try std.testing.expect(entries.entries[1].values[2].eql(
        q(7 + state_chain.MAX_CLOCK_DIFF),
    ));

    const allocator = std.testing.allocator;
    var range20 = try counter.Counter.init(allocator, .range_check_20);
    defer range20.deinit(allocator);
    try interaction.registerRangeCheck20Counter(&range20);
    try std.testing.expect(range20.signedTotal().eql(M31.zero()));
    var wrong = try counter.Counter.init(allocator, .range_check_8_8);
    defer wrong.deinit(allocator);
    try std.testing.expectError(
        error.InvalidRelationDomain,
        interaction.registerRangeCheck20Counter(&wrong),
    );
}

test "clock update component owns exact bounds and aliases both selectors" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    const component = ClockUpdateComponent.initVerifier(4, 7, 11, 13, 17, &relations, QM31.zero());
    try std.testing.expectEqual(@as(usize, 3), component.nConstraints());
    _ = component.asVerifierComponent();
    var bounds = try component.traceLogDegreeBounds(allocator);
    defer bounds.deinitDeep(allocator);
    try std.testing.expectEqual(@as(usize, 3), bounds.items.len);
    try std.testing.expectEqual(@as(usize, 2), bounds.items[0].len);
    try std.testing.expectEqual(interaction.N_MAIN_COLUMNS, bounds.items[1].len);
    try std.testing.expectEqual(interaction.N_INTERACTION_COLUMNS, bounds.items[2].len);
    for (bounds.items) |tree| for (tree) |log_size| try std.testing.expectEqual(@as(u32, 4), log_size);
    const indices = try component.preprocessedColumnIndices(allocator);
    defer allocator.free(indices);
    try std.testing.expectEqualSlices(usize, &.{ 7, 11 }, indices);
}

test "clock update generated interaction satisfies row semantics and rejects mutation" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    var main = try testMain(allocator, 4);
    defer main.deinit(allocator);
    var generated = try interaction.generate(allocator, &main.columns, 4, &relations);
    defer generated.deinit(allocator);
    const component = try ClockUpdateComponent.initProver(
        4,
        0,
        1,
        0,
        0,
        &relations,
        generated.claim,
        generated.previous,
    );
    _ = component.asProverComponent();
    const placement = try infra.BitReversalTable.init(allocator, 4);
    defer placement.deinit(allocator);
    const committed_row = placement.map(0);
    var sampled: [interaction.N_MAIN_COLUMNS]QM31 = undefined;
    for (&sampled, &main.columns) |*value, column| value.* = QM31.fromBase(column[committed_row]);
    const current = secureAt(&generated.columns, committed_row);
    const previous = secureAt(&generated.previous, committed_row);
    try std.testing.expect((try component.evaluateRow(
        &sampled,
        current,
        previous,
        QM31.one(),
        QM31.one(),
    )).allZero());
    sampled[0] = q(2);
    try std.testing.expect(!(try component.evaluateRow(
        &sampled,
        current,
        previous,
        QM31.one(),
        QM31.one(),
    )).allZero());
}

test "clock update OODS uses exact global offsets" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    var committed = try testMain(allocator, 4);
    defer committed.deinit(allocator);
    var generated = try interaction.generate(allocator, &committed.columns, 4, &relations);
    defer generated.deinit(allocator);
    const first_index: usize = 2;
    const active_index: usize = 3;
    const main_offset: usize = 5;
    const secure_offset: usize = 7;
    const component = ClockUpdateComponent.initVerifier(
        4,
        first_index,
        active_index,
        main_offset,
        secure_offset,
        &relations,
        generated.claim,
    );
    const placement = try infra.BitReversalTable.init(allocator, 4);
    defer placement.deinit(allocator);
    const committed_row = placement.map(0);

    var pp_storage = [_][1]QM31{.{q(19)}} ** 5;
    pp_storage[first_index][0] = QM31.one();
    pp_storage[active_index][0] = QM31.one();
    var pp: [pp_storage.len][]QM31 = undefined;
    for (&pp, &pp_storage) |*column, *values| column.* = values;
    var main_storage = [_][1]QM31{.{q(23)}} ** (main_offset + interaction.N_MAIN_COLUMNS + 2);
    for (main_storage[main_offset..][0..interaction.N_MAIN_COLUMNS], &committed.columns) |*value, column| {
        value[0] = QM31.fromBase(column[committed_row]);
    }
    var main: [main_storage.len][]QM31 = undefined;
    for (&main, &main_storage) |*column, *values| column.* = values;
    var secure_storage = [_][2]QM31{.{ q(29), q(31) }} **
        (secure_offset + interaction.N_INTERACTION_COLUMNS + 2);
    const current = generated.claim.toM31Array();
    const previous = secureAt(&generated.previous, committed_row).toM31Array();
    for (0..interaction.N_INTERACTION_COLUMNS) |index| {
        secure_storage[secure_offset + index][0] = QM31.fromBase(current[index]);
        secure_storage[secure_offset + index][1] = QM31.fromBase(previous[index]);
    }
    var secure: [secure_storage.len][]QM31 = undefined;
    for (&secure, &secure_storage) |*column, *values| column.* = values;
    var trees = [_][][]QM31{ &pp, &main, &secure };
    const mask = core_air_components.MaskValues.initOwned(&trees);
    const point = circle.SECURE_FIELD_CIRCLE_GEN.mul(29);
    var honest = core_air_accumulation.PointEvaluationAccumulator.init(QM31.one());
    try component.evaluateConstraintQuotientsAtPoint(
        point,
        &mask,
        &honest,
        component.maxConstraintLogDegreeBound(),
    );
    try std.testing.expect(honest.finalize().isZero());
    pp_storage[active_index][0] = QM31.zero();
    var mutated = core_air_accumulation.PointEvaluationAccumulator.init(QM31.one());
    try component.evaluateConstraintQuotientsAtPoint(
        point,
        &mask,
        &mutated,
        component.maxConstraintLogDegreeBound(),
    );
    try std.testing.expect(!mutated.finalize().isZero());
}

test "clock update on-domain path enforces inactive padding" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    const log_size: u32 = 4;
    const eval_log_size: u32 = 5;
    const eval_size: usize = 1 << eval_log_size;
    const trace_size: usize = 1 << log_size;
    const values = try allocator.alloc(M31, eval_size);
    defer allocator.free(values);
    @memset(values, M31.zero());
    const previous_values = try allocator.alloc(M31, trace_size);
    defer allocator.free(previous_values);
    @memset(previous_values, M31.zero());
    const zero_poly = prover_component.Poly{ .log_size = eval_log_size, .values = values };
    var pp = [_]prover_component.Poly{zero_poly} ** 2;
    var main = [_]prover_component.Poly{zero_poly} ** interaction.N_MAIN_COLUMNS;
    var secure = [_]prover_component.Poly{zero_poly} ** interaction.N_INTERACTION_COLUMNS;
    var trees = [_][]const prover_component.Poly{ &pp, &main, &secure };
    const trace_data = prover_component.Trace{
        .polys = pcs.TreeVec([]const prover_component.Poly).initOwned(&trees),
    };
    const previous = [_][]const M31{previous_values} ** interaction.N_INTERACTION_COLUMNS;
    const component = try ClockUpdateComponent.initProver(
        log_size,
        0,
        1,
        0,
        0,
        &relations,
        QM31.zero(),
        previous,
    );
    var accumulator = try prover_air_accumulation.DomainEvaluationAccumulator.init(
        allocator,
        QM31.one(),
        eval_log_size,
        component.nConstraints(),
    );
    defer accumulator.deinit();
    try component.evaluateConstraintQuotientsOnDomain(&trace_data, &accumulator);
    var result = try accumulator.finalize();
    defer result.deinit(allocator);
    for (0..result.len()) |row| try std.testing.expect(result.at(row).isZero());

    const active_values = try allocator.alloc(M31, eval_size);
    defer allocator.free(active_values);
    @memset(active_values, M31.one());
    pp[1] = .{ .log_size = eval_log_size, .values = active_values };
    var mutated = try prover_air_accumulation.DomainEvaluationAccumulator.init(
        allocator,
        QM31.one(),
        eval_log_size,
        component.nConstraints(),
    );
    defer mutated.deinit();
    try component.evaluateConstraintQuotientsOnDomain(&trace_data, &mutated);
    var mutated_result = try mutated.finalize();
    defer mutated_result.deinit(allocator);
    var saw_nonzero = false;
    for (0..mutated_result.len()) |row| {
        saw_nonzero = saw_nonzero or !mutated_result.at(row).isZero();
    }
    try std.testing.expect(saw_nonzero);
}

fn generateInteraction(
    allocator: std.mem.Allocator,
    columns: []const []const M31,
    relations: *const relations_mod.Relations,
) !void {
    var generated = try interaction.generate(allocator, columns, 4, relations);
    defer generated.deinit(allocator);
}

test "clock update interaction rejects malformed columns and rolls back allocations" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    var main = try testMain(allocator, 4);
    defer main.deinit(allocator);
    var views: [interaction.N_MAIN_COLUMNS][]const M31 = undefined;
    for (&views, &main.columns) |*view, column| view.* = column;
    try std.testing.expectError(
        error.InvalidColumnCount,
        interaction.generate(allocator, views[0 .. views.len - 1], 4, &relations),
    );
    const saved = views[0];
    views[0] = saved[0 .. saved.len - 1];
    try std.testing.expectError(
        error.InvalidColumnLength,
        interaction.generate(allocator, &views, 4, &relations),
    );
    views[0] = saved;
    try std.testing.checkAllAllocationFailures(
        allocator,
        generateInteraction,
        .{ &views, &relations },
    );
}

fn allocateMetadata(allocator: std.mem.Allocator, component: *const ClockUpdateComponent) !void {
    var bounds = try component.traceLogDegreeBounds(allocator);
    defer bounds.deinitDeep(allocator);
    var masks = try component.maskPoints(
        allocator,
        circle.SECURE_FIELD_CIRCLE_GEN,
        component.maxConstraintLogDegreeBound() + 2,
    );
    defer masks.deinitDeep(allocator);
    const indices = try component.preprocessedColumnIndices(allocator);
    defer allocator.free(indices);
}

test "clock update metadata allocations roll back completely" {
    const relations = relations_mod.Relations.dummy();
    const component = ClockUpdateComponent.initVerifier(4, 0, 1, 0, 0, &relations, QM31.zero());
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocateMetadata,
        .{&component},
    );
}
