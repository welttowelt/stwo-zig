const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;
const counter_mod = @import("lookups/tables/counter.zig");
const table_interaction = @import("lookups/tables/interaction.zig");
const table_schema = @import("lookups/tables/schema.zig");
const program_commitment = @import("program/commitment.zig");
const program_interaction = @import("program/interaction.zig");
const relations_mod = @import("relation_challenges.zig");
const relation_export = @import("relation_export.zig");
const components = @import("relation_export_components.zig");
const claims = @import("transcript/claims.zig");

fn advanceAbsent(
    count: usize,
    ledger: *relation_export.ClaimLedger,
    sequence: *relation_export.Sequence,
) !void {
    for (0..count) |index| {
        _ = try relation_export.exportAbsentComponent(@enumFromInt(index), ledger, sequence);
    }
}

fn programClaim(
    row: program_commitment.Row,
    relations: *const relations_mod.Relations,
) !QM31 {
    var result = QM31.zero();
    for (program_interaction.rowPairsFromRow(row, relations)) |pair| {
        result = result.add(try relation_export.pairTerm(pair));
    }
    return result;
}

test "relation component export binds exact program columns and native claim" {
    const allocator = std.testing.allocator;
    const relations = relations_mod.Relations.dummy();
    const row = program_commitment.Row{
        .addr = 0x1000,
        .values = .{ 0x13, 0, 0, 0 },
        .multiplicity = 1,
        .root = 77,
    };
    var columns = try program_commitment.generateMain(allocator, &.{row}, 4);
    defer columns.deinit(allocator);
    var views: [program_commitment.N_MAIN_COLUMNS][]const M31 = undefined;
    for (columns.values, &views) |column, *view| view.* = column;
    var shard = components.CommittedShard{
        .ordinal = 0,
        .shard_count = 1,
        .n_real_rows = 1,
        .committed_columns = &views,
        .main_columns_digest = undefined,
    };
    shard.main_columns_digest = components.digestCommittedShard(.program, shard);

    var native_sums = [_]QM31{QM31.zero()} ** relation_export.COMPONENT_COUNT;
    native_sums[@intFromEnum(relation_export.Component.program)] = try programClaim(row, &relations);
    const native = claims.InteractionClaim.init(native_sums, &.{});
    var ledger = try relation_export.ClaimLedger.init(.{1} ** 32, .{2} ** 32, &native);
    var sequence = relation_export.Sequence.init();
    try advanceAbsent(@intFromEnum(relation_export.Component.program), &ledger, &sequence);
    var observer = relation_export.NullObserver{};
    const evidence = try components.exportInfrastructure(
        allocator,
        .program,
        &.{shard},
        &relations,
        &ledger,
        &sequence,
        &observer,
    );
    try std.testing.expectEqual(@as(u64, 80), evidence.all.entries);
    try std.testing.expectEqual(@as(u64, 5), evidence.nonzero.entries);
    try std.testing.expect(evidence.computed_claim.eql(native_sums[16]));

    const original = columns.values[0][0];
    columns.values[0][0] = original.add(M31.one());
    var shadow_ledger = try relation_export.ClaimLedger.init(.{1} ** 32, .{2} ** 32, &native);
    var shadow_sequence = relation_export.Sequence.init();
    try advanceAbsent(16, &shadow_ledger, &shadow_sequence);
    try std.testing.expectError(
        error.MainColumnsDigestMismatch,
        components.exportInfrastructure(
            allocator,
            .program,
            &.{shard},
            &relations,
            &shadow_ledger,
            &shadow_sequence,
            &observer,
        ),
    );
}

