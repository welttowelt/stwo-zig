//! RISC-V STARK prover and verifier orchestration.
//!
//! Proves execution of a RISC-V RV32IM program by:
//! 1. Running the program (ELF) to produce an execution trace
//! 2. Splitting the trace by opcode family
//! 3. Creating per-family components, each at its own log_size
//! 4. Committing and proving via the stwo STARK backend
//! 5. Verification of the produced proof
//!
//! ## Architecture
//!
//! Instead of one monolithic component with all trace rows, the trace is split
//! by opcode family. Each active family gets its own component with its own
//! `log_size = ceil(log2(count))`. This gives smaller FFTs per-component and
//! better cache behavior.
//!
//! ## Usage
//! ```zig
//! const result = try proveRiscVWithEngine(
//!     Engine, allocator, config, &exec_trace, &state_chain, &rw_memory, null,
//! );
//! try verifyRiscVWithEngine(Engine, allocator, config, result.statement, result.proof, result.interaction_claim);
//! ```

const std = @import("std");
const core_air_accumulation = @import("../../core/air/accumulation.zig");
const core_air_components = @import("../../core/air/components.zig");
const core_air_derive = @import("../../core/air/derive.zig");
const channel_blake2s = @import("../../core/channel/blake2s.zig");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const pcs_core = @import("../../core/pcs/mod.zig");
const pcs_verifier = @import("../../core/pcs/verifier.zig");
const core_proof = @import("../../core/proof.zig");
const core_verifier = @import("../../core/verifier.zig");
const blake2_merkle = @import("../../core/vcs_lifted/blake2_merkle.zig");
const prover_air_accumulation = @import("../../prover/air/accumulation.zig");
const prover_component = @import("../../prover/air/component_prover.zig");
const prover_engine = @import("../../prover/engine.zig");
const prover_pcs = @import("../../prover/pcs/mod.zig");
const stage_profile = @import("../../prover/stage_profile.zig");
const work_pool = @import("../../prover/work_pool.zig");
const secure_column = @import("../../prover/secure_column.zig");
const utils = @import("../../core/utils.zig");
const circle = @import("../../core/circle.zig");

const runner_mod = @import("runner/mod.zig");
const trace_mod = @import("runner/trace.zig");
const trace_columns = @import("air/trace_columns.zig");
const interaction_gen = @import("air/interaction_gen.zig");
const logup = @import("air/logup.zig");
const memory_logup = @import("air/memory_logup.zig");
const opcode_memory = @import("air/opcode_memory.zig");
const public_data_mod = @import("air/public_data.zig");
const public_logup = @import("air/public_logup.zig");
const memory_boundary = @import("air/memory_commitment/boundary.zig");
const hash_component = @import("air/memory_commitment/hash_component.zig");
const merkle_node = @import("air/memory_commitment/merkle_node.zig");
const poseidon2_air = @import("air/memory_commitment/poseidon2_air.zig");
const program_commitment = @import("air/program/commitment.zig");
const program_interaction = @import("air/program/interaction.zig");
const program_table = @import("air/program/table.zig");
const memory_interaction = @import("air/memory_commitment/interaction.zig");
const memory_trace = @import("air/memory_commitment/trace.zig");
const riscv_component = @import("air/component.zig");
const statement_mod = @import("air/statement.zig");
const infra = @import("infra_trace.zig");
const proof_transcript = @import("proof_transcript.zig");
const state_chain = @import("runner/state_chain.zig");
const memory_state = @import("runner/memory_state.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;
pub const PublicData = public_data_mod.PublicData;

pub const Hasher = blake2_merkle.Blake2sMerkleHasher;
const MerkleChannel = blake2_merkle.Blake2sMerkleChannel;
const Channel = channel_blake2s.Blake2sChannel;

pub const FamilyComponentDesc = statement_mod.FamilyComponentDesc;
const RiscVTraceComponent = riscv_component.RiscVTraceComponent;
pub const InfraKind = statement_mod.InfraKind;
pub const InfraComponentDesc = statement_mod.InfraComponentDesc;
pub const RiscVStatement = statement_mod.RiscVStatement;
pub const RiscVInteractionClaim = statement_mod.RiscVInteractionClaim;
pub const MAX_COMPONENTS = statement_mod.MAX_COMPONENTS;
pub const MAX_INFRA_COMPONENTS = statement_mod.MAX_INFRA_COMPONENTS;
const MAX_OPCODE_SHARD_LOG_SIZE: u32 = 16;
const MAX_OPCODE_SHARD_ROWS: usize = @as(usize, 1) << MAX_OPCODE_SHARD_LOG_SIZE;
const MAX_MEMORY_SHARD_LOG_SIZE: u32 = 16;
const MAX_MEMORY_SHARD_ROWS: usize = @as(usize, 1) << MAX_MEMORY_SHARD_LOG_SIZE;

pub const Proof = core_proof.StarkProof(Hasher);
pub const ExtendedProof = core_proof.ExtendedStarkProof(Hasher);
pub const OwnedRiscVStatement = @import("owned_statement.zig").OwnedRiscVStatement;

pub const ProveOutput = struct {
    statement: RiscVStatement,
    proof: Proof,
    interaction_claim: RiscVInteractionClaim,

    pub fn deinit(self: *ProveOutput, allocator: std.mem.Allocator) void {
        self.proof.deinit(allocator);
        self.* = undefined;
    }
};

/// Complete proving-engine substitution point.
///
/// The frontend owns statement construction and portable trace columns. The
/// engine owns commitment state, commitment execution, composition, FRI,
/// decommitment, and proof assembly. `Scheme` is intentionally opaque to the
/// frontend so a device backend can store a resident arena and command graph.
pub const assertProverEngine = prover_engine.assertProverEngine;

/// Binds a caller-selected backend to this frontend's protocol types.
///
/// Concrete backend selection belongs to an integration or tool boundary.
pub fn ProverEngineForBackend(comptime Backend: type) type {
    return prover_engine.ProverEngine(Backend, Hasher, MerkleChannel, Channel);
}

pub const ProverError = error{
    EmptyTrace,
    InvalidLogSize,
    InvalidStatement,
    InvalidPreprocessedCommitment,
    InvalidInteractionClaim,
    ProvingFailed,
    TooManyOpcodeComponents,
    TooManyInfrastructureComponents,
};

// -- Helpers --

/// Compute log_size from a count, with minimum of 1.
fn computeLogSize(count: usize) u32 {
    if (count <= 1) return 1;
    return @intCast(std.math.log2_int_ceil(usize, count));
}

fn validateStatement(statement: RiscVStatement) ProverError!void {
    if (statement.n_components == 0 or statement.n_components > MAX_COMPONENTS)
        return ProverError.InvalidStatement;
    if (statement.n_infra < 4 or statement.n_infra > MAX_INFRA_COMPONENTS)
        return ProverError.InvalidStatement;
    if (statement.public_data.initial_pc != statement.initial_pc or
        statement.public_data.final_pc != statement.final_pc or
        statement.public_data.clock != statement.total_steps or
        statement.public_data.io_entries.input_words.len !=
            std.math.divCeil(usize, statement.public_data.io_entries.input_len, 4) catch unreachable)
        return ProverError.InvalidStatement;

    var total_rows: u64 = 0;
    var previous_family: ?trace_mod.OpcodeFamily = null;
    var previous_rows: u32 = 0;
    var max_non_program_log: u32 = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        if (desc.log_size == 0 or desc.log_size > MAX_OPCODE_SHARD_LOG_SIZE or
            desc.n_rows == 0 or desc.n_rows > MAX_OPCODE_SHARD_ROWS or
            desc.log_size != computeLogSize(desc.n_rows) or
            desc.n_columns != nCommittedColumnsForFamily(desc.family) + OPCODE_BUS_COLS)
            return ProverError.InvalidStatement;
        if (previous_family) |family| {
            if (@intFromEnum(desc.family) < @intFromEnum(family))
                return ProverError.InvalidStatement;
            if (desc.family == family and previous_rows != MAX_OPCODE_SHARD_ROWS)
                return ProverError.InvalidStatement;
        }
        previous_family = desc.family;
        previous_rows = desc.n_rows;
        total_rows += desc.n_rows;
        max_non_program_log = @max(max_non_program_log, desc.log_size);
    }
    if (total_rows != statement.total_steps) return ProverError.InvalidStatement;

    const program = statement.infra_descs[0];
    if (program.kind != .program or program.n_rows == 0 or
        program.n_columns != program_commitment.N_MAIN_COLUMNS)
        return ProverError.InvalidStatement;

    var index: usize = 1;
    while (index < statement.n_infra and statement.infra_descs[index].kind == .memory) : (index += 1) {
        const desc = statement.infra_descs[index];
        if (desc.n_columns != memory_trace.N_COLUMNS or desc.n_rows == 0 or
            desc.n_rows > MAX_MEMORY_SHARD_ROWS or
            desc.log_size != @max(@as(u32, 4), computeLogSize(desc.n_rows)))
            return ProverError.InvalidStatement;
        max_non_program_log = @max(max_non_program_log, desc.log_size);
    }
    if (index + 3 != statement.n_infra) return ProverError.InvalidStatement;
    const merkle_desc = statement.infra_descs[index];
    const poseidon_desc = statement.infra_descs[index + 1];
    const clock_update = statement.infra_descs[index + 2];
    if (merkle_desc.kind != .merkle or
        merkle_desc.n_columns != merkle_node.N_MAIN_COLUMNS or
        merkle_desc.log_size != @max(@as(u32, 4), computeLogSize(merkle_desc.n_rows)))
        return ProverError.InvalidStatement;
    if (poseidon_desc.kind != .poseidon2 or
        poseidon_desc.n_columns != poseidon2_air.N_MAIN_COLUMNS or
        poseidon_desc.log_size != @max(@as(u32, 4), computeLogSize(poseidon_desc.n_rows)))
        return ProverError.InvalidStatement;
    if (clock_update.kind != .clock_update or
        clock_update.n_columns != infra.CLOCK_UPDATE_COLS or
        clock_update.log_size != @max(@as(u32, 4), computeLogSize(clock_update.n_rows)))
        return ProverError.InvalidStatement;
    if (poseidon_desc.n_rows != merkle_desc.n_rows) return ProverError.InvalidStatement;
    max_non_program_log = @max(
        max_non_program_log,
        @max(clock_update.log_size, @max(poseidon_desc.log_size, merkle_desc.log_size)),
    );
    if (program.n_rows > (@as(usize, 1) << @intCast(program.log_size)) or
        program.log_size != @max(computeLogSize(program.n_rows), max_non_program_log))
        return ProverError.InvalidStatement;
}

