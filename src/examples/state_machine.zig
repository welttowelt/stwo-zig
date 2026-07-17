const std = @import("std");
const core_air_accumulation = @import("../core/air/accumulation.zig");
const core_air_components = @import("../core/air/components.zig");
const core_air_derive = @import("../core/air/derive.zig");
const channel_blake2s = @import("../core/channel/blake2s.zig");
const m31 = @import("../core/fields/m31.zig");
const qm31 = @import("../core/fields/qm31.zig");
const pcs_core = @import("../core/pcs/mod.zig");
const pcs_verifier = @import("../core/pcs/verifier.zig");
const core_proof = @import("../core/proof.zig");
const core_verifier = @import("../core/verifier.zig");
const blake2_merkle = @import("../core/vcs_lifted/blake2_merkle.zig");
const prover_air_accumulation = @import("../prover/air/accumulation.zig");
const prover_component = @import("../prover/air/component_prover.zig");
const prover_engine = @import("../prover/engine.zig");
const stage_profile = @import("../prover/stage_profile.zig");
const secure_column = @import("../prover/secure_column.zig");
const prover_transaction = @import("common/prover_transaction.zig");
const trace_input = @import("state_machine/input.zig");
const statement_impl = @import("state_machine/statement.zig");
const CpuBackend = @import("../backends/cpu_scalar/mod.zig").CpuBackend;

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = @import("../core/circle.zig").CirclePointQM31;

pub const State = trace_input.State;
pub const Hasher = blake2_merkle.Blake2sPrefixedMerkleHasher;
pub const MerkleChannel = blake2_merkle.Blake2sPrefixedMerkleChannel;
pub const Channel = channel_blake2s.Blake2sChannel;
pub const Proof = core_proof.StarkProof(Hasher);
pub const ExtendedProof = core_proof.ExtendedStarkProof(Hasher);
pub const CpuProverEngine = prover_engine.ProverEngine(
    CpuBackend,
    Hasher,
    MerkleChannel,
    Channel,
);

pub fn ProverEngineForBackend(comptime Backend: type) type {
    return prover_engine.ProverEngine(Backend, Hasher, MerkleChannel, Channel);
}

comptime {
    prover_engine.assertProverEngine(CpuProverEngine);
}

pub const Request = trace_input.Request;
pub const PreparedInput = trace_input.PreparedInput;
pub const prepareInput = trace_input.prepare;
pub const genTrace = trace_input.genTrace;
pub const deinitTrace = trace_input.deinitTrace;

pub const Error = trace_input.Error || statement_impl.Error || error{
    InvalidProofShape,
};

pub const TransitionStates = statement_impl.TransitionStates;
pub const Statement0 = statement_impl.Statement0;
pub const Statement1 = statement_impl.Statement1;
pub const PreparedStatement = statement_impl.PreparedStatement;
pub const Elements = statement_impl.Elements;
pub const transitionStates = statement_impl.transitionStates;
pub const claimedSumFromInitial = statement_impl.claimedSumFromInitial;
pub const claimedSumTelescoping = statement_impl.claimedSumTelescoping;
pub const claimsSatisfyStatement = statement_impl.claimsSatisfyStatement;
pub const prepareStatement = statement_impl.prepare;
pub const verifyStatement = statement_impl.verify;
const mixStatement0 = statement_impl.mixStatement0;
const mixPublicInput = statement_impl.mixPublicInput;
const mixStatement1 = statement_impl.mixStatement1;

pub const ProveOutput = struct {
    statement: PreparedStatement,
    proof: Proof,
};

pub const ProveExOutput = prover_transaction.Output(PreparedStatement, ExtendedProof);

