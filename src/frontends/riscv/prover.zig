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
const secure_column = @import("../../prover/secure_column.zig");
const circle = @import("../../core/circle.zig");

const runner_mod = @import("runner/mod.zig");
const trace_mod = @import("runner/trace.zig");
const trace_columns = @import("air/trace_columns.zig");
const component_order = @import("air/component_order.zig");
const clock_update_component = @import("air/clock_update_component.zig");
const clock_update_interaction = @import("air/clock_update_interaction.zig");
const interaction_gen = @import("air/interaction_gen.zig");
const opcode_component = @import("air/lookups/opcode_component.zig");
const opcode_entries = @import("air/lookups/opcode_entries.zig");
const opcode_interaction = @import("air/lookups/opcode_interaction.zig");
const lookup_table_component = @import("air/lookups/tables/component.zig");
const lookup_table_interaction = @import("air/lookups/tables/interaction.zig");
const lookup_table_schema = @import("air/lookups/tables/schema.zig");
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
const lookup_sources = @import("prover/lookup_sources.zig");
const opcode_trace = @import("prover/opcode_trace.zig");
const preprocessed_trace = @import("prover/preprocessed.zig");
const semantic_component = @import("air/semantic_component.zig");
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

fn computeOpcodeLogSize(count: usize) u32 {
    return @max(@as(u32, 4), computeLogSize(count));
}

fn validateStatement(statement: RiscVStatement) ProverError!void {
    if (statement.n_components == 0 or statement.n_components > MAX_COMPONENTS)
        return ProverError.InvalidStatement;
    if (statement.n_infra < 10 or statement.n_infra > MAX_INFRA_COMPONENTS)
        return ProverError.InvalidStatement;
    statement.public_data.validate() catch return ProverError.InvalidStatement;
    if (statement.public_data.initial_pc != statement.initial_pc or
        statement.public_data.final_pc != statement.final_pc or
        statement.public_data.clock != statement.total_steps or
        statement.public_data.io_entries.input_words.len !=
            std.math.divCeil(usize, statement.public_data.io_entries.input_len, 4) catch unreachable)
        return ProverError.InvalidStatement;

    var total_rows: u64 = 0;
    var previous_family_index: ?usize = null;
    var previous_rows: u32 = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        if (desc.log_size == 0 or desc.log_size > MAX_OPCODE_SHARD_LOG_SIZE or
            desc.n_rows == 0 or desc.n_rows > MAX_OPCODE_SHARD_ROWS or
            desc.log_size != computeOpcodeLogSize(desc.n_rows) or
            desc.n_columns != trace_mod.nColumnsForFamily(desc.family))
            return ProverError.InvalidStatement;
        const family_index = component_order.opcodeFamilyIndex(desc.family);
        if (previous_family_index) |previous| {
            if (family_index < previous) return ProverError.InvalidStatement;
            if (family_index == previous and previous_rows != MAX_OPCODE_SHARD_ROWS)
                return ProverError.InvalidStatement;
        }
        previous_family_index = family_index;
        previous_rows = desc.n_rows;
        total_rows += desc.n_rows;
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
    }
    if (index + 3 + component_order.LOOKUP_TABLE_COUNT != statement.n_infra)
        return ProverError.InvalidStatement;
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
    index += 3;
    for (component_order.lookupTables()) |kind| {
        const desc = statement.infra_descs[index];
        if (desc.kind != statement_mod.infraKindForTable(kind) or
            desc.log_size != lookup_table_schema.logSize(kind) or
            desc.n_rows != lookup_table_schema.size(kind) or
            desc.n_columns != 1)
            return ProverError.InvalidStatement;
        index += 1;
    }
    std.debug.assert(index == statement.n_infra);
    if (program.n_rows > (@as(usize, 1) << @intCast(program.log_size)) or
        program.log_size != computeLogSize(program.n_rows))
        return ProverError.InvalidStatement;
}