fn verifyPreprocessedRoot(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    statement: RiscVStatement,
    actual: Hasher.Hash,
) !void {
    const n_columns = 2 * (statement.n_components + statement.n_infra);
    const columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_columns);
    var initialized: usize = 0;
    var columns_moved = false;
    errdefer if (!columns_moved) {
        for (columns[0..initialized]) |column| allocator.free(@constCast(column.values));
        allocator.free(columns);
    };
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        columns[initialized] = .{ .log_size = desc.log_size, .values = try genIsFirstColumn(allocator, desc.log_size) };
        initialized += 1;
        columns[initialized] = .{ .log_size = desc.log_size, .values = try genIsActiveColumn(allocator, desc.log_size, desc.n_rows) };
        initialized += 1;
    }
    for (0..statement.n_infra) |i| {
        const desc = statement.infra_descs[i];
        columns[initialized] = .{ .log_size = desc.log_size, .values = try genIsFirstColumn(allocator, desc.log_size) };
        initialized += 1;
        columns[initialized] = .{ .log_size = desc.log_size, .values = try genIsActiveColumn(allocator, desc.log_size, desc.n_rows) };
        initialized += 1;
    }

    var scheme = try Engine.init(allocator, pcs_config);
    defer Engine.deinit(&scheme, allocator);
    var channel = Channel{};
    try Engine.commit(&scheme, allocator, columns, null, &channel);
    columns_moved = true;
    var roots = try scheme.roots(allocator);
    defer roots.deinit(allocator);
    if (roots.items.len != 1 or !std.meta.eql(roots.items[0], actual))
        return ProverError.InvalidPreprocessedCommitment;
}

// -- IsFirst column generation --

fn genIsFirstColumn(allocator: std.mem.Allocator, log_size: u32) ![]M31 {
    const n = @as(usize, 1) << @intCast(log_size);
    const values = try allocator.alloc(M31, n);
    @memset(values, M31.zero());
    if (n > 0) {
        const bit_rev_0 = utils.bitReverseIndex(
            utils.cosetIndexToCircleDomainIndex(0, log_size),
            log_size,
        );
        values[bit_rev_0] = M31.one();
    }
    return values;
}

fn genIsActiveColumn(
    allocator: std.mem.Allocator,
    log_size: u32,
    n_rows: u32,
) ![]M31 {
    const n = @as(usize, 1) << @intCast(log_size);
    if (n_rows > n) return ProverError.InvalidLogSize;
    const values = try allocator.alloc(M31, n);
    @memset(values, M31.zero());
    for (0..n_rows) |row| {
        const dst = utils.bitReverseIndex(
            utils.cosetIndexToCircleDomainIndex(row, log_size),
            log_size,
        );
        values[dst] = M31.one();
    }
    return values;
}

fn isCommittedFamilyColumn(_: trace_mod.OpcodeFamily, _: usize) bool {
    // Previous-value and previous-clock fields are part of the MemoryAccess
    // witness. They cannot remain protocol-implicit zero columns once the
    // runner supplies real access chains.
    return true;
}

fn nCommittedColumnsForFamily(family: trace_mod.OpcodeFamily) u32 {
    var count: u32 = 0;
    for (0..trace_mod.nColumnsForFamily(family)) |column| {
        if (isCommittedFamilyColumn(family, column)) count += 1;
    }
    return count;
}

const OPCODE_BUS_COLS: u32 = 5;

/// Result of the single-pass column generation for all opcode families.
const AllComponentColumns = struct {
    components: [MAX_COMPONENTS]trace_mod.TraceColumns,
};

fn deinitAllComponentColumns(
    allocator: std.mem.Allocator,
    statement: RiscVStatement,
    columns: *AllComponentColumns,
) void {
    for (0..statement.n_components) |component_index| {
        const component_columns = &columns.components[component_index];
        for (component_columns.columns[0..component_columns.n_columns]) |*values| {
            if (values.len == 0) continue;
            allocator.free(values.*);
            values.* = &.{};
        }
    }
}