/// Proves the state-machine statement using the shared component-driven prover flow.
///
/// Inputs:
/// - `pcs_config`: PCS/FRI configuration.
/// - `log_n_rows`: transition trace size exponent `n`.
/// - `initial_state`: public initial state.
///
/// Output:
/// - `ProveOutput` carrying the prepared statement and generated proof.
///
/// Failure modes:
/// - `Error.InvalidLogSize`/`Error.InvalidIncIndex` from trace/statement setup.
/// - allocator/prover failures from PCS/FRI/prover internals.
pub fn prove(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    log_n_rows: u32,
    initial_state: State,
) anyerror!ProveOutput {
    return proveWithEngine(
        CpuProverEngine,
        allocator,
        pcs_config,
        .{ .log_n_rows = log_n_rows, .initial_state = initial_state },
        null,
    );
}

/// Extended proving wrapper over `prover.proveEx`.
pub fn proveEx(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    log_n_rows: u32,
    initial_state: State,
    include_all_preprocessed_columns: bool,
) anyerror!ProveExOutput {
    return proveExWithEngine(
        CpuProverEngine,
        allocator,
        pcs_config,
        .{ .log_n_rows = log_n_rows, .initial_state = initial_state },
        include_all_preprocessed_columns,
        null,
    );
}

pub fn proveProfiled(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    log_n_rows: u32,
    initial_state: State,
    recorder: *stage_profile.Recorder,
) anyerror!ProveOutput {
    return proveWithEngine(
        CpuProverEngine,
        allocator,
        pcs_config,
        .{ .log_n_rows = log_n_rows, .initial_state = initial_state },
        recorder,
    );
}