test "relation component export requires the committed memory selector" {
    const allocator = std.testing.allocator;
    var storage: [8][]M31 = undefined;
    var initialized: usize = 0;
    defer for (storage[0..initialized]) |column| allocator.free(column);
    for (&storage) |*column| {
        column.* = try allocator.alloc(M31, 16);
        @memset(column.*, M31.zero());
        initialized += 1;
    }
    var views: [8][]const M31 = undefined;
    for (storage, &views) |column, *view| view.* = column;
    var shard = components.CommittedShard{
        .ordinal = 0,
        .shard_count = 1,
        .n_real_rows = 1,
        .committed_columns = &views,
        .main_columns_digest = undefined,
    };
    shard.main_columns_digest = components.digestCommittedShard(.memory, shard);
    const native = claims.InteractionClaim.init(
        .{QM31.zero()} ** relation_export.COMPONENT_COUNT,
        &.{},
    );
    var ledger = try relation_export.ClaimLedger.init(.{1} ** 32, .{2} ** 32, &native);
    var sequence = relation_export.Sequence.init();
    try advanceAbsent(@intFromEnum(relation_export.Component.memory), &ledger, &sequence);
    var observer = relation_export.NullObserver{};
    try std.testing.expectError(
        error.MissingSelector,
        components.exportInfrastructure(
            allocator,
            .memory,
            &.{shard},
            &relations_mod.Relations.dummy(),
            &ledger,
            &sequence,
            &observer,
        ),
    );
}

test "relation component export binds lookup main and preprocessed buffers" {
    const allocator = std.testing.allocator;
    const kind = table_schema.Kind.range_check_m31;
    const relations = relations_mod.Relations.dummy();
    var counter = try counter_mod.Counter.init(allocator, kind);
    defer counter.deinit(allocator);
    try counter.registerRaw(
        QM31.one(),
        &.{ QM31.fromBase(M31.fromU64(7)), QM31.fromBase(M31.fromU64(3)) },
    );
    const multiplicity = try counter.committedColumn(allocator);
    defer allocator.free(multiplicity);
    var tuples = try table_schema.generatePreprocessed(allocator, kind);
    defer tuples.deinit(allocator);
    var tuple_views: [table_schema.MAX_ARITY][]const M31 = undefined;
    for (tuples.columns[0..tuples.n_columns], tuple_views[0..tuples.n_columns]) |column, *view| {
        view.* = column;
    }
    var source = components.LookupTableSource{
        .kind = kind,
        .multiplicity_column = multiplicity,
        .tuple_columns = tuple_views[0..tuples.n_columns],
        .main_columns_digest = undefined,
        .preprocessed_columns_digest = undefined,
    };
    source.main_columns_digest = components.digestLookupMain(source);
    source.preprocessed_columns_digest = components.digestLookupPreprocessed(source);
    var interaction = try table_interaction.generate(allocator, &counter, &relations);
    defer interaction.deinit(allocator);
    var native_sums = [_]QM31{QM31.zero()} ** relation_export.COMPONENT_COUNT;
    native_sums[@intFromEnum(relation_export.Component.range_check_m31)] = interaction.claim;
    const native = claims.InteractionClaim.init(native_sums, &.{});
    var ledger = try relation_export.ClaimLedger.init(.{1} ** 32, .{2} ** 32, &native);
    var sequence = relation_export.Sequence.init();
    try advanceAbsent(@intFromEnum(relation_export.Component.range_check_m31), &ledger, &sequence);
    var observer = relation_export.NullObserver{};
    const evidence = try components.exportLookupTable(
        allocator,
        source,
        &relations,
        &ledger,
        &sequence,
        &observer,
    );
    try std.testing.expectEqual(@as(u64, table_schema.size(kind)), evidence.all.entries);
    try std.testing.expectEqual(@as(u64, 1), evidence.nonzero.entries);

    tuples.columns[0][0] = tuples.columns[0][0].add(M31.one());
    var shadow_ledger = try relation_export.ClaimLedger.init(.{1} ** 32, .{2} ** 32, &native);
    var shadow_sequence = relation_export.Sequence.init();
    try advanceAbsent(26, &shadow_ledger, &shadow_sequence);
    try std.testing.expectError(
        error.TablePreprocessedDigestMismatch,
        components.exportLookupTable(
            allocator,
            source,
            &relations,
            &shadow_ledger,
            &shadow_sequence,
            &observer,
        ),
    );
}