/// Generate M31 columns for ALL opcode families in a single pass over the
/// execution trace, avoiding one complete trace scan per family.
///
/// Produces bit-identical output to the per-family approach: each family's
/// columns are in bit-reversed circle-domain order with its own log_size.
fn genAllFamilyColumns(
    allocator: std.mem.Allocator,
    exec_trace: *const trace_mod.Trace,
    statement: RiscVStatement,
) !AllComponentColumns {
    var result: AllComponentColumns = undefined;

    // Per-family metadata derived from statement descriptors.
    var log_sizes: [MAX_COMPONENTS]u32 = undefined;
    var domain_sizes: [MAX_COMPONENTS]usize = undefined;
    var n_cols: [MAX_COMPONENTS]usize = undefined;
    var row_counters: [trace_mod.N_FAMILIES]usize = .{0} ** trace_mod.N_FAMILIES;
    var first_component: [trace_mod.N_FAMILIES]usize = undefined;
    var family_component_counts: [trace_mod.N_FAMILIES]usize = .{0} ** trace_mod.N_FAMILIES;

    // Track allocation progress for cleanup on error. We store the family
    // enum indices (fi) of fully allocated families, plus a partial count
    // for the family currently being allocated.
    var initialized_components: [MAX_COMPONENTS]usize = undefined;
    var n_initialized: usize = 0;
    var partial_fi: usize = 0; // family index currently being allocated
    var partial_cols: usize = 0; // columns allocated so far for partial_fi

    errdefer {
        // Free all columns in fully initialized families.
        for (0..n_initialized) |i| {
            const component_index = initialized_components[i];
            for (0..n_cols[component_index]) |ci| {
                const values = result.components[component_index].columns[ci];
                if (values.len != 0) allocator.free(values);
            }
        }
        // Free partially initialized columns in the family that failed.
        if (partial_cols > 0) {
            for (0..partial_cols) |ci| {
                const values = result.components[partial_fi].columns[ci];
                if (values.len != 0) allocator.free(values);
            }
        }
    }

    // Pre-allocate columns for all families.
    for (0..statement.n_components) |comp_idx| {
        const desc = statement.component_descs[comp_idx];
        const fi = @intFromEnum(desc.family);
        if (family_component_counts[fi] == 0) first_component[fi] = comp_idx;
        family_component_counts[fi] += 1;
        log_sizes[comp_idx] = desc.log_size;
        domain_sizes[comp_idx] = @as(usize, 1) << @intCast(desc.log_size);
        n_cols[comp_idx] = trace_mod.nColumnsForFamily(desc.family);

        partial_fi = comp_idx;
        partial_cols = 0;
        for (0..n_cols[comp_idx]) |ci| {
            if (!isCommittedFamilyColumn(desc.family, ci)) {
                result.components[comp_idx].columns[ci] = &.{};
                partial_cols = ci + 1;
                continue;
            }
            result.components[comp_idx].columns[ci] = try allocator.alloc(M31, domain_sizes[comp_idx]);
            @memset(result.components[comp_idx].columns[ci], M31.zero());
            partial_cols = ci + 1;
        }
        result.components[comp_idx].n_columns = n_cols[comp_idx];
        initialized_components[n_initialized] = comp_idx;
        n_initialized += 1;
        partial_cols = 0; // fully initialized, no longer partial
    }

    // Pre-compute bit-reversal tables for each active family's log_size.
    var tables: [MAX_COMPONENTS]?infra.BitReversalTable = .{null} ** MAX_COMPONENTS;
    errdefer {
        for (&tables) |*t| {
            if (t.*) |tbl| tbl.deinit(allocator);
        }
    }
    for (0..statement.n_components) |comp_idx| {
        tables[comp_idx] = try infra.BitReversalTable.init(allocator, log_sizes[comp_idx]);
    }
    defer {
        for (&tables) |*t| {
            if (t.*) |tbl| tbl.deinit(allocator);
        }
    }

    const FillWork = struct {
        rows: []const trace_mod.TraceRow,
        family_offsets: [trace_mod.N_FAMILIES]usize,
        result: *AllComponentColumns,
        tables: *const [MAX_COMPONENTS]?infra.BitReversalTable,
        domain_sizes: *const [MAX_COMPONENTS]usize,
        first_component: *const [trace_mod.N_FAMILIES]usize,
        family_component_counts: *const [trace_mod.N_FAMILIES]usize,

        fn run(work: *@This()) void {
            var offsets = work.family_offsets;
            for (work.rows) |row| {
                const family = trace_mod.opcodeFamily(row.opcode);
                const fi = @intFromEnum(family);
                const family_row = offsets[fi];
                offsets[fi] += 1;
                const shard_index = family_row / MAX_OPCODE_SHARD_ROWS;
                if (shard_index >= work.family_component_counts[fi]) continue;
                const component_index = work.first_component[fi] + shard_index;
                const idx = family_row - shard_index * MAX_OPCODE_SHARD_ROWS;
                if (idx >= work.domain_sizes[component_index]) continue;
                const bit_rev_idx = work.tables[component_index].?.map(idx);
                trace_mod.fillFamilyColumns(
                    &work.result.components[component_index].columns,
                    bit_rev_idx,
                    row,
                    family,
                );
            }
        }
    };

    const active_pool = work_pool.getGlobalPool();
    const worker_count = if (active_pool) |pool|
        @max(@as(usize, 1), @min(pool.workerCount(), exec_trace.rows.items.len / 65_536))
    else
        1;
    var worker_family_counts: [work_pool.MAX_WORKERS][trace_mod.N_FAMILIES]usize =
        .{.{0} ** trace_mod.N_FAMILIES} ** work_pool.MAX_WORKERS;
    const chunk_len = (exec_trace.rows.items.len + worker_count - 1) / worker_count;
    for (0..worker_count) |worker| {
        const start = worker * chunk_len;
        const end = @min(exec_trace.rows.items.len, start + chunk_len);
        for (exec_trace.rows.items[start..end]) |row| {
            worker_family_counts[worker][@intFromEnum(trace_mod.opcodeFamily(row.opcode))] += 1;
        }
    }

    var works: [work_pool.MAX_WORKERS]FillWork = undefined;
    for (0..worker_count) |worker| {
        var offsets: [trace_mod.N_FAMILIES]usize = undefined;
        for (0..trace_mod.N_FAMILIES) |fi| {
            offsets[fi] = row_counters[fi];
            row_counters[fi] += worker_family_counts[worker][fi];
        }
        const start = worker * chunk_len;
        const end = @min(exec_trace.rows.items.len, start + chunk_len);
        works[worker] = .{
            .rows = exec_trace.rows.items[start..end],
            .family_offsets = offsets,
            .result = &result,
            .tables = &tables,
            .domain_sizes = &domain_sizes,
            .first_component = &first_component,
            .family_component_counts = &family_component_counts,
        };
    }
    if (worker_count > 1) {
        var wait_group: std.Thread.WaitGroup = .{};
        for (works[1..worker_count]) |*work| {
            active_pool.?.spawnWg(&wait_group, FillWork.run, .{work});
        }
        FillWork.run(&works[0]);
        wait_group.wait();
    } else {
        FillWork.run(&works[0]);
    }

    // Record actual row counts.
    for (0..statement.n_components) |comp_idx| {
        const fi = @intFromEnum(statement.component_descs[comp_idx].family);
        const shard_index = comp_idx - first_component[fi];
        const shard_start = shard_index * MAX_OPCODE_SHARD_ROWS;
        result.components[comp_idx].n_real_rows = @min(
            row_counters[fi] -| shard_start,
            domain_sizes[comp_idx],
        );
    }

    return result;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Proves through a transaction-level engine selected by the caller.
///
/// This is the backend substitution point. Engines may retain every committed
/// column and all subsequent prover state on a device; the frontend performs no
/// access to `Engine.Scheme` other than passing it back to engine methods.
/// When `opt_chain` is null, only the program infrastructure is populated.
pub fn proveRiscVWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    exec_trace: *const trace_mod.Trace,
    opt_chain: ?*const state_chain.StateChainTracker,
    opt_memory: ?*const memory_state.Snapshot,
    recorder: ?*stage_profile.Recorder,
) !ProveOutput {
    const register_boundary = try opcode_memory.deriveRegisterBoundary(exec_trace.rows.items);
    if (opt_chain) |chain| {
        if (!std.mem.eql(u32, &register_boundary.last_clock, &chain.reg_last_clk))
            return ProverError.InvalidStatement;
    }
    return proveRiscVWithEngineAndPublicData(
        Engine,
        allocator,
        pcs_config,
        exec_trace,
        opt_chain,
        opt_memory,
        recorder,
        .{
            .initial_pc = exec_trace.initial_pc,
            .final_pc = exec_trace.final_pc,
            .clock = @intCast(exec_trace.step_count),
            .initial_regs = register_boundary.initial,
            .final_regs = register_boundary.final,
            .reg_last_clock = register_boundary.last_clock,
            .program_root = null,
            .initial_rw_root = null,
            .final_rw_root = null,
            .io_entries = .{
                .input_start = 0,
                .input_len = 0,
                .input_words = &.{},
                .output_len = 0,
                .output_len_addr = 0,
                .output_data_addr = 0,
                .output_words = &.{},
            },
        },
    );
}

