//! Singleton LogUp interaction columns for lookup multiplicity tables.

const std = @import("std");
const fields = @import("../../../../../core/fields/mod.zig");
const M31 = @import("../../../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../../../core/fields/qm31.zig").QM31;
const infra = @import("../../../infra_trace.zig");
const entry = @import("../entry.zig");
const logup = @import("../../logup.zig");
const relations_mod = @import("../../relation_challenges.zig");
const counter_mod = @import("counter.zig");
const schema = @import("schema.zig");

pub const N_COLUMNS: usize = 4;
pub const Previous = [N_COLUMNS][]M31;

pub const Result = struct {
    columns: [N_COLUMNS][]M31,
    previous: Previous,
    claim: QM31,

    /// Moves the current cumulative columns out for commitment. Previous-row
    /// masks and the claim remain owned by this result until `deinit`.
    pub fn takeColumns(self: *Result) [N_COLUMNS][]M31 {
        const result = self.columns;
        self.columns = .{&.{}} ** N_COLUMNS;
        return result;
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        freeColumns(allocator, &self.columns);
        freeColumns(allocator, &self.previous);
        self.* = undefined;
    }
};

pub fn tableEntry(
    kind: schema.Kind,
    tuple: schema.Tuple,
    signed_multiplicity: M31,
) entry.Entry {
    var result = entry.Entry{
        .domain = schema.domain(kind),
        .numerator = QM31.fromBase(signed_multiplicity).neg(),
        .arity = @intCast(tuple.len),
    };
    for (tuple.slice(), result.values[0..tuple.len]) |value, *dst| dst.* = QM31.fromBase(value);
    return result;
}

pub fn rowPair(
    kind: schema.Kind,
    tuple: schema.Tuple,
    signed_multiplicity: M31,
    relations: *const relations_mod.Relations,
) !logup.RowPair {
    const relation_entry = tableEntry(kind, tuple, signed_multiplicity);
    return logup.RowPair.single(relation_entry.numerator, try relation_entry.denominator(relations));
}

/// Generate one secure singleton cumulative column as four committed M31
/// columns. Denominators are batch-inverted because tables reach 2^20 rows.
pub fn generate(
    allocator: std.mem.Allocator,
    counter: *const counter_mod.Counter,
    relations: *const relations_mod.Relations,
) !Result {
    const size = schema.size(counter.kind);
    if (counter.values.len != size) return error.InvalidTraceShape;
    const denominators = try allocator.alloc(QM31, size);
    defer allocator.free(denominators);
    for (denominators, 0..) |*denominator, row| {
        const tuple = try schema.tupleAt(counter.kind, row);
        const relation_entry = tableEntry(counter.kind, tuple, counter.values[row]);
        denominator.* = try relation_entry.denominator(relations);
    }
    const inverse = try fields.batchInverse(QM31, allocator, denominators);
    defer allocator.free(inverse);

    const sums = try allocator.alloc(QM31, size);
    defer allocator.free(sums);
    var accumulator = QM31.zero();
    for (sums, inverse, counter.values) |*sum, denominator_inverse, multiplicity| {
        accumulator = accumulator.add(QM31.fromBase(multiplicity).neg().mul(denominator_inverse));
        sum.* = accumulator;
    }

    var columns = try allocateColumns(allocator, size);
    errdefer freeColumns(allocator, &columns);
    var previous = try allocateColumns(allocator, size);
    errdefer freeColumns(allocator, &previous);
    const table = try infra.BitReversalTable.init(allocator, schema.logSize(counter.kind));
    defer table.deinit(allocator);
    for (0..size) |row| {
        const dst = table.map(row);
        const current = sums[row].toM31Array();
        const prior = sums[(row + size - 1) % size].toM31Array();
        for (0..N_COLUMNS) |coordinate| {
            columns[coordinate][dst] = current[coordinate];
            previous[coordinate][dst] = prior[coordinate];
        }
    }
    return .{ .columns = columns, .previous = previous, .claim = accumulator };
}

/// Shared on-domain/OODS table AIR identity.
pub fn evaluate(
    kind: schema.Kind,
    tuple: []const QM31,
    signed_multiplicity: QM31,
    current: QM31,
    previous: QM31,
    is_first: QM31,
    claim: QM31,
    relations: *const relations_mod.Relations,
) !QM31 {
    if (tuple.len != schema.arity(kind)) return error.InvalidTraceShape;
    var relation_entry = entry.Entry{
        .domain = schema.domain(kind),
        .numerator = signed_multiplicity.neg(),
        .arity = @intCast(tuple.len),
    };
    @memcpy(relation_entry.values[0..tuple.len], tuple);
    return logup.pairConstraint(
        current,
        previous,
        is_first,
        claim,
        logup.RowPair.single(relation_entry.numerator, try relation_entry.denominator(relations)),
    );
}

fn allocateColumns(allocator: std.mem.Allocator, len: usize) ![N_COLUMNS][]M31 {
    var result: [N_COLUMNS][]M31 = undefined;
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |column| allocator.free(column);
    for (&result) |*column| {
        column.* = try allocator.alloc(M31, len);
        initialized += 1;
    }
    return result;
}