pub fn proveWithBackend(
    comptime Backend: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    request: Request,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveOutput {
    return proveWithEngine(
        ProverEngineForBackend(Backend),
        allocator,
        pcs_config,
        request,
        recorder,
    );
}

pub fn proveWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    request: Request,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveOutput {
    var output = try proveExWithEngine(
        Engine,
        allocator,
        pcs_config,
        request,
        false,
        recorder,
    );
    const proof = output.proof.proof;
    output.proof.aux.deinit(allocator);
    return .{ .statement = output.statement, .proof = proof };
}

pub fn proveExWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    request: Request,
    include_all_preprocessed_columns: bool,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveExOutput {
    const prepared = blk: {
        var stage = try stage_profile.StageScope.begin(
            recorder,
            "trace_generation",
            "Trace generation",
        );
        defer stage.end();
        break :blk try prepareInput(allocator, request);
    };
    return provePreparedExImpl(
        Engine,
        false,
        {},
        allocator,
        pcs_config,
        prepared,
        include_all_preprocessed_columns,
        recorder,
    );
}

/// Proves a prepared State Machine trace and consumes it on every path.
pub fn provePreparedWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    prepared: PreparedInput,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveOutput {
    var output = try provePreparedExImpl(
        Engine,
        false,
        {},
        allocator,
        pcs_config,
        prepared,
        false,
        recorder,
    );
    const proof = output.proof.proof;
    output.proof.aux.deinit(allocator);
    return .{ .statement = output.statement, .proof = proof };
}

pub fn provePreparedExWithEngine(
    comptime Engine: type,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    prepared: PreparedInput,
    include_all_preprocessed_columns: bool,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveExOutput {
    return provePreparedExImpl(
        Engine,
        false,
        {},
        allocator,
        pcs_config,
        prepared,
        include_all_preprocessed_columns,
        recorder,
    );
}

pub fn provePreparedWithSessionAndEngine(
    comptime Engine: type,
    session: *const Engine.Session,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    prepared: PreparedInput,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveOutput {
    var output = try provePreparedExImpl(
        Engine,
        true,
        session,
        allocator,
        pcs_config,
        prepared,
        false,
        recorder,
    );
    const proof = output.proof.proof;
    output.proof.aux.deinit(allocator);
    return .{ .statement = output.statement, .proof = proof };
}

pub fn provePreparedExWithSessionAndEngine(
    comptime Engine: type,
    session: *const Engine.Session,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    prepared: PreparedInput,
    include_all_preprocessed_columns: bool,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveExOutput {
    return provePreparedExImpl(
        Engine,
        true,
        session,
        allocator,
        pcs_config,
        prepared,
        include_all_preprocessed_columns,
        recorder,
    );
}

fn provePreparedExImpl(
    comptime Engine: type,
    comptime use_session: bool,
    session: if (use_session) *const Engine.Session else void,
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    prepared: PreparedInput,
    include_all_preprocessed_columns: bool,
    recorder: ?*stage_profile.Recorder,
) anyerror!ProveExOutput {
    return prover_transaction.provePreparedEx(
        Engine,
        ProvingSpec,
        use_session,
        session,
        allocator,
        pcs_config,
        prepared,
        .{
            .include_all_preprocessed_columns = include_all_preprocessed_columns,
            .recorder = recorder,
        },
    );
}

pub fn requiredTwiddleCircleLog(
    request: Request,
    pcs_config: pcs_core.PcsConfig,
) Error!u32 {
    try trace_input.validate(request);
    const composition_log = std.math.add(u32, request.log_n_rows, 1) catch
        return error.InvalidLogSize;
    const commitment_log = std.math.add(
        u32,
        request.log_n_rows,
        pcs_config.fri_config.log_blowup_factor,
    ) catch return error.InvalidLogSize;
    return @max(
        @max(composition_log, commitment_log),
        pcs_config.lifting_log_size orelse 0,
    );
}

/// Verifies a state-machine proof generated by `prove`.
///
/// Preconditions:
/// - `statement` and `proof` come from matching execution parameters.
/// - `proof` is consumed by this function.
pub fn verify(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    statement: PreparedStatement,
    proof_in: Proof,
) anyerror!void {
    if (statement.stmt0.n == 0 or statement.stmt0.n >= 31) {
        var proof = proof_in;
        proof.deinit(allocator);
        return Error.InvalidLogSize;
    }
    if (statement.stmt0.m != statement.stmt0.n - 1) {
        var proof = proof_in;
        proof.deinit(allocator);
        return Error.InvalidLogSize;
    }
    if (proof_in.commitment_scheme_proof.commitments.items.len < 2) {
        var proof = proof_in;
        proof.deinit(allocator);
        return Error.InvalidProofShape;
    }

    var proof = proof_in;
    var proof_moved = false;
    defer if (!proof_moved) proof.deinit(allocator);

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var commitment_scheme = try pcs_verifier.CommitmentSchemeVerifier(Hasher, MerkleChannel).init(
        allocator,
        pcs_config,
    );
    defer commitment_scheme.deinit(allocator);

    const log_n_rows = statement.stmt0.n;
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[0],
        &[_]u32{log_n_rows},
        &channel,
    );
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[1],
        &[_]u32{ log_n_rows, log_n_rows },
        &channel,
    );

    mixStatement0(&channel, statement.stmt0);
    const elements = Elements.draw(&channel);
    try verifyStatement(statement, elements);
    mixPublicInput(&channel, statement.public_input);
    mixStatement1(&channel, statement.stmt1);

    const component = ExampleStateMachineComponent{
        .trace_log_size = log_n_rows,
        .composition_eval = statement.stmt1.x_axis_claimed_sum.add(statement.stmt1.y_axis_claimed_sum),
    };
    const verifier_components = [_]core_air_components.Component{
        component.asVerifierComponent(),
    };

    proof_moved = true;
    try core_verifier.verify(
        Hasher,
        MerkleChannel,
        allocator,
        verifier_components[0..],
        &channel,
        &commitment_scheme,
        proof,
    );
}

const ExampleStateMachineComponent = struct {
    trace_log_size: u32,
    composition_eval: QM31,

    const Adapter = core_air_derive.ComponentAdapter(
        @This(),
        prover_component.ComponentProver,
        prover_component.Trace,
        prover_air_accumulation.DomainEvaluationAccumulator,
    );

    fn asVerifierComponent(self: *const @This()) core_air_components.Component {
        return Adapter.asVerifierComponent(self);
    }

    fn asProverComponent(self: *const @This()) prover_component.ComponentProver {
        return Adapter.asProverComponent(self);
    }

    pub fn nConstraints(_: *const @This()) usize {
        return 1;
    }

    pub fn maxConstraintLogDegreeBound(self: *const @This()) u32 {
        return self.trace_log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        const preprocessed = try allocator.dupe(u32, &[_]u32{self.trace_log_size});
        const main = try allocator.dupe(u32, &[_]u32{
            self.trace_log_size,
            self.trace_log_size,
        });
        return core_air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &[_][]u32{
                preprocessed,
                main,
            }),
        );
    }

    pub fn maskPoints(
        _: *const @This(),
        allocator: std.mem.Allocator,
        point: CirclePointQM31,
        _: u32,
    ) !core_air_components.MaskPoints {
        const preprocessed_col = try allocator.alloc(CirclePointQM31, 0);
        const preprocessed_cols = try allocator.dupe([]CirclePointQM31, &[_][]CirclePointQM31{
            preprocessed_col,
        });

        const main_col0 = try allocator.alloc(CirclePointQM31, 1);
        main_col0[0] = point;
        const main_col1 = try allocator.alloc(CirclePointQM31, 1);
        main_col1[0] = point;
        const main_cols = try allocator.dupe([]CirclePointQM31, &[_][]CirclePointQM31{
            main_col0,
            main_col1,
        });

        return core_air_components.MaskPoints.initOwned(
            try allocator.dupe([][]CirclePointQM31, &[_][][]CirclePointQM31{
                preprocessed_cols,
                main_cols,
            }),
        );
    }

    pub fn preprocessedColumnIndices(
        _: *const @This(),
        allocator: std.mem.Allocator,
    ) ![]usize {
        return allocator.dupe(usize, &[_]usize{0});
    }

    pub fn evaluateConstraintQuotientsAtPoint(
        self: *const @This(),
        _: CirclePointQM31,
        _: *const core_air_components.MaskValues,
        evaluation_accumulator: *core_air_accumulation.PointEvaluationAccumulator,
        _: u32,
    ) !void {
        evaluation_accumulator.accumulate(self.composition_eval);
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        _: *const prover_component.Trace,
        evaluation_accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        const domain_size = @as(usize, 1) << @intCast(self.trace_log_size + 1);
        const values = try evaluation_accumulator.allocator.alloc(QM31, domain_size);
        defer evaluation_accumulator.allocator.free(values);
        @memset(values, self.composition_eval);

        var col = try secure_column.SecureColumnByCoords.fromSecureSlice(evaluation_accumulator.allocator, values);
        defer col.deinit(evaluation_accumulator.allocator);
        try evaluation_accumulator.accumulateColumn(self.trace_log_size + 1, &col);
    }
};

