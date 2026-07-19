//! Test-only mutation of one typed committed witness cell before commitment.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const prover_pcs = @import("stwo_prover_impl").pcs;
const statement_mod = @import("../air/statement.zig");
const infra = @import("../infra_trace.zig");
const trace = @import("../runner/trace.zig");

pub const Target = union(enum) {
    opcode: struct {
        family: trace.OpcodeFamily,
        shard: u32 = 0,
    },
    infrastructure: struct {
        kind: statement_mod.InfraKind,
        occurrence: u32 = 0,
    },
};

pub const Cell = struct {
    target: Target,
    column: u32,
    logical_row: u32,
    delta: u32 = 1,
};

pub const Mutation = union(enum) {
    preprocessed: Cell,
    main: Cell,
};

pub const Error = error{
    InvalidMutationTarget,
    InvalidMutationColumn,
    InvalidMutationRow,
    InvalidMutationDelta,
    InvalidTraceShape,
};

const Location = struct {
    column_offset: usize,
    log_size: u32,
    n_rows: u32,
    n_columns: u32,
};

pub fn applyPreprocessed(
    allocator: std.mem.Allocator,
    statement: statement_mod.RiscVStatement,
    columns: []prover_pcs.ColumnEvaluation,
    mutation: Mutation,
) !void {
    const cell = switch (mutation) {
        .preprocessed => |value| value,
        .main => return,
    };
    if (columns.len != statement.nPreprocessedColumns()) return Error.InvalidTraceShape;
    try mutate(allocator, columns, try locatePreprocessed(statement, cell.target), cell);
}

pub fn applyMain(
    allocator: std.mem.Allocator,
    statement: statement_mod.RiscVStatement,
    columns: []prover_pcs.ColumnEvaluation,
    mutation: Mutation,
) !void {
    const cell = switch (mutation) {
        .main => |value| value,
        .preprocessed => return,
    };
    if (columns.len != statement.nMainColumns()) return Error.InvalidTraceShape;
    try mutate(allocator, columns, try locateMain(statement, cell.target), cell);
}

fn mutate(
    allocator: std.mem.Allocator,
    columns: []prover_pcs.ColumnEvaluation,
    location: Location,
    cell: Cell,
) !void {
    if (cell.delta == 0) return Error.InvalidMutationDelta;
    if (cell.column >= location.n_columns) return Error.InvalidMutationColumn;
    if (cell.logical_row >= location.n_rows) return Error.InvalidMutationRow;
    const column = &columns[location.column_offset + cell.column];
    if (column.log_size != location.log_size) return Error.InvalidTraceShape;
    const placement = try infra.BitReversalTable.init(allocator, location.log_size);
    defer placement.deinit(allocator);
    const row = placement.map(cell.logical_row);
    const values = @constCast(column.values);
    values[row] = values[row].add(M31.fromU64(cell.delta));
}

fn locateMain(statement: statement_mod.RiscVStatement, target: Target) Error!Location {
    return switch (target) {
        .opcode => |wanted| locateOpcodeMain(statement, wanted.family, wanted.shard),
        .infrastructure => |wanted| locateInfraMain(statement, wanted.kind, wanted.occurrence),
    };
}

fn locateOpcodeMain(
    statement: statement_mod.RiscVStatement,
    family: trace.OpcodeFamily,
    wanted_shard: u32,
) Error!Location {
    var offset: usize = 0;
    var shard: u32 = 0;
    for (0..statement.n_components) |index| {
        const desc = statement.component_descs[index];
        if (desc.family == family) {
            if (shard == wanted_shard) return .{
                .column_offset = offset,
                .log_size = desc.log_size,
                .n_rows = desc.n_rows,
                .n_columns = desc.n_columns,
            };
            shard += 1;
        }
        offset += desc.n_columns;
    }
    return Error.InvalidMutationTarget;
}

fn locateInfraMain(
    statement: statement_mod.RiscVStatement,
    kind: statement_mod.InfraKind,
    wanted_occurrence: u32,
) Error!Location {
    var offset: usize = statement.nOpcodeMainColumns();
    var occurrence: u32 = 0;
    for (0..statement.n_infra) |index| {
        const desc = statement.infra_descs[index];
        if (desc.kind == kind) {
            if (occurrence == wanted_occurrence) return .{
                .column_offset = offset,
                .log_size = desc.log_size,
                .n_rows = desc.n_rows,
                .n_columns = desc.n_columns,
            };
            occurrence += 1;
        }
        offset += desc.n_columns;
    }
    return Error.InvalidMutationTarget;
}

fn locatePreprocessed(statement: statement_mod.RiscVStatement, target: Target) Error!Location {
    const wanted = switch (target) {
        .opcode => return Error.InvalidMutationTarget,
        .infrastructure => |value| value,
    };
    var occurrence: u32 = 0;
    for (0..statement.n_infra) |index| {
        const desc = statement.infra_descs[index];
        if (desc.kind == wanted.kind) {
            if (occurrence == wanted.occurrence) return .{
                .column_offset = statement.preprocessedOffsetForInfra(index),
                .log_size = desc.log_size,
                .n_rows = @intCast(@as(usize, 1) << @intCast(desc.log_size)),
                .n_columns = statement_mod.nPreprocessedColumnsForInfra(desc.kind),
            };
            occurrence += 1;
        }
    }
    return Error.InvalidMutationTarget;
}
