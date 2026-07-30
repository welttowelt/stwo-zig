//! Overlaps fixed lookup-table interaction generation with the other Tree-2
//! generators while preserving declaration-order column commitment.

const std = @import("std");
const component_order = @import("../air/component_order.zig");
const lookup_table_counter = @import("../air/lookups/tables/counter.zig");
const lookup_table_interaction = @import("../air/lookups/tables/interaction.zig");
const lookup_table_schema = @import("../air/lookups/tables/schema.zig");
const source_ingest = @import("../air/lookups/tables/source_ingest.zig");
const relation_challenges = @import("../air/relation_challenges.zig");
const interaction_columns = @import("interaction_columns.zig");
const proof_workspace = @import("proof_workspace.zig");
const types = @import("types.zig");

const Columns = interaction_columns.Columns;
const ProofWorkspace = proof_workspace.ProofWorkspace;
const Relations = relation_challenges.Relations;
const RiscVInteractionClaim = types.RiscVInteractionClaim;

/// A single-use helper. `start` may fall back to the caller thread, `finish`
/// always joins before exposing results, and `join` is safe on every error path.
pub const Task = struct {
    allocator: std.mem.Allocator,
    workspace: *ProofWorkspace,
    source: *const source_ingest.Result,
    relations: *const Relations,
    claim: *RiscVInteractionClaim,
    thread: ?std.Thread = null,
    joined: bool = false,
    error_value: ?anyerror = null,

    pub fn init(
        allocator: std.mem.Allocator,
        workspace: *ProofWorkspace,
        source: *const source_ingest.Result,
        relations: *const Relations,
        claim: *RiscVInteractionClaim,
    ) Task {
        return .{
            .allocator = allocator,
            .workspace = workspace,
            .source = source,
            .relations = relations,
            .claim = claim,
        };
    }

    pub fn start(self: *Task) void {
        self.thread = std.Thread.spawn(.{}, Task.run, .{self}) catch null;
        if (self.thread == null) self.run();
    }

    pub fn join(self: *Task) void {
        if (self.joined) return;
        if (self.thread) |thread| thread.join();
        self.joined = true;
    }

    pub fn finish(self: *Task, columns: *Columns) !void {
        self.join();
        if (self.error_value) |err| return err;
        const kinds = component_order.lookupTables();
        std.debug.assert(self.workspace.n_table_results == kinds.len);
        for (kinds, self.workspace.table_results[0..self.workspace.n_table_results]) |kind, *result| {
            const taken = result.takeColumns();
            for (taken) |values| columns.append(lookup_table_schema.logSize(kind), values);
        }
    }

    fn run(self: *Task) void {
        self.generate() catch |err| {
            self.error_value = err;
        };
    }

    fn generate(self: *Task) !void {
        const table_infra_start =
            self.workspace.statement.n_infra - component_order.LOOKUP_TABLE_COUNT;
        for (component_order.lookupTables(), 0..) |kind, table_index| {
            self.workspace.table_results[self.workspace.n_table_results] =
                try lookup_table_interaction.generate(
                    self.allocator,
                    &self.source.counters.counters[@intFromEnum(kind)],
                    self.relations,
                );
            const generated =
                &self.workspace.table_results[self.workspace.n_table_results];
            self.workspace.n_table_results += 1;
            self.claim.lookup_claims[table_infra_start + table_index] =
                generated.claim;
        }
    }
};

test "scheduled lookup generation is byte-identical to the serial generator" {
    const allocator = std.testing.allocator;
    var source = source_ingest.Result{
        .counters = try lookup_table_counter.Set.init(allocator),
        .family_count = 0,
        .shard_count = 0,
        .real_rows = 0,
        .padded_rows = 0,
        .source_entries = .{0} ** lookup_table_schema.KIND_COUNT,
        .manifest_digest = undefined,
    };
    defer source.deinit(allocator);

    // Non-zero samples exercise every table without coupling this scheduling
    // regression to a benchmark fixture or to the source-ingest implementation.
    for (&source.counters.counters, 0..) |*table, index| {
        table.values[0] = @import("stwo_core").fields.m31.M31.fromU64(index + 1);
        table.values[table.values.len / 2] =
            @import("stwo_core").fields.m31.M31.fromU64(index + 11).neg();
    }

    const relations = Relations.dummy();
    const n_columns =
        component_order.LOOKUP_TABLE_COUNT * lookup_table_interaction.N_COLUMNS;

    const scheduled_workspace = try allocator.create(ProofWorkspace);
    defer allocator.destroy(scheduled_workspace);
    scheduled_workspace.statement.n_infra = component_order.LOOKUP_TABLE_COUNT;
    scheduled_workspace.n_table_results = 0;
    defer for (
        scheduled_workspace.table_results[0..scheduled_workspace.n_table_results],
    ) |*result| result.deinit(allocator);
    const scheduled_claim = try allocator.create(RiscVInteractionClaim);
    defer allocator.destroy(scheduled_claim);
    scheduled_claim.initZeroInto();
    var scheduled_columns = try Columns.init(allocator, n_columns);
    defer scheduled_columns.deinit(allocator);

    var scheduled = Task.init(
        allocator,
        scheduled_workspace,
        &source,
        &relations,
        scheduled_claim,
    );
    scheduled.start();
    try std.testing.expect(scheduled.thread != null);
    try scheduled.finish(&scheduled_columns);

    const serial_workspace = try allocator.create(ProofWorkspace);
    defer allocator.destroy(serial_workspace);
    serial_workspace.statement.n_infra = component_order.LOOKUP_TABLE_COUNT;
    serial_workspace.n_table_results = 0;
    defer for (
        serial_workspace.table_results[0..serial_workspace.n_table_results],
    ) |*result| result.deinit(allocator);
    const serial_claim = try allocator.create(RiscVInteractionClaim);
    defer allocator.destroy(serial_claim);
    serial_claim.initZeroInto();
    var serial_columns = try Columns.init(allocator, n_columns);
    defer serial_columns.deinit(allocator);

    var serial = Task.init(
        allocator,
        serial_workspace,
        &source,
        &relations,
        serial_claim,
    );
    serial.run();
    try serial.finish(&serial_columns);

    try std.testing.expectEqual(n_columns, scheduled_columns.filled);
    try std.testing.expectEqual(n_columns, serial_columns.filled);
    for (
        scheduled_claim.lookup_claims[0..component_order.LOOKUP_TABLE_COUNT],
        serial_claim.lookup_claims[0..component_order.LOOKUP_TABLE_COUNT],
    ) |actual, expected| try std.testing.expect(actual.eql(expected));
    for (
        scheduled_columns.values[0..scheduled_columns.filled],
        serial_columns.values[0..serial_columns.filled],
    ) |actual, expected| {
        try std.testing.expectEqual(expected.log_size, actual.log_size);
        try std.testing.expectEqualSlices(
            @import("stwo_core").fields.m31.M31,
            expected.values,
            actual.values,
        );
    }
}