fn verifyPreprocessedRoot(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    statement: RiscVStatement,
    actual: Hasher.Hash,
) !void {
    const columns = try preprocessed_trace.generate(allocator, statement);
    var columns_moved = false;
    errdefer if (!columns_moved) {
        for (columns) |column| allocator.free(@constCast(column.values));
        allocator.free(columns);
    };

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

    for (component_order.opcodeFamilies()) |family| {
        const count = counts.get(family);
        if (count == 0) continue;

        var remaining = count;
        while (remaining > 0) {
            if (statement.n_components >= MAX_COMPONENTS) return ProverError.TooManyOpcodeComponents;
            const shard_len = @min(remaining, MAX_OPCODE_SHARD_ROWS);
            statement.component_descs[statement.n_components] = .{
                .family = family,
                .log_size = computeOpcodeLogSize(shard_len),
                .n_rows = @intCast(shard_len),
                .n_columns = trace_mod.nColumnsForFamily(family),
            };
            statement.n_components += 1;
            remaining -= shard_len;
        }
    }

    if (statement.n_components == 0) return ProverError.EmptyTrace;

    // -- Step 2b: Build infrastructure component descriptors. --
    statement.n_infra = 0;

    // Exact sparse decoded-program commitment (8 columns).
    const program_log_size = computeLogSize(program.rows.len);
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
    const clock_infra_index = statement.n_infra;
    statement.infra_descs[clock_infra_index] = .{
        .kind = .clock_update,
        .log_size = clock_update_log,
        .n_rows = if (opt_chain) |chain| @intCast(
            chain.clock_updates_mem.items.len + chain.clock_updates_reg.items.len,
        ) else 0,
        .n_columns = infra.CLOCK_UPDATE_COLS,
    };
    statement.n_infra += 1;

    for (component_order.lookupTables()) |kind| {
        if (statement.n_infra == MAX_INFRA_COMPONENTS)
            return ProverError.TooManyInfrastructureComponents;
        statement.infra_descs[statement.n_infra] = .{
            .kind = statement_mod.infraKindForTable(kind),
            .log_size = lookup_table_schema.logSize(kind),
            .n_rows = @intCast(lookup_table_schema.size(kind)),
            .n_columns = 1,
        };
        statement.n_infra += 1;
    }
    try validateStatement(statement);

    var channel = Channel{};
    statement.public_data.mixInto(&channel);

    var scheme = try Engine.init(allocator, pcs_config);
    var scheme_owned = true;
    errdefer if (scheme_owned) Engine.deinit(&scheme, allocator);

    // Empty state chain for fallback when opt_chain is null.
    var empty_chain = state_chain.StateChainTracker.init(allocator);
    defer empty_chain.deinit();

    // -- Step 3: Tree 0 -- selectors and exact lookup-table tuples. --
    {
        var stage = try stage_profile.StageScope.begin(recorder, "riscv_preprocessed_commit", "RISC-V preprocessed trace commit");
        defer stage.end();
        const preprocessed = try preprocessed_trace.generate(allocator, statement);
        var moved = false;
        errdefer if (!moved) {
            for (preprocessed) |column| allocator.free(@constCast(column.values));
            allocator.free(preprocessed);
        };
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
        result: opcode_trace.Columns = undefined,
        err: ?anyerror = null,

        fn run(work: *@This()) void {
            work.result = opcode_trace.generate(
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
    var opcode_cleanup_on_error = true;
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
        if (opcode_cleanup_on_error and opcode_work.err == null) {
            opcode_work.result.deinit(allocator, statement);
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

    var clock_main: [clock_update_interaction.N_MAIN_COLUMNS][]M31 =
        .{&.{}} ** clock_update_interaction.N_MAIN_COLUMNS;
    var clock_main_initialized = false;
    defer if (clock_main_initialized) {
        for (clock_main) |column| allocator.free(column);
    };

    // Unified register + memory clock update (8 cols).
    {
        const chain_ptr = opt_chain orelse &empty_chain;
        const cu_cols = try infra.genClockUpdateColumns(allocator, chain_ptr, clock_update_log);
        clock_main = cu_cols.columns;
        clock_main_initialized = true;
        for (0..infra.CLOCK_UPDATE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = clock_update_log,
                .values = try allocator.dupe(M31, clock_main[c]),
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
    opcode_cleanup_on_error = false;
    defer opcode_work.result.deinit(allocator, statement);

    // Derive table multiplicities from the exact family buffers that will be
    // committed below. This keeps both the lookup source and its commitment on
    // one witness path, including any future pre-commit mutation hook.
    var lookup_source = try lookup_sources.ingest(allocator, statement, &opcode_work.result);
    defer lookup_source.deinit(allocator);
    if (boundary_claims) |claims| {
        try lookup_sources.registerMemoryBoundary(&lookup_source.counters, claims.rows);
    }
    try clock_update_interaction.registerRangeCheck20Counter(
        lookup_source.counters.get(.range_check_20),
    );
    for (component_order.lookupTables()) |kind| {
        const counter = &lookup_source.counters.counters[@intFromEnum(kind)];
        main_columns[col_offset] = .{
            .log_size = lookup_table_schema.logSize(kind),
            .values = try counter.committedColumn(allocator),
        };
        main_initialized[col_offset] = true;
        col_offset += 1;
    }

    var opcode_col_offset: usize = 0;
    for (0..statement.n_components) |comp_idx| {
        const desc = statement.component_descs[comp_idx];
        const generated = &opcode_work.result.components[comp_idx];
        if (generated.n_columns != desc.n_columns) return ProverError.InvalidStatement;
        for (generated.columns[0..generated.n_columns], 0..) |values, column| {
            main_columns[opcode_col_offset + column] = .{
                .log_size = desc.log_size,
                .values = try allocator.dupe(M31, values),
            };
            main_initialized[opcode_col_offset + column] = true;
        }
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

    // Tree 2 carries exact declaration-order opcode and infrastructure
    // interactions generated from byte-identical base buffers retained across
    // the Tree1 commitment.
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

    // Shifted cumulative columns remain alive through composition evaluation.
    // Opcode interactions consume the exact values retained by Tree 1.
    var opcode_results: [MAX_COMPONENTS]opcode_interaction.Result = undefined;
    var n_opcode_results: usize = 0;
    defer for (opcode_results[0..n_opcode_results]) |*result| result.deinit(allocator);
    var table_results: [component_order.LOOKUP_TABLE_COUNT]lookup_table_interaction.Result = undefined;
    var n_table_results: usize = 0;
    defer for (table_results[0..n_table_results]) |*result| result.deinit(allocator);
    var clock_result: ?clock_update_interaction.InteractionTrace = null;
    defer if (clock_result) |*result| result.deinit(allocator);
    var program_prev: program_interaction.Previous =
        .{.{ &.{}, &.{}, &.{}, &.{} }} ** program_interaction.N_SUMS;
    var merkle_prev: merkle_node.Previous =
        .{.{ &.{}, &.{}, &.{}, &.{} }} ** merkle_node.N_SUMS;
    var poseidon_prev: poseidon2_air.Previous =
        .{.{ &.{}, &.{}, &.{}, &.{} }} ** poseidon2_air.N_SUMS;
    const memory_prev = try allocator.alloc(memory_interaction.Previous, statement.n_infra);
    for (memory_prev) |*prev| prev.* = .{.{ &.{}, &.{}, &.{}, &.{} }} ** memory_interaction.N_SUMS;
    defer {
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

        var opcode_main_offset: usize = 0;
        for (0..statement.n_components) |i| {
            const desc = statement.component_descs[i];
            const n_family_columns: usize = @intCast(desc.n_columns);
            var family_columns: [trace_mod.MAX_FAMILY_COLUMNS][]const M31 = undefined;
            for (
                opcode_work.result.components[i].columns[0..n_family_columns],
                family_columns[0..n_family_columns],
            ) |column, *values| values.* = column;
            opcode_results[n_opcode_results] = try opcode_interaction.generate(
                allocator,
                desc.family,
                family_columns[0..n_family_columns],
                desc.log_size,
                &relations,
            );
            const generated = &opcode_results[n_opcode_results];
            n_opcode_results += 1;
            @memcpy(
                interaction_claim.opcode_claims[i][0..generated.n_batches],
                generated.claims[0..generated.n_batches],
            );
            const columns = generated.takeColumns();
            for (columns[0..generated.nColumns()]) |values| {
                interaction_columns[inter_col_idx] = .{ .log_size = desc.log_size, .values = values };
                inter_col_idx += 1;
            }
            opcode_main_offset += n_family_columns;
        }
        std.debug.assert(opcode_main_offset == n_opcode_main);

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

        var clock_views: [clock_update_interaction.N_MAIN_COLUMNS][]const M31 = undefined;
        for (&clock_views, clock_main) |*view, column| view.* = column;
        clock_result = try clock_update_interaction.generate(
            allocator,
            &clock_views,
            clock_update_log,
            &relations,
        );
        interaction_claim.clock_claims[clock_infra_index] = clock_result.?.claim;
        const clock_columns = clock_result.?.takeColumns();
        for (clock_columns) |values| {
            interaction_columns[inter_col_idx] = .{
                .log_size = clock_update_log,
                .values = values,
            };
            inter_col_idx += 1;
        }

        const table_infra_start = statement.n_infra - component_order.LOOKUP_TABLE_COUNT;
        for (component_order.lookupTables(), 0..) |kind, table_index| {
            const infra_index = table_infra_start + table_index;
            table_results[n_table_results] = try lookup_table_interaction.generate(
                allocator,
                &lookup_source.counters.counters[@intFromEnum(kind)],
                &relations,
            );
            const generated = &table_results[n_table_results];
            n_table_results += 1;
            interaction_claim.lookup_claims[infra_index] = generated.claim;
            const columns = generated.takeColumns();
            for (columns) |values| {
                interaction_columns[inter_col_idx] = .{
                    .log_size = lookup_table_schema.logSize(kind),
                    .values = values,
                };
                inter_col_idx += 1;
            }
        }
        std.debug.assert(inter_col_idx == n_interaction);

        try proof_transcript.mixInteractionClaim(&channel, &statement, &interaction_claim);
        interaction_columns_moved = true;
        try Engine.commit(&scheme, allocator, interaction_columns, recorder, &channel);
    }

    // -- Step 6: Pair semantic owners with exact lookup consumers. --
    var semantic_storage: [MAX_COMPONENTS]semantic_component.SemanticComponent = undefined;
    var opcode_lookup_storage: [MAX_COMPONENTS]opcode_component.OpcodeLookupComponent = undefined;
    var infra_storage: [MAX_INFRA_COMPONENTS]RiscVTraceComponent = undefined;
    var hash_storage: [2]hash_component.HashComponent = undefined;
    var n_hash_components: usize = 0;
    var clock_storage: clock_update_component.ClockUpdateComponent = undefined;
    var table_storage: [component_order.LOOKUP_TABLE_COUNT]lookup_table_component.LookupTableComponent = undefined;
    var components_arr: [2 * MAX_COMPONENTS + MAX_INFRA_COMPONENTS]prover_component.ComponentProver = undefined;
    var total_components: usize = 0;

    var main_offset: usize = 0;
    var interaction_offset: usize = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        semantic_storage[i] = try semantic_component.SemanticComponent.init(
            desc.family,
            desc.log_size,
            2 * i + 1,
            main_offset,
        );
        components_arr[total_components] = semantic_storage[i].asProverComponent();
        total_components += 1;
        opcode_lookup_storage[i] = try opcode_component.OpcodeLookupComponent.initProver(
            desc.family,
            desc.log_size,
            2 * i,
            main_offset,
            interaction_offset,
            &relations,
            try interaction_claim.opcodeClaims(desc.family, i),
            constOpcodePrev(opcode_results[i].previous),
        );
        components_arr[total_components] = opcode_lookup_storage[i].asProverComponent();
        total_components += 1;
        main_offset += desc.n_columns;
        interaction_offset += opcode_interaction.nColumns(desc.family);
    }

    for (0..statement.n_infra) |i| {
        const desc = statement.infra_descs[i];
        const preprocessed_base = statement.preprocessedOffsetForInfra(i);
        if (desc.kind == .poseidon2 or desc.kind == .merkle) {
            hash_storage[n_hash_components] = .{
                .kind = if (desc.kind == .poseidon2) .poseidon2 else .merkle,
                .log_size = desc.log_size,
                .n_rows = desc.n_rows,
                .is_first_col_idx = preprocessed_base,
                .is_active_col_idx = preprocessed_base + 1,
                .main_col_offset = main_offset,
                .interaction_col_offset = interaction_offset,
                .relations = &relations,
                .merkle_claims = interaction_claim.merkle_claims[i],
                .poseidon_claims = interaction_claim.poseidon_claims[i],
                .s_merkle_prev = constMerklePrev(merkle_prev),
                .s_poseidon_prev = constPoseidonPrev(poseidon_prev),
            };
            components_arr[total_components] = hash_storage[n_hash_components].asProverComponent();
            total_components += 1;
            n_hash_components += 1;
            main_offset += desc.n_columns;
            interaction_offset += statement_mod.nInteractionColsForInfra(desc.kind);
            continue;
        }
        if (statement_mod.tableKind(desc.kind)) |table_kind| {
            const table_index = component_order.lookupTableIndex(table_kind);
            var tuple_indices: [lookup_table_schema.MAX_ARITY]usize = undefined;
            for (tuple_indices[0..lookup_table_schema.arity(table_kind)], 0..) |*index, offset| {
                index.* = preprocessed_base + 1 + offset;
            }
            table_storage[table_index] = try lookup_table_component.LookupTableComponent.initProver(
                table_kind,
                preprocessed_base,
                tuple_indices[0..lookup_table_schema.arity(table_kind)],
                main_offset,
                interaction_offset,
                &relations,
                interaction_claim.lookup_claims[i],
                constPrev(table_results[table_index].previous),
            );
            components_arr[total_components] = table_storage[table_index].asProverComponent();
            total_components += 1;
            main_offset += desc.n_columns;
            interaction_offset += lookup_table_interaction.N_COLUMNS;
            continue;
        }
        if (desc.kind == .clock_update) {
            clock_storage = try clock_update_component.ClockUpdateComponent.initProver(
                desc.log_size,
                preprocessed_base,
                preprocessed_base + 1,
                main_offset,
                interaction_offset,
                &relations,
                interaction_claim.clock_claims[i],
                constPrev(clock_result.?.previous),
            );
            components_arr[total_components] = clock_storage.asProverComponent();
            total_components += 1;
            main_offset += desc.n_columns;
            interaction_offset += clock_update_interaction.N_INTERACTION_COLUMNS;
            continue;
        }
        const kind: riscv_component.Kind = switch (desc.kind) {
            .program => .program,
            .memory => .memory,
            else => return ProverError.InvalidStatement,
        };
        infra_storage[i] = .{
            .desc = .{
                .family = .base_alu_reg,
                .log_size = desc.log_size,
                .n_rows = desc.n_rows,
                .n_columns = desc.n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .is_first_col_idx = preprocessed_base,
            .is_active_col_idx = preprocessed_base + 1,
            .main_col_offset = main_offset,
            .kind = kind,
            .relations = &relations,
            .interaction_col_offset = interaction_offset,
            .program_claims = interaction_claim.program_claims[i],
            .s_program_prev = constProgramPrev(program_prev),
            .memory_claims = interaction_claim.memory_claims[i],
            .s_memory_prev = constMemoryPrev(memory_prev[i]),
        };
        components_arr[total_components] = infra_storage[i].asProverComponent();
        total_components += 1;
        main_offset += desc.n_columns;
        interaction_offset += statement_mod.nInteractionColsForInfra(desc.kind);
    }
    std.debug.assert(main_offset == n_main);
    std.debug.assert(interaction_offset == n_interaction);

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

fn constOpcodePrev(
    bufs: [opcode_interaction.MAX_BATCHES][4][]M31,
) [opcode_interaction.MAX_BATCHES][4][]const M31 {
    var result: [opcode_interaction.MAX_BATCHES][4][]const M31 = undefined;
    for (&result, bufs) |*dst, src| dst.* = constPrev(src);
    return result;
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
    if (claim.n_components != statement.n_components or claim.n_infra != statement.n_infra) {
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

    // Tree 0: selector pairs plus exact lookup-table tuple columns.
    const preproc_log_sizes = try preprocessed_trace.logSizes(allocator, statement);
    defer allocator.free(preproc_log_sizes);
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
        const n_cols = opcode_interaction.nColumns(statement.component_descs[i].family);
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

    const canonical = try claim.canonical(&statement);
    const canonical_view = canonical.view();
    try logup.verifyGlobalCancellation(
        &.{canonical_view.total()},
        try public_logup.sum(&statement.public_data, &relations),
    );

    // Reconstruct the exact prover component ordering and ownership split.
    var semantic_storage: [MAX_COMPONENTS]semantic_component.SemanticComponent = undefined;
    var opcode_lookup_storage: [MAX_COMPONENTS]opcode_component.OpcodeLookupComponent = undefined;
    var infra_storage: [MAX_INFRA_COMPONENTS]RiscVTraceComponent = undefined;
    var hash_storage: [2]hash_component.HashComponent = undefined;
    var n_hash_components: usize = 0;
    var clock_storage: clock_update_component.ClockUpdateComponent = undefined;
    var table_storage: [component_order.LOOKUP_TABLE_COUNT]lookup_table_component.LookupTableComponent = undefined;
    var verifier_components: [2 * MAX_COMPONENTS + MAX_INFRA_COMPONENTS]core_air_components.Component = undefined;
    var total_v_components: usize = 0;

    var verifier_col_offset: usize = 0;
    var verifier_inter_offset: usize = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        semantic_storage[i] = try semantic_component.SemanticComponent.init(
            desc.family,
            desc.log_size,
            2 * i + 1,
            verifier_col_offset,
        );
        verifier_components[total_v_components] = semantic_storage[i].asVerifierComponent();
        total_v_components += 1;
        opcode_lookup_storage[i] = try opcode_component.OpcodeLookupComponent.initVerifier(
            desc.family,
            desc.log_size,
            2 * i,
            verifier_col_offset,
            verifier_inter_offset,
            &relations,
            try claim.opcodeClaims(desc.family, i),
        );
        verifier_components[total_v_components] = opcode_lookup_storage[i].asVerifierComponent();
        total_v_components += 1;
        verifier_col_offset += desc.n_columns;
        verifier_inter_offset += opcode_interaction.nColumns(desc.family);
    }
    for (0..statement.n_infra) |i| {
        const desc = statement.infra_descs[i];
        const preprocessed_base = statement.preprocessedOffsetForInfra(i);
        if (desc.kind == .poseidon2 or desc.kind == .merkle) {
            hash_storage[n_hash_components] = .{
                .kind = if (desc.kind == .poseidon2) .poseidon2 else .merkle,
                .log_size = desc.log_size,
                .n_rows = desc.n_rows,
                .is_first_col_idx = preprocessed_base,
                .is_active_col_idx = preprocessed_base + 1,
                .main_col_offset = verifier_col_offset,
                .interaction_col_offset = verifier_inter_offset,
                .relations = &relations,
                .merkle_claims = claim.merkle_claims[i],
                .poseidon_claims = claim.poseidon_claims[i],
            };
            verifier_components[total_v_components] = hash_storage[n_hash_components].asVerifierComponent();
            total_v_components += 1;
            n_hash_components += 1;
            verifier_col_offset += desc.n_columns;
            verifier_inter_offset += statement_mod.nInteractionColsForInfra(desc.kind);
            continue;
        }
        if (statement_mod.tableKind(desc.kind)) |table_kind| {
            const table_index = component_order.lookupTableIndex(table_kind);
            var tuple_indices: [lookup_table_schema.MAX_ARITY]usize = undefined;
            for (tuple_indices[0..lookup_table_schema.arity(table_kind)], 0..) |*index, offset| {
                index.* = preprocessed_base + 1 + offset;
            }
            table_storage[table_index] = try lookup_table_component.LookupTableComponent.initVerifier(
                table_kind,
                preprocessed_base,
                tuple_indices[0..lookup_table_schema.arity(table_kind)],
                verifier_col_offset,
                verifier_inter_offset,
                &relations,
                claim.lookup_claims[i],
            );
            verifier_components[total_v_components] = table_storage[table_index].asVerifierComponent();
            total_v_components += 1;
            verifier_col_offset += desc.n_columns;
            verifier_inter_offset += lookup_table_interaction.N_COLUMNS;
            continue;
        }
        if (desc.kind == .clock_update) {
            clock_storage = clock_update_component.ClockUpdateComponent.initVerifier(
                desc.log_size,
                preprocessed_base,
                preprocessed_base + 1,
                verifier_col_offset,
                verifier_inter_offset,
                &relations,
                claim.clock_claims[i],
            );
            verifier_components[total_v_components] = clock_storage.asVerifierComponent();
            total_v_components += 1;
            verifier_col_offset += desc.n_columns;
            verifier_inter_offset += clock_update_interaction.N_INTERACTION_COLUMNS;
            continue;
        }
        const kind: riscv_component.Kind = switch (desc.kind) {
            .program => .program,
            .memory => .memory,
            else => return ProverError.InvalidStatement,
        };
        infra_storage[i] = .{
            .desc = .{
                .family = .base_alu_reg,
                .log_size = desc.log_size,
                .n_rows = desc.n_rows,
                .n_columns = desc.n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .is_first_col_idx = preprocessed_base,
            .is_active_col_idx = preprocessed_base + 1,
            .main_col_offset = verifier_col_offset,
            .kind = kind,
            .relations = &relations,
            .interaction_col_offset = verifier_inter_offset,
            .program_claims = claim.program_claims[i],
            .memory_claims = claim.memory_claims[i],
        };
        verifier_components[total_v_components] = infra_storage[i].asVerifierComponent();
        total_v_components += 1;
        verifier_col_offset += desc.n_columns;
        verifier_inter_offset += statement_mod.nInteractionColsForInfra(desc.kind);
    }
    std.debug.assert(verifier_col_offset == n_main);
    std.debug.assert(verifier_inter_offset == n_interaction);

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