pub fn proveRiscVWithEngineAndPublicData(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    exec_trace: *const trace_mod.Trace,
    opt_chain: ?*const state_chain.StateChainTracker,
    opt_memory: ?*const memory_state.Snapshot,
    recorder: ?*stage_profile.Recorder,
    public_data: PublicData,
) !ProveOutput {
    comptime prover_engine.assertProverEngine(Engine);
    if (exec_trace.step_count == 0) return ProverError.EmptyTrace;

    var boundary_claims: ?memory_boundary.Claims = if (opt_memory) |snapshot|
        try memory_boundary.build(allocator, snapshot.words)
    else
        null;
    defer if (boundary_claims) |*claims| claims.deinit(allocator);
    if (boundary_claims) |claims| try claims.validate(allocator);

    const fetches = try allocator.alloc(program_table.Fetch, exec_trace.rows.items.len);
    defer allocator.free(fetches);
    for (exec_trace.rows.items, fetches) |row, *fetch| {
        fetch.* = .{ .pc = row.pc, .word = row.inst_word };
    }
    var program = try program_commitment.build(
        allocator,
        fetches,
        if (opt_memory) |snapshot| snapshot.program_words else &.{},
    );
    defer program.deinit(allocator);

    // Pinned Stark-V visits Poseidon calls program -> initial RW -> final RW,
    // while its Merkle table visits initial RW -> final RW -> program.
    var poseidon_calls_list: std.ArrayList(poseidon2_air.Call) = .{};
    defer poseidon_calls_list.deinit(allocator);
    for (program.tree.nodes) |node| {
        const row = merkle_node.NodeRow.fromNode(node, program.tree.root);
        try poseidon_calls_list.append(allocator, row.poseidonCall());
    }
    if (boundary_claims) |claims| {
        if (claims.initial_tree) |tree| {
            for (tree.nodes) |node| {
                const row = merkle_node.NodeRow.fromNode(node, tree.root);
                try poseidon_calls_list.append(allocator, row.poseidonCall());
            }
        }
        if (claims.final_tree) |tree| {
            for (tree.nodes) |node| {
                const row = merkle_node.NodeRow.fromNode(node, tree.root);
                try poseidon_calls_list.append(allocator, row.poseidonCall());
            }
        }
    }
    const poseidon_calls = poseidon_calls_list.items;

    var merkle_rows_list: std.ArrayList(merkle_node.NodeRow) = .{};
    defer merkle_rows_list.deinit(allocator);
    if (boundary_claims) |claims| {
        if (claims.initial_tree) |tree| {
            for (tree.nodes) |node| {
                try merkle_rows_list.append(allocator, merkle_node.NodeRow.fromNode(node, tree.root));
            }
        }
        if (claims.final_tree) |tree| {
            for (tree.nodes) |node| {
                try merkle_rows_list.append(allocator, merkle_node.NodeRow.fromNode(node, tree.root));
            }
        }
    }
    for (program.tree.nodes) |node| {
        try merkle_rows_list.append(allocator, merkle_node.NodeRow.fromNode(node, program.tree.root));
    }
    const merkle_rows = merkle_rows_list.items;

    // -- Step 1: Count rows per opcode family. --
    const counts = try exec_trace.groupByOpcodeFamily(allocator);

    // -- Step 2: Build statement with per-family descriptors. --
    var statement: RiscVStatement = .{
        .n_components = 0,
        .component_descs = undefined,
        .initial_pc = exec_trace.initial_pc,
        .final_pc = exec_trace.final_pc,
        .total_steps = @intCast(exec_trace.step_count),
        .public_data = public_data,
    };

    for (0..trace_mod.N_FAMILIES) |fi| {
        const family: trace_mod.OpcodeFamily = @enumFromInt(fi);
        const count = counts.get(family);
        if (count == 0) continue;

        var remaining = count;
        while (remaining > 0) {
            if (statement.n_components >= MAX_COMPONENTS) return ProverError.TooManyOpcodeComponents;
            const shard_len = @min(remaining, MAX_OPCODE_SHARD_ROWS);
            statement.component_descs[statement.n_components] = .{
                .family = family,
                .log_size = computeLogSize(shard_len),
                .n_rows = @intCast(shard_len),
                .n_columns = nCommittedColumnsForFamily(family) + OPCODE_BUS_COLS,
            };
            statement.n_components += 1;
            remaining -= shard_len;
        }
    }

    if (statement.n_components == 0) return ProverError.EmptyTrace;

    // -- Step 2b: Build infrastructure component descriptors. --
    statement.n_infra = 0;

    // Exact sparse decoded-program commitment (8 columns).
    var program_log_size = computeLogSize(program.rows.len);
    statement.infra_descs[statement.n_infra] = .{
        .kind = .program,
        .log_size = program_log_size,
        .n_rows = @intCast(program.rows.len),
        .n_columns = program_commitment.N_MAIN_COLUMNS,
    };
    statement.n_infra += 1;

    // Ordinary RW-memory boundary rows, sharded without changing relation
    // placement. Opcode-side accesses close this bus in a later soundness slice.
    var memory_shard_count: usize = 0;
    var memory_shard_lengths: [MAX_INFRA_COMPONENTS]usize = undefined;
    if (boundary_claims) |claims| {
        var remaining = claims.rows.len;
        while (remaining > 0) {
            if (statement.n_infra + 3 >= MAX_INFRA_COMPONENTS)
                return ProverError.TooManyInfrastructureComponents;
            const shard_len = @min(remaining, MAX_MEMORY_SHARD_ROWS);
            const shard_log_size = @max(computeLogSize(shard_len), 4);
            statement.infra_descs[statement.n_infra] = .{
                .kind = .memory,
                .log_size = shard_log_size,
                .n_rows = @intCast(shard_len),
                .n_columns = memory_trace.N_COLUMNS,
            };
            statement.n_infra += 1;
            memory_shard_lengths[memory_shard_count] = shard_len;
            memory_shard_count += 1;
            remaining -= shard_len;
        }
    }

    if (statement.public_data.program_root) |root| {
        if (root != program.tree.root) return ProverError.InvalidStatement;
    }
    statement.public_data.program_root = program.tree.root;

    if (boundary_claims) |claims| {
        const initial_root = if (claims.initial_tree) |tree| tree.root else null;
        const final_root = if (claims.final_tree) |tree| tree.root else null;
        if (statement.public_data.initial_rw_root) |root| {
            if (initial_root == null or root != initial_root.?) return ProverError.InvalidStatement;
        }
        if (statement.public_data.final_rw_root) |root| {
            if (final_root == null or root != final_root.?) return ProverError.InvalidStatement;
        }
        statement.public_data.initial_rw_root = initial_root;
        statement.public_data.final_rw_root = final_root;
    } else if (statement.public_data.initial_rw_root != null or
        statement.public_data.final_rw_root != null)
    {
        return ProverError.InvalidStatement;
    }

    const total_hashes = poseidon_calls.len;

    // Merkle and Poseidon2 follow the pinned component registry order.
    const total_merkle_nodes = merkle_rows.len;
    const merkle_log_size: u32 = if (total_merkle_nodes > 0)
        @max(4, computeLogSize(total_merkle_nodes))
    else
        4;
    const merkle_infra_index = statement.n_infra;
    statement.infra_descs[merkle_infra_index] = .{
        .kind = .merkle,
        .log_size = merkle_log_size,
        .n_rows = @intCast(total_merkle_nodes),
        .n_columns = merkle_node.N_MAIN_COLUMNS,
    };
    statement.n_infra += 1;

    const poseidon_log_size: u32 = if (total_hashes > 0)
        @max(4, computeLogSize(total_hashes))
    else
        4;
    const poseidon_infra_index = statement.n_infra;
    statement.infra_descs[poseidon_infra_index] = .{
        .kind = .poseidon2,
        .log_size = poseidon_log_size,
        .n_rows = @intCast(total_hashes),
        .n_columns = poseidon2_air.N_MAIN_COLUMNS,
    };
    statement.n_infra += 1;

    // Unified clock update follows Poseidon2 in the pinned registry.
    var clock_update_log: u32 = 4;
    if (opt_chain) |chain| {
        const n_updates = chain.clock_updates_mem.items.len + chain.clock_updates_reg.items.len;
        if (n_updates > 0) clock_update_log = @max(computeLogSize(n_updates), 4);
    }
    statement.infra_descs[statement.n_infra] = .{
        .kind = .clock_update,
        .log_size = clock_update_log,
        .n_rows = if (opt_chain) |chain| @intCast(
            chain.clock_updates_mem.items.len + chain.clock_updates_reg.items.len,
        ) else 0,
        .n_columns = infra.CLOCK_UPDATE_COLS,
    };
    statement.n_infra += 1;

    // Preprocessed lookup multiplicity tables stay uncommitted: range-check
    // and bitwise buses are not wired yet.

    // Lift the program ROM to the maximal component size: the interaction
    // tree (tree 2) must contain a column at the maximal committed log size
    // because the lifted PCS folds query positions only for tree 0. Padding
    // ROM rows carry zero multiplicity and do not change the bus balance.
    var max_component_log: u32 = 0;
    for (0..statement.n_components) |i| {
        max_component_log = @max(max_component_log, statement.component_descs[i].log_size);
    }
    for (0..statement.n_infra) |i| {
        max_component_log = @max(max_component_log, statement.infra_descs[i].log_size);
    }
    program_log_size = @max(program_log_size, max_component_log);
    std.debug.assert(statement.infra_descs[0].kind == .program);
    statement.infra_descs[0].log_size = program_log_size;
    try validateStatement(statement);

    var channel = Channel{};
    statement.public_data.mixInto(&channel);

    var scheme = try Engine.init(allocator, pcs_config);
    var scheme_owned = true;
    errdefer if (scheme_owned) Engine.deinit(&scheme, allocator);

    // Empty state chain for fallback when opt_chain is null.
    var empty_chain = state_chain.StateChainTracker.init(allocator);
    defer empty_chain.deinit();

    // -- Step 3: Tree 0 -- deterministic IsFirst/IsActive selector pairs. --
    const n_preproc = 2 * (statement.n_components + statement.n_infra);
    {
        var stage = try stage_profile.StageScope.begin(recorder, "riscv_preprocessed_commit", "RISC-V preprocessed trace commit");
        defer stage.end();
        const preprocessed = try allocator.alloc(prover_pcs.ColumnEvaluation, n_preproc);
        var initialized: usize = 0;
        var moved = false;
        errdefer if (!moved) {
            for (preprocessed[0..initialized]) |column| allocator.free(@constCast(column.values));
            allocator.free(preprocessed);
        };
        for (0..statement.n_components) |i| {
            const ls = statement.component_descs[i].log_size;
            preprocessed[2 * i] = .{ .log_size = ls, .values = try genIsFirstColumn(allocator, ls) };
            initialized += 1;
            preprocessed[2 * i + 1] = .{
                .log_size = ls,
                .values = try genIsActiveColumn(allocator, ls, statement.component_descs[i].n_rows),
            };
            initialized += 1;
        }
        for (0..statement.n_infra) |i| {
            const ls = statement.infra_descs[i].log_size;
            const base = 2 * (statement.n_components + i);
            preprocessed[base] = .{ .log_size = ls, .values = try genIsFirstColumn(allocator, ls) };
            initialized += 1;
            preprocessed[base + 1] = .{
                .log_size = ls,
                .values = try genIsActiveColumn(allocator, ls, statement.infra_descs[i].n_rows),
            };
            initialized += 1;
        }
        moved = true;
        try Engine.commit(&scheme, allocator, preprocessed, recorder, &channel);
    }

    // -- Step 4: Tree 1 -- Main trace (opcode + infrastructure columns). --
    const n_opcode_main = statement.nOpcodeMainColumns();
    const n_infra_main = statement.nInfraColumns();
    const n_main = n_opcode_main + n_infra_main;
    const main_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_main);
    const main_initialized = allocator.alloc(bool, n_main) catch |err| {
        allocator.free(main_columns);
        return err;
    };
    defer allocator.free(main_initialized);
    @memset(main_initialized, false);
    var main_columns_moved = false;
    errdefer if (!main_columns_moved) {
        for (main_columns, main_initialized) |column, initialized| {
            if (initialized) allocator.free(@constCast(column.values));
        }
        allocator.free(main_columns);
    };
    const OpcodeGenerationWork = struct {
        allocator: std.mem.Allocator,
        exec_trace: *const trace_mod.Trace,
        statement: RiscVStatement,
        result: AllComponentColumns = undefined,
        err: ?anyerror = null,

        fn run(work: *@This()) void {
            work.result = genAllFamilyColumns(
                work.allocator,
                work.exec_trace,
                work.statement,
            ) catch |err| {
                work.err = err;
                return;
            };
        }
    };
    var opcode_work = OpcodeGenerationWork{
        .allocator = allocator,
        .exec_trace = exec_trace,
        .statement = statement,
    };
    var opcode_stage = try stage_profile.StageScope.begin(recorder, "riscv_opcode_trace_generation", "RISC-V opcode trace generation (overlapped)");
    const opcode_thread = std.Thread.spawn(.{}, OpcodeGenerationWork.run, .{&opcode_work}) catch null;
    var opcode_joined = false;
    defer if (opcode_thread) |thread| {
        if (!opcode_joined) thread.join();
    };
    errdefer {
        if (opcode_thread) |thread| {
            if (!opcode_joined) {
                thread.join();
                opcode_joined = true;
            }
        }
        if (opcode_work.err == null) {
            deinitAllComponentColumns(allocator, statement, &opcode_work.result);
        }
    }
    if (opcode_thread == null) OpcodeGenerationWork.run(&opcode_work);

    var col_offset: usize = n_opcode_main;

    var infrastructure_stage = try stage_profile.StageScope.begin(recorder, "riscv_infrastructure_trace_generation", "RISC-V infrastructure trace generation");
    // Infrastructure columns.
    // Exact sparse decoded-program commitment.
    {
        const prog_cols = try program_commitment.generateMain(allocator, program.rows, program_log_size);
        for (0..program_commitment.N_MAIN_COLUMNS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = program_log_size,
                .values = prog_cols.values[c],
            };
            main_initialized[col_offset + c] = true;
        }
        col_offset += program_commitment.N_MAIN_COLUMNS;
    }

    // Exact ordinary RW-memory boundary table.
    if (boundary_claims) |claims| {
        var row_start: usize = 0;
        for (memory_shard_lengths[0..memory_shard_count]) |shard_len| {
            const log_size = @max(computeLogSize(shard_len), 4);
            const generated = try memory_trace.generate(
                allocator,
                claims.rows[row_start..][0..shard_len],
                log_size,
            );
            for (generated.values) |values| {
                main_columns[col_offset] = .{ .log_size = log_size, .values = values };
                main_initialized[col_offset] = true;
                col_offset += 1;
            }
            row_start += shard_len;
        }
    }

    // Exact sparse Merkle rows: initial RW, final RW, then program.
    {
        const mkl_cols = try merkle_node.generateMain(allocator, merkle_rows, merkle_log_size);
        for (0..merkle_node.N_MAIN_COLUMNS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = merkle_log_size,
                .values = mkl_cols.values[c],
            };
            main_initialized[col_offset + c] = true;
        }
        col_offset += merkle_node.N_MAIN_COLUMNS;
    }

    // Exact narrow Poseidon2 permutation calls, one per sparse Merkle node.
    {
        const p2_cols = try poseidon2_air.generateMain(allocator, poseidon_calls, poseidon_log_size);
        for (0..poseidon2_air.N_MAIN_COLUMNS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = poseidon_log_size,
                .values = p2_cols.values[c],
            };
            main_initialized[col_offset + c] = true;
        }
        col_offset += poseidon2_air.N_MAIN_COLUMNS;
    }

    // Unified register + memory clock update (8 cols).
    {
        const chain_ptr = opt_chain orelse &empty_chain;
        const cu_cols = try infra.genClockUpdateColumns(allocator, chain_ptr, clock_update_log);
        for (0..infra.CLOCK_UPDATE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = clock_update_log,
                .values = cu_cols.columns[c],
            };
            main_initialized[col_offset + c] = true;
        }
        col_offset += infra.CLOCK_UPDATE_COLS;
    }
    infrastructure_stage.end();

    if (opcode_thread) |thread| {
        thread.join();
        opcode_joined = true;
    }
    opcode_stage.end();
    if (opcode_work.err) |err| return err;

    var rows_by_family: [trace_mod.N_FAMILIES]std.ArrayList(trace_mod.TraceRow) =
        .{std.ArrayList(trace_mod.TraceRow).empty} ** trace_mod.N_FAMILIES;
    defer for (&rows_by_family) |*rows| rows.deinit(allocator);
    for (exec_trace.rows.items) |row| {
        try rows_by_family[@intFromEnum(trace_mod.opcodeFamily(row.opcode))].append(allocator, row);
    }
    var family_bus_cursor: [trace_mod.N_FAMILIES]usize = .{0} ** trace_mod.N_FAMILIES;
    var opcode_col_offset: usize = 0;
    for (0..statement.n_components) |comp_idx| {
        const desc = statement.component_descs[comp_idx];
        var committed_column: usize = 0;
        for (0..opcode_work.result.components[comp_idx].n_columns) |column| {
            const values = opcode_work.result.components[comp_idx].columns[column];
            if (!isCommittedFamilyColumn(desc.family, column)) {
                std.debug.assert(values.len == 0);
                continue;
            }
            main_columns[opcode_col_offset + committed_column] = .{
                .log_size = desc.log_size,
                .values = values,
            };
            main_initialized[opcode_col_offset + committed_column] = true;
            opcode_work.result.components[comp_idx].columns[column] = &.{};
            committed_column += 1;
        }
        std.debug.assert(committed_column + OPCODE_BUS_COLS == desc.n_columns);
        const fi = @intFromEnum(desc.family);
        const start = family_bus_cursor[fi];
        const end = start + desc.n_rows;
        if (end > rows_by_family[fi].items.len) return ProverError.InvalidLogSize;
        const bus = try interaction_gen.genOpcodeBusColumns(
            allocator,
            rows_by_family[fi].items[start..end],
            desc.log_size,
        );
        for (bus) |values| {
            main_columns[opcode_col_offset + committed_column] = .{
                .log_size = desc.log_size,
                .values = values,
            };
            main_initialized[opcode_col_offset + committed_column] = true;
            committed_column += 1;
        }
        family_bus_cursor[fi] = end;
        std.debug.assert(committed_column == desc.n_columns);
        opcode_col_offset += desc.n_columns;
    }
    std.debug.assert(opcode_col_offset == n_opcode_main);
    std.debug.assert(col_offset == n_main);

    {
        var stage = try stage_profile.StageScope.begin(recorder, "riscv_main_trace_commit", "RISC-V main trace commit");
        defer stage.end();
        main_columns_moved = true;
        try Engine.commit(&scheme, allocator, main_columns, recorder, &channel);
    }

    // Tree 2 carries the transitional opcode buses and the exact program,
    // memory, Merkle, and Poseidon2 interactions. Exact opcode/table placement
    // and canonical global cancellation remain release blockers.
    const n_interaction = statement.nInteractionColumns();

    std.log.info("Columns: opcode={d} infra={d} total tree1={d} interaction={d}", .{
        n_opcode_main,
        n_infra_main,
        n_main,
        n_interaction,
    });
    std.log.info("Poseidon2 Merkle: {d} exact sparse-node calls, poseidon_log_size={d}, merkle_log_size={d}", .{
        total_hashes,
        poseidon_log_size,
        merkle_log_size,
    });

    // -- Step 5: LogUp interaction tree (tree 2). --
    const transcript_prefix = try proof_transcript.proveToRelations(allocator, &channel, &statement);
    const relations = transcript_prefix.relations;

    var interaction_claim = RiscVInteractionClaim.initZero();
    interaction_claim.n_components = statement.n_components;
    interaction_claim.n_infra = statement.n_infra;
    interaction_claim.interaction_pow = transcript_prefix.interaction_pow;

    // Uncommitted trace-order-shifted S columns ([0] state, [1] prog per
    // opcode component; rom for the program component), kept alive for the
    // on-domain constraint evaluation inside Engine.prove.
    const opcode_prev = try allocator.alloc([2][4][]M31, statement.n_components);
    var opcode_prev_transferred = false;
    errdefer if (!opcode_prev_transferred) allocator.free(opcode_prev);
    for (opcode_prev) |*prev| prev.* = .{ .{ &.{}, &.{}, &.{}, &.{} }, .{ &.{}, &.{}, &.{}, &.{} } };
    const opcode_memory_prev = try allocator.alloc(opcode_memory.Previous, statement.n_components);
    var opcode_memory_prev_transferred = false;
    errdefer if (!opcode_memory_prev_transferred) allocator.free(opcode_memory_prev);
    for (opcode_memory_prev) |*prev| {
        prev.* = .{.{ &.{}, &.{}, &.{}, &.{} }} ** opcode_memory.N_ACCESSES;
    }
    var program_prev: program_interaction.Previous =
        .{.{ &.{}, &.{}, &.{}, &.{} }} ** program_interaction.N_SUMS;
    var merkle_prev: merkle_node.Previous =
        .{.{ &.{}, &.{}, &.{}, &.{} }} ** merkle_node.N_SUMS;
    var poseidon_prev: poseidon2_air.Previous =
        .{.{ &.{}, &.{}, &.{}, &.{} }} ** poseidon2_air.N_SUMS;
    const memory_prev = try allocator.alloc(memory_interaction.Previous, statement.n_infra);
    for (memory_prev) |*prev| prev.* = .{.{ &.{}, &.{}, &.{}, &.{} }} ** memory_interaction.N_SUMS;
    opcode_prev_transferred = true;
    opcode_memory_prev_transferred = true;
    defer {
        for (opcode_prev) |prev| {
            for (prev) |set| interaction_gen.freeColumns(allocator, &set);
        }
        allocator.free(opcode_prev);
        for (opcode_memory_prev) |prev| {
            for (prev) |set| interaction_gen.freeColumns(allocator, &set);
        }
        allocator.free(opcode_memory_prev);
        for (&program_prev) |*set| interaction_gen.freeColumns(allocator, set);
        for (&merkle_prev) |*set| interaction_gen.freeColumns(allocator, set);
        for (&poseidon_prev) |*set| interaction_gen.freeColumns(allocator, set);
        for (0..statement.n_infra) |i| {
            if (statement.infra_descs[i].kind != .memory) continue;
            for (&memory_prev[i]) |*set| interaction_gen.freeColumns(allocator, set);
        }
        allocator.free(memory_prev);
    }

    {
        var stage = try stage_profile.StageScope.begin(recorder, "riscv_interaction_commit", "RISC-V interaction trace generation and commit");
        defer stage.end();

        // Rebuild per-family row lists (execution order) and chunk them by
        // MAX_OPCODE_SHARD_ROWS, mirroring the descriptor construction.
        var family_rows: [trace_mod.N_FAMILIES]std.ArrayList(trace_mod.TraceRow) =
            .{std.ArrayList(trace_mod.TraceRow).empty} ** trace_mod.N_FAMILIES;
        defer for (&family_rows) |*list| list.deinit(allocator);
        for (exec_trace.rows.items) |row| {
            const fi = @intFromEnum(trace_mod.opcodeFamily(row.opcode));
            try family_rows[fi].append(allocator, row);
        }

        const interaction_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_interaction);
        var inter_col_idx: usize = 0;
        var interaction_columns_moved = false;
        errdefer {
            if (!interaction_columns_moved) {
                for (interaction_columns[0..inter_col_idx]) |column| {
                    allocator.free(@constCast(column.values));
                }
                allocator.free(interaction_columns);
            }
        }

        var family_cursor: [trace_mod.N_FAMILIES]usize = .{0} ** trace_mod.N_FAMILIES;
        for (0..statement.n_components) |i| {
            const desc = statement.component_descs[i];
            const fi = @intFromEnum(desc.family);
            const remaining = family_rows[fi].items.len - family_cursor[fi];
            const shard_len = @min(remaining, MAX_OPCODE_SHARD_ROWS);
            std.debug.assert(shard_len > 0 and computeLogSize(shard_len) == desc.log_size);
            const shard = family_rows[fi].items[family_cursor[fi]..][0..shard_len];
            family_cursor[fi] += shard_len;

            const gen = try interaction_gen.genOpcodeInteraction(allocator, shard, desc.log_size, &relations);
            interaction_claim.state_claims[i] = gen.state_claim;
            interaction_claim.prog_claims[i] = gen.prog_claim;
            interaction_claim.opcode_memory_claims[i] = gen.memory_claims;
            opcode_prev[i] = .{ gen.prev_state, gen.prev_prog };
            opcode_memory_prev[i] = gen.prev_memory;
            for (gen.columns) |values| {
                interaction_columns[inter_col_idx] = .{ .log_size = desc.log_size, .values = values };
                inter_col_idx += 1;
            }
        }
        for (0..trace_mod.N_FAMILIES) |fi| {
            std.debug.assert(family_cursor[fi] == family_rows[fi].items.len);
        }

        const rom = try program_interaction.generate(
            allocator,
            program.rows,
            program_log_size,
            &relations,
        );
        interaction_claim.program_claims[0] = rom.claims.sums;
        program_prev = rom.previous;
        for (rom.columns) |values| {
            interaction_columns[inter_col_idx] = .{ .log_size = program_log_size, .values = values };
            inter_col_idx += 1;
        }

        if (boundary_claims) |claims| {
            var row_start: usize = 0;
            for (0..statement.n_infra) |infra_index| {
                const desc = statement.infra_descs[infra_index];
                if (desc.kind != .memory) continue;
                const row_end = row_start + desc.n_rows;
                const generated = try memory_interaction.generate(
                    allocator,
                    claims.rows[row_start..row_end],
                    desc.log_size,
                    &relations,
                );
                interaction_claim.memory_claims[infra_index] = generated.claims.sums;
                memory_prev[infra_index] = generated.previous;
                for (generated.columns) |values| {
                    interaction_columns[inter_col_idx] = .{ .log_size = desc.log_size, .values = values };
                    inter_col_idx += 1;
                }
                row_start = row_end;
            }
            std.debug.assert(row_start == claims.rows.len);
        }

        const merkle_interaction = try merkle_node.generateInteraction(
            allocator,
            merkle_rows,
            merkle_log_size,
            &relations,
        );
        interaction_claim.merkle_claims[merkle_infra_index] = merkle_interaction.claims.sums;
        merkle_prev = merkle_interaction.previous;
        for (merkle_interaction.columns) |values| {
            interaction_columns[inter_col_idx] = .{ .log_size = merkle_log_size, .values = values };
            inter_col_idx += 1;
        }

        const poseidon_interaction = try poseidon2_air.generateInteraction(
            allocator,
            poseidon_calls,
            poseidon_log_size,
            &relations,
        );
        interaction_claim.poseidon_claims[poseidon_infra_index] = poseidon_interaction.claims.sums;
        poseidon_prev = poseidon_interaction.previous;
        for (poseidon_interaction.columns) |values| {
            interaction_columns[inter_col_idx] = .{ .log_size = poseidon_log_size, .values = values };
            inter_col_idx += 1;
        }
        std.debug.assert(inter_col_idx == n_interaction);

        try proof_transcript.mixInteractionClaim(&channel, &statement, &interaction_claim);
        interaction_columns_moved = true;
        try Engine.commit(&scheme, allocator, interaction_columns, recorder, &channel);
    }

    // -- Step 6: Create per-family components and prove. --
    const total_components = statement.n_components + statement.n_infra;
    var component_storage: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]RiscVTraceComponent = undefined;
    var hash_storage: [2]hash_component.HashComponent = undefined;
    var n_hash_components: usize = 0;
    var components_arr: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]prover_component.ComponentProver = undefined;

    var main_offset: usize = 0;
    var interaction_offset: usize = 0;
    // Opcode family components
    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = .{
                .family = statement.component_descs[i].family,
                .log_size = statement.component_descs[i].log_size,
                .n_rows = statement.component_descs[i].n_rows,
                .n_columns = statement.component_descs[i].n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .is_first_col_idx = 2 * i,
            .is_active_col_idx = 2 * i + 1,
            .main_col_offset = main_offset,
            .kind = .opcode,
            .relations = &relations,
            .interaction_col_offset = interaction_offset,
            .state_claim = interaction_claim.state_claims[i],
            .prog_claim = interaction_claim.prog_claims[i],
            .opcode_memory_claims = interaction_claim.opcode_memory_claims[i],
            .s_state_prev = constPrev(opcode_prev[i][0]),
            .s_prog_prev = constPrev(opcode_prev[i][1]),
            .s_opcode_memory_prev = constOpcodeMemoryPrev(opcode_memory_prev[i]),
        };
        components_arr[i] = component_storage[i].asProverComponent();
        main_offset += statement.component_descs[i].n_columns;
        interaction_offset += riscv_component.nInteractionCols(.opcode);
    }
    // Infrastructure components (same RiscVTraceComponent type, different descriptors)
    for (0..statement.n_infra) |i| {
        const idx = statement.n_components + i;
        const kind: riscv_component.Kind = switch (statement.infra_descs[i].kind) {
            .program => .program,
            .memory => .memory,
            else => .silent,
        };
        if (statement.infra_descs[i].kind == .poseidon2 or
            statement.infra_descs[i].kind == .merkle)
        {
            hash_storage[n_hash_components] = .{
                .kind = if (statement.infra_descs[i].kind == .poseidon2) .poseidon2 else .merkle,
                .log_size = statement.infra_descs[i].log_size,
                .n_rows = statement.infra_descs[i].n_rows,
                .is_first_col_idx = 2 * idx,
                .is_active_col_idx = 2 * idx + 1,
                .main_col_offset = main_offset,
                .interaction_col_offset = interaction_offset,
                .relations = &relations,
                .merkle_claims = interaction_claim.merkle_claims[i],
                .poseidon_claims = interaction_claim.poseidon_claims[i],
                .s_merkle_prev = constMerklePrev(merkle_prev),
                .s_poseidon_prev = constPoseidonPrev(poseidon_prev),
            };
            components_arr[idx] = hash_storage[n_hash_components].asProverComponent();
            n_hash_components += 1;
            main_offset += statement.infra_descs[i].n_columns;
            interaction_offset += statement_mod.nInteractionColsForInfra(statement.infra_descs[i].kind);
            continue;
        }
        component_storage[idx] = .{
            .desc = .{
                .family = .base_alu_reg, // placeholder family for infra
                .log_size = statement.infra_descs[i].log_size,
                .n_rows = statement.infra_descs[i].n_rows,
                .n_columns = statement.infra_descs[i].n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .is_first_col_idx = 2 * idx,
            .is_active_col_idx = 2 * idx + 1,
            .main_col_offset = main_offset,
            .kind = kind,
            .relations = &relations,
            .interaction_col_offset = interaction_offset,
            .program_claims = interaction_claim.program_claims[i],
            .s_program_prev = constProgramPrev(program_prev),
            .memory_claims = interaction_claim.memory_claims[i],
            .s_memory_prev = constMemoryPrev(memory_prev[i]),
        };
        components_arr[idx] = component_storage[idx].asProverComponent();
        main_offset += statement.infra_descs[i].n_columns;
        interaction_offset += statement_mod.nInteractionColsForInfra(statement.infra_descs[i].kind);
    }

    scheme_owned = false;
    var extended = try Engine.prove(
        allocator,
        components_arr[0..total_components],
        &channel,
        scheme,
        .{ .recorder = recorder },
    );
    const proof = extended.proof;
    extended.aux.deinit(allocator);

    return .{ .statement = statement, .proof = proof, .interaction_claim = interaction_claim };
}