const ProvingSpec = struct {
    pub const Statement = PreparedStatement;
    pub const PreparedInput = trace_input.PreparedInput;
    pub const max_components: usize = 1;

    pub const ProverContext = struct {
        statement_value: PreparedStatement,
        component: ExampleStateMachineComponent,
    };

    pub fn validateRequest(request: Request) Error!void {
        try trace_input.validate(request);
    }

    pub fn validatePrepared(prepared: *const trace_input.PreparedInput) Error!void {
        const preprocessed = prepared.trace.preprocessed.columns orelse
            return error.PreparedInputConsumed;
        const main = prepared.trace.main.columns orelse
            return error.PreparedInputConsumed;
        if (preprocessed.len != 1 or main.len != 2)
            return error.InvalidPreparedGeometry;
        for (preprocessed) |column| {
            if (column.log_size != prepared.request.log_n_rows)
                return error.InvalidPreparedGeometry;
        }
        for (main) |column| {
            if (column.log_size != prepared.request.log_n_rows)
                return error.InvalidPreparedGeometry;
        }
    }

    pub fn compositionLog(request: Request) Error!u32 {
        return std.math.add(u32, request.log_n_rows, 1) catch
            return error.InvalidLogSize;
    }

    pub fn initProverContext(
        out: *ProverContext,
        channel: *Channel,
        request: Request,
    ) !void {
        mixStatement0(channel, .{
            .n = request.log_n_rows,
            .m = request.log_n_rows - 1,
        });
        const elements = Elements.draw(channel);
        const prepared_statement = try prepareStatement(
            request.log_n_rows,
            request.initial_state,
            elements,
        );
        mixPublicInput(channel, prepared_statement.public_input);
        mixStatement1(channel, prepared_statement.stmt1);

        out.* = .{
            .statement_value = prepared_statement,
            .component = .{
                .trace_log_size = request.log_n_rows,
                .composition_eval = prepared_statement.stmt1.x_axis_claimed_sum.add(
                    prepared_statement.stmt1.y_axis_claimed_sum,
                ),
            },
        };
    }

    pub fn statement(context: *const ProverContext) PreparedStatement {
        return context.statement_value;
    }

    pub fn proverComponents(
        context: *const ProverContext,
        out: []prover_component.ComponentProver,
    ) ![]const prover_component.ComponentProver {
        if (out.len < max_components) return error.InvalidProofShape;
        out[0] = context.component.asProverComponent();
        return out[0..1];
    }
};