fn freeColumns(allocator: std.mem.Allocator, columns: []const []M31) void {
    for (columns) |column| {
        if (column.len != 0) allocator.free(column);
    }
}

fn sourceTerm(
    kind: schema.Kind,
    values: []const QM31,
    numerator: QM31,
    relations: *const relations_mod.Relations,
) !QM31 {
    var relation_entry = entry.Entry{
        .domain = schema.domain(kind),
        .numerator = numerator,
        .arity = @intCast(values.len),
    };
    @memcpy(relation_entry.values[0..values.len], values);
    return numerator.mul(try (try relation_entry.denominator(relations)).inv());
}

test "table singleton balances signed source multiplicity for all six domains" {
    const relations = relations_mod.Relations.dummy();
    for (0..schema.KIND_COUNT) |index| {
        const kind: schema.Kind = @enumFromInt(index);
        const tuple = try schema.tupleAt(kind, 17);
        var secure: [schema.MAX_ARITY]QM31 = undefined;
        for (tuple.slice(), secure[0..tuple.len]) |value, *dst| dst.* = QM31.fromBase(value);
        const source = try sourceTerm(kind, secure[0..tuple.len], QM31.one().neg(), &relations);
        const table = try rowPair(kind, tuple, M31.one().neg(), &relations);
        const table_term = table.n1.mul(try table.d1.inv());
        try std.testing.expect(source.add(table_term).isZero());

        const wrong = try rowPair(kind, tuple, M31.fromU64(2).neg(), &relations);
        const wrong_term = wrong.n1.mul(try wrong.d1.inv());
        try std.testing.expect(!source.add(wrong_term).isZero());
        try std.testing.expect(!source.isZero()); // omitted table row
    }
}

test "table AIR identity rejects multiplicity, tuple, and claim mutations" {
    const relations = relations_mod.Relations.dummy();
    const kind: schema.Kind = .range_check_8_8;
    const tuple = [_]QM31{ QM31.fromBase(M31.fromU64(1)), QM31.fromBase(M31.fromU64(2)) };
    const pair = logup.RowPair.single(
        QM31.one(),
        relations.range_check_8_8.combineSecure(tuple),
    );
    const claim = pair.n1.mul(try pair.d1.inv());
    const honest = try evaluate(kind, &tuple, QM31.one().neg(), claim, claim, QM31.one(), claim, &relations);
    try std.testing.expect(honest.isZero());
    const bad_mult = try evaluate(kind, &tuple, M31QM31(2).neg(), claim, claim, QM31.one(), claim, &relations);
    try std.testing.expect(!bad_mult.isZero());
    var swapped = tuple;
    std.mem.swap(QM31, &swapped[0], &swapped[1]);
    const bad_tuple = try evaluate(kind, &swapped, QM31.one().neg(), claim, claim, QM31.one(), claim, &relations);
    try std.testing.expect(!bad_tuple.isZero());
    const bad_claim = try evaluate(kind, &tuple, QM31.one().neg(), claim, claim, QM31.one(), claim.add(QM31.one()), &relations);
    try std.testing.expect(!bad_claim.isZero());
}

test "generated singleton column closes one signed range M31 request" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    var counter = try counter_mod.Counter.init(allocator, .range_check_m31);
    defer counter.deinit(allocator);
    const tuple = [_]QM31{ M31QM31(1), M31QM31(2) };
    try counter.registerRaw(QM31.one().neg(), &tuple);
    var generated = try generate(allocator, &counter, &relations);
    defer generated.deinit(allocator);

    const source = try sourceTerm(.range_check_m31, &tuple, QM31.one().neg(), &relations);
    try std.testing.expect(source.add(generated.claim).isZero());
    const table = try infra.BitReversalTable.init(allocator, schema.logSize(.range_check_m31));
    defer table.deinit(allocator);
    const last = table.map(schema.size(.range_check_m31) - 1);
    const claim_from_column = QM31.fromM31(
        generated.columns[0][last],
        generated.columns[1][last],
        generated.columns[2][last],
        generated.columns[3][last],
    );
    try std.testing.expect(claim_from_column.eql(generated.claim));
    for (0..N_COLUMNS) |coordinate| {
        const previous_row = table.map(schema.size(.range_check_m31) - 2);
        try std.testing.expect(generated.previous[coordinate][last].eql(generated.columns[coordinate][previous_row]));
    }

    const owned_columns = generated.takeColumns();
    defer freeColumns(allocator, &owned_columns);
    for (generated.columns) |column| try std.testing.expectEqual(@as(usize, 0), column.len);
    for (owned_columns) |column| {
        try std.testing.expectEqual(schema.size(.range_check_m31), column.len);
    }
    try std.testing.expect(generated.claim.eql(claim_from_column));
    for (generated.previous) |column| {
        try std.testing.expectEqual(schema.size(.range_check_m31), column.len);
    }
}

fn M31QM31(value: u32) QM31 {
    return QM31.fromBase(M31.fromU64(value));
}