fn constPrev(bufs: [4][]M31) [4][]const M31 {
    return .{ bufs[0], bufs[1], bufs[2], bufs[3] };
}

fn constMemoryPrev(bufs: memory_interaction.Previous) [memory_interaction.N_SUMS][4][]const M31 {
    var result: [memory_interaction.N_SUMS][4][]const M31 = undefined;
    for (&result, bufs) |*dst, src| dst.* = constPrev(src);
    return result;
}

fn constProgramPrev(bufs: program_interaction.Previous) [program_interaction.N_SUMS][4][]const M31 {
    var result: [program_interaction.N_SUMS][4][]const M31 = undefined;
    for (&result, bufs) |*dst, src| dst.* = constPrev(src);
    return result;
}

fn constMerklePrev(bufs: merkle_node.Previous) [merkle_node.N_SUMS][4][]const M31 {
    var result: [merkle_node.N_SUMS][4][]const M31 = undefined;
    for (&result, bufs) |*dst, src| dst.* = constPrev(src);
    return result;
}

fn constPoseidonPrev(bufs: poseidon2_air.Previous) [poseidon2_air.N_SUMS][4][]const M31 {
    var result: [poseidon2_air.N_SUMS][4][]const M31 = undefined;
    for (&result, bufs) |*dst, src| dst.* = constPrev(src);
    return result;
}