test "examples state_machine: trace generation increments selected coordinate" {
    const alloc = std.testing.allocator;

    var trace = try genTrace(
        alloc,
        4,
        .{
            M31.fromCanonical(17),
            M31.fromCanonical(16),
        },
        1,
    );
    defer deinitTrace(alloc, &trace);

    try std.testing.expectEqual(@as(usize, 16), trace[0].len);
    try std.testing.expectEqual(@as(usize, 16), trace[1].len);
    try std.testing.expect(trace[0][0].eql(M31.fromCanonical(17)));
}

test "examples state_machine: transition states follow upstream formulas" {
    const initial: State = .{
        M31.fromCanonical(5),
        M31.fromCanonical(9),
    };
    const states = try transitionStates(6, initial);

    try std.testing.expect(states.intermediate[0].eql(M31.fromCanonical(5 + 64)));
    try std.testing.expect(states.intermediate[1].eql(M31.fromCanonical(9)));
    try std.testing.expect(states.final[0].eql(M31.fromCanonical(5 + 64)));
    try std.testing.expect(states.final[1].eql(M31.fromCanonical(9 + 32)));
}

test "examples state_machine: rejects invalid log size and coordinate index" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        Error.InvalidLogSize,
        transitionStates(0, .{ M31.zero(), M31.zero() }),
    );
    try std.testing.expectError(
        Error.InvalidLogSize,
        transitionStates(31, .{ M31.zero(), M31.zero() }),
    );
    try std.testing.expectError(
        Error.InvalidIncIndex,
        genTrace(alloc, 4, .{ M31.zero(), M31.zero() }, 2),
    );
}

test "examples state_machine: claimed-sum accumulation equals telescoping form" {
    const elements: Elements = .{
        .z = QM31.fromU32Unchecked(41, 17, 9, 3),
        .alpha = QM31.fromU32Unchecked(5, 8, 13, 21),
    };
    const initial: State = .{
        M31.fromCanonical(7),
        M31.fromCanonical(11),
    };

    const direct = try claimedSumFromInitial(6, initial, 1, elements);
    const telescoping = try claimedSumTelescoping(6, initial, 1, elements);
    try std.testing.expect(direct.eql(telescoping));
}

test "examples state_machine: draw yields distinct lookup elements on successive calls" {
    var channel = Channel{};
    const e0 = Elements.draw(&channel);
    const e1 = Elements.draw(&channel);
    try std.testing.expect(!e0.z.eql(e1.z) or !e0.alpha.eql(e1.alpha));
}

test "examples state_machine: claimed sums satisfy public statement equation" {
    const initial: State = .{
        M31.fromCanonical(3),
        M31.fromCanonical(9),
    };
    const elements: Elements = .{
        .z = QM31.fromU32Unchecked(27, 4, 19, 8),
        .alpha = QM31.fromU32Unchecked(2, 7, 11, 13),
    };
    const log_n_rows: u32 = 7;

    const transitions = try transitionStates(log_n_rows, initial);
    const x_claim = try claimedSumTelescoping(log_n_rows, initial, 0, elements);
    const y_claim = try claimedSumTelescoping(log_n_rows - 1, transitions.intermediate, 1, elements);
    const ok = try claimsSatisfyStatement(
        initial,
        transitions.final,
        x_claim,
        y_claim,
        elements,
    );
    try std.testing.expect(ok);
}