fn constOpcodeMemoryPrev(bufs: opcode_memory.Previous) [opcode_memory.N_ACCESSES][4][]const M31 {
    var result: [opcode_memory.N_ACCESSES][4][]const M31 = undefined;
    for (&result, bufs) |*dst, src| dst.* = constPrev(src);
    return result;
}

/// Verify a RISC-V STARK proof with per-opcode-family components.
/// Consumes `proof_in` on both success and failure.
pub fn verifyRiscVWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    statement: RiscVStatement,
    proof_in: Proof,
    claim: RiscVInteractionClaim,
) !void {
    comptime prover_engine.assertProverEngine(Engine);
    var proof = proof_in;
    var proof_moved = false;
    defer if (!proof_moved) proof.deinit(allocator);

    try validateStatement(statement);
    if (claim.n_components != statement.n_components) {
        return ProverError.InvalidInteractionClaim;
    }
    if (proof.commitment_scheme_proof.commitments.items.len != 4) {
        return core_verifier.VerificationError.InvalidStructure;
    }
    try verifyPreprocessedRoot(
        Engine,
        allocator,
        pcs_config,
        statement,
        proof.commitment_scheme_proof.commitments.items[0],
    );

    var channel = Channel{};
    statement.public_data.mixInto(&channel);

    var commitment_scheme = try pcs_verifier.CommitmentSchemeVerifier(
        Hasher,
        MerkleChannel,
    ).init(allocator, pcs_config);
    defer commitment_scheme.deinit(allocator);

    // Tree 0: deterministic IsFirst/IsActive pairs for every component.
    const n_preproc_v = 2 * (statement.n_components + statement.n_infra);
    const preproc_log_sizes = try allocator.alloc(u32, n_preproc_v);
    defer allocator.free(preproc_log_sizes);
    for (0..statement.n_components) |i| {
        preproc_log_sizes[2 * i] = statement.component_descs[i].log_size;
        preproc_log_sizes[2 * i + 1] = statement.component_descs[i].log_size;
    }
    for (0..statement.n_infra) |i| {
        const base = 2 * (statement.n_components + i);
        preproc_log_sizes[base] = statement.infra_descs[i].log_size;
        preproc_log_sizes[base + 1] = statement.infra_descs[i].log_size;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[0],
        preproc_log_sizes,
        &channel,
    );

    // Tree 1: Main trace -- opcode columns + infrastructure columns.
    const n_main = statement.nMainColumns();
    const main_log_sizes = try allocator.alloc(u32, n_main);
    defer allocator.free(main_log_sizes);
    var col_offset: usize = 0;
    // Opcode family columns.
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        for (0..desc.n_columns) |c| {
            main_log_sizes[col_offset + c] = desc.log_size;
        }
        col_offset += desc.n_columns;
    }
    // Infrastructure columns (must match prover order).
    for (0..statement.n_infra) |i| {
        const idesc = statement.infra_descs[i];
        for (0..idesc.n_columns) |c| {
            main_log_sizes[col_offset + c] = idesc.log_size;
        }
        col_offset += idesc.n_columns;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[1],
        main_log_sizes,
        &channel,
    );

    const relations = try proof_transcript.verifyToRelations(
        allocator,
        &channel,
        &statement,
        claim.interaction_pow,
    );

    const n_interaction = statement.nInteractionColumns();
    const interaction_log_sizes = try allocator.alloc(u32, n_interaction);
    defer allocator.free(interaction_log_sizes);
    var inter_col_offset: usize = 0;
    for (0..statement.n_components) |i| {
        const n_cols = riscv_component.nInteractionCols(.opcode);
        for (0..n_cols) |c| {
            interaction_log_sizes[inter_col_offset + c] = statement.component_descs[i].log_size;
        }
        inter_col_offset += n_cols;
    }
    for (0..statement.n_infra) |i| {
        const n_cols = statement_mod.nInteractionColsForInfra(statement.infra_descs[i].kind);
        for (0..n_cols) |c| {
            interaction_log_sizes[inter_col_offset + c] = statement.infra_descs[i].log_size;
        }
        inter_col_offset += n_cols;
    }
    std.debug.assert(inter_col_offset == n_interaction);
    try proof_transcript.mixInteractionClaim(&channel, &statement, &claim);
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[2],
        interaction_log_sizes,
        &channel,
    );

    // Relation domains cancel independently; a shifted state claim must not
    // be repairable by an offsetting program claim.
    const state_boundary = try public_logup.registersStateSum(
        &statement.public_data,
        &relations,
    );
    const state_claims = try allocator.alloc(QM31, statement.n_components);
    defer allocator.free(state_claims);
    for (0..statement.n_components) |i| {
        state_claims[i] = claim.state_claims[i];
    }
    try logup.verifyGlobalCancellation(state_claims, state_boundary);

    // Reconstruct per-family + infrastructure verifier components.
    const total_v_components = statement.n_components + statement.n_infra;
    var component_storage: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]RiscVTraceComponent = undefined;
    var hash_storage: [2]hash_component.HashComponent = undefined;
    var n_hash_components: usize = 0;
    var verifier_components: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]core_air_components.Component = undefined;

    var verifier_col_offset: usize = 0;
    var verifier_inter_offset: usize = 0;
    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = statement.component_descs[i],
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .is_first_col_idx = 2 * i,
            .is_active_col_idx = 2 * i + 1,
            .main_col_offset = verifier_col_offset,
            .kind = .opcode,
            .relations = &relations,
            .interaction_col_offset = verifier_inter_offset,
            .state_claim = claim.state_claims[i],
            .prog_claim = claim.prog_claims[i],
            .opcode_memory_claims = claim.opcode_memory_claims[i],
        };
        verifier_components[i] = component_storage[i].asVerifierComponent();
        verifier_col_offset += statement.component_descs[i].n_columns;
        verifier_inter_offset += riscv_component.nInteractionCols(.opcode);
    }
    for (0..statement.n_infra) |i| {
        const idx = statement.n_components + i;
        const kind: riscv_component.Kind = switch (statement.infra_descs[i].kind) {
            .program => .program,
            .memory => .memory,
            else => .silent,
        };
        if (statement.infra_descs[i].kind == .poseidon2 or
            statement.infra_descs[i].kind == .merkle)
        {
            hash_storage[n_hash_components] = .{
                .kind = if (statement.infra_descs[i].kind == .poseidon2) .poseidon2 else .merkle,
                .log_size = statement.infra_descs[i].log_size,
                .n_rows = statement.infra_descs[i].n_rows,
                .is_first_col_idx = 2 * idx,
                .is_active_col_idx = 2 * idx + 1,
                .main_col_offset = verifier_col_offset,
                .interaction_col_offset = verifier_inter_offset,
                .relations = &relations,
                .merkle_claims = claim.merkle_claims[i],
                .poseidon_claims = claim.poseidon_claims[i],
            };
            verifier_components[idx] = hash_storage[n_hash_components].asVerifierComponent();
            n_hash_components += 1;
            verifier_col_offset += statement.infra_descs[i].n_columns;
            verifier_inter_offset += statement_mod.nInteractionColsForInfra(statement.infra_descs[i].kind);
            continue;
        }
        component_storage[idx] = .{
            .desc = .{
                .family = .base_alu_reg,
                .log_size = statement.infra_descs[i].log_size,
                .n_rows = statement.infra_descs[i].n_rows,
                .n_columns = statement.infra_descs[i].n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .is_first_col_idx = 2 * idx,
            .is_active_col_idx = 2 * idx + 1,
            .main_col_offset = verifier_col_offset,
            .kind = kind,
            .relations = &relations,
            .interaction_col_offset = verifier_inter_offset,
            .program_claims = claim.program_claims[i],
            .memory_claims = claim.memory_claims[i],
        };
        verifier_components[idx] = component_storage[idx].asVerifierComponent();
        verifier_col_offset += statement.infra_descs[i].n_columns;
        verifier_inter_offset += statement_mod.nInteractionColsForInfra(statement.infra_descs[i].kind);
    }

    proof_moved = true;
    try core_verifier.verify(
        Hasher,
        MerkleChannel,
        allocator,
        verifier_components[0..total_v_components],
        &channel,
        &commitment_scheme,
        proof,
    );
}

/// Run a RISC-V ELF, prove execution, and verify the proof.
/// Verification consumes the proof; the returned public-I/O slices are owned.
pub fn proveAndVerifyElfWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
    max_steps: usize,
    pcs_config: pcs_core.PcsConfig,
) !OwnedRiscVStatement {
    var run_result = try runner_mod.run(allocator, elf_bytes, max_steps);
    defer run_result.deinit();

    const input_words = try public_data_mod.packInputWords(allocator, run_result.input);
    errdefer allocator.free(input_words);
    const output_words = try allocator.alloc(public_data_mod.OutputWord, run_result.output_words.len);
    errdefer allocator.free(output_words);
    for (run_result.output_words, 0..) |word, i| output_words[i] = .{
        .addr = word.addr,
        .value = word.value,
        .clock = word.clock,
    };
    const public_data = PublicData{
        .initial_pc = run_result.initial_pc,
        .final_pc = run_result.final_pc,
        .clock = @intCast(run_result.step_count),
        .initial_regs = run_result.initial_regs,
        .final_regs = run_result.final_regs,
        .reg_last_clock = run_result.state_chain_tracker.reg_last_clk,
        .program_root = null,
        .initial_rw_root = null,
        .final_rw_root = null,
        .io_entries = .{
            .input_start = run_result.input_start,
            .input_len = @intCast(run_result.input.len),
            .input_words = input_words,
            .output_len = run_result.output_len,
            .output_len_addr = run_result.output_len_addr,
            .output_data_addr = run_result.output_data_addr,
            .output_words = output_words,
        },
    };
    const output = try proveRiscVWithEngineAndPublicData(
        Engine,
        allocator,
        pcs_config,
        &run_result.execution_trace,
        &run_result.state_chain_tracker,
        &run_result.rw_memory,
        null,
        public_data,
    );

    // Verify immediately (takes ownership of the proof).
    try verifyRiscVWithEngine(
        Engine,
        allocator,
        pcs_config,
        output.statement,
        output.proof,
        output.interaction_claim,
    );

    return OwnedRiscVStatement.init(output.statement, input_words, output_words);
}