test "examples state_machine: prepare/verify statement roundtrip" {
    const elements: Elements = .{
        .z = QM31.fromU32Unchecked(37, 19, 5, 11),
        .alpha = QM31.fromU32Unchecked(7, 3, 13, 17),
    };
    const initial: State = .{
        M31.fromCanonical(12),
        M31.fromCanonical(4),
    };

    const statement = try prepareStatement(8, initial, elements);
    try std.testing.expectEqual(@as(u32, 8), statement.stmt0.n);
    try std.testing.expectEqual(@as(u32, 7), statement.stmt0.m);
    try verifyStatement(statement, elements);

    var bad = statement;
    bad.stmt1.y_axis_claimed_sum = bad.stmt1.y_axis_claimed_sum.add(QM31.one());
    try std.testing.expectError(Error.StatementNotSatisfied, verifyStatement(bad, elements));
}

test "examples state_machine: prove/verify wrapper roundtrip" {
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = try @import("../core/fri.zig").FriConfig.init(0, 1, 3),
    };

    const output = try prove(
        std.testing.allocator,
        config,
        5,
        .{
            M31.fromCanonical(9),
            M31.fromCanonical(3),
        },
    );
    try verify(
        std.testing.allocator,
        config,
        output.statement,
        output.proof,
    );
}

test "examples state_machine: prove_ex wrapper roundtrip" {
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = try @import("../core/fri.zig").FriConfig.init(0, 1, 3),
    };

    var output = try proveEx(
        std.testing.allocator,
        config,
        5,
        .{
            M31.fromCanonical(9),
            M31.fromCanonical(3),
        },
        false,
    );
    defer output.proof.aux.deinit(std.testing.allocator);
    try verify(
        std.testing.allocator,
        config,
        output.statement,
        output.proof.proof,
    );
}

test "examples state_machine: prove and prove_ex wrappers emit identical proof bytes" {
    const alloc = std.testing.allocator;
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = try @import("../core/fri.zig").FriConfig.init(0, 1, 3),
    };

    var output_prove = try prove(
        alloc,
        config,
        5,
        .{
            M31.fromCanonical(14),
            M31.fromCanonical(6),
        },
    );
    defer output_prove.proof.deinit(alloc);

    var output_prove_ex = try proveEx(
        alloc,
        config,
        5,
        .{
            M31.fromCanonical(14),
            M31.fromCanonical(6),
        },
        false,
    );
    defer output_prove_ex.proof.aux.deinit(alloc);
    defer output_prove_ex.proof.proof.deinit(alloc);

    const proof_wire = @import("../interop/proof_wire.zig");
    const prove_bytes = try proof_wire.encodeProofBytes(alloc, output_prove.proof);
    defer alloc.free(prove_bytes);
    const prove_ex_bytes = try proof_wire.encodeProofBytes(alloc, output_prove_ex.proof.proof);
    defer alloc.free(prove_ex_bytes);

    try std.testing.expectEqualSlices(u8, prove_bytes, prove_ex_bytes);
}

test "examples state_machine: verify wrapper rejects tampered statement" {
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = try @import("../core/fri.zig").FriConfig.init(0, 1, 3),
    };

    const output = try prove(
        std.testing.allocator,
        config,
        5,
        .{
            M31.fromCanonical(14),
            M31.fromCanonical(6),
        },
    );
    var bad_statement = output.statement;
    bad_statement.stmt1.x_axis_claimed_sum = bad_statement.stmt1.x_axis_claimed_sum.add(QM31.one());

    try std.testing.expectError(
        Error.StatementNotSatisfied,
        verify(
            std.testing.allocator,
            config,
            bad_statement,
            output.proof,
        ),
    );
}
