const std = @import("std");

pub const Backend = enum { cpu_native, metal_hybrid };

pub const EvidenceClass = enum {
    verified_unprofiled,
    profiled_diagnostic,
    correctness_only,
};

pub const Example = enum { wide_fibonacci, xor, plonk, state_machine, blake, poseidon };

pub const WideFibonacciParameters = struct {
    log_n_rows: u32 = 12,
    sequence_len: u32 = 16,
};

pub const XorParameters = struct {
    log_size: u32 = 10,
    log_step: u32 = 2,
    offset: usize = 3,
};

pub const PlonkParameters = struct {
    log_n_rows: u32 = 10,
};

pub const StateMachineParameters = struct {
    log_n_rows: u32 = 10,
    initial_x: u32 = 9,
    initial_y: u32 = 3,
};

pub const BlakeParameters = struct {
    log_n_rows: u32 = 8,
    n_rounds: u32 = 2,
};

pub const PoseidonParameters = struct {
    log_n_instances: u32 = 13,
};

pub const Workload = union(Example) {
    wide_fibonacci: WideFibonacciParameters,
    xor: XorParameters,
    plonk: PlonkParameters,
    state_machine: StateMachineParameters,
    blake: BlakeParameters,
    poseidon: PoseidonParameters,
};

pub const Protocol = enum {
    smoke,
    functional,

    pub fn parameters(self: Protocol) ProtocolParameters {
        return switch (self) {
            .smoke => .{ .pow_bits = 0 },
            .functional => .{ .pow_bits = 10 },
        };
    }
};

pub const ProtocolParameters = struct {
    pow_bits: u32,
    log_blowup_factor: u32 = 1,
    log_last_layer_degree_bound: u32 = 0,
    n_queries: usize = 3,
    fold_step: u32 = 1,
};

pub const Args = struct {
    example: Example = .wide_fibonacci,
    wide_fibonacci: WideFibonacciParameters = .{},
    xor: XorParameters = .{},
    plonk: PlonkParameters = .{},
    state_machine: StateMachineParameters = .{},
    blake: BlakeParameters = .{},
    poseidon: PoseidonParameters = .{},
    protocol: Protocol = .functional,
    warmups: usize = MIN_HEADLINE_WARMUPS,
    samples: usize = 5,
    profiled: bool = false,
    proof_artifact_out: ?[]const u8 = null,

    pub fn workload(self: Args) Workload {
        return switch (self.example) {
            .wide_fibonacci => .{ .wide_fibonacci = self.wide_fibonacci },
            .xor => .{ .xor = self.xor },
            .plonk => .{ .plonk = self.plonk },
            .state_machine => .{ .state_machine = self.state_machine },
            .blake => .{ .blake = self.blake },
            .poseidon => .{ .poseidon = self.poseidon },
        };
    }

    pub fn evidenceClass(self: Args, meets_sampling_contract: bool) EvidenceClass {
        if (self.profiled) return .profiled_diagnostic;
        return if (meets_sampling_contract) .verified_unprofiled else .correctness_only;
    }
};

pub const ParseResult = union(enum) { run: Args, help };

const MAX_LOG_ROWS: u32 = 22;
const MAX_SEQUENCE_LEN: u32 = 512;
const MAX_BLAKE_ROUNDS: u32 = 32;
const POSEIDON_LOG_INSTANCES_PER_ROW: u32 = 3;
const POSEIDON_COLUMNS: u64 = 1264;
const MAX_XOR_OFFSET: usize = (1 << 31) - 1;
const M31_MODULUS: u32 = 0x7fffffff;
const MAX_COMMITTED_CELLS: u64 = 1 << 25;
pub const MIN_HEADLINE_WARMUPS: usize = 10;
pub const MAX_WARMUPS: usize = 10;

pub fn parseArgs(argv: []const []const u8) !ParseResult {
    var result = Args{};
    var saw_wide_parameter = false;
    var saw_xor_parameter = false;
    var saw_state_machine_parameter = false;
    var saw_blake_parameter = false;
    var saw_poseidon_parameter = false;
    var log_n_rows_override: ?u32 = null;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--profiled")) {
            result.profiled = true;
            continue;
        }
        if (index + 1 >= argv.len) return error.MissingArgumentValue;
        index += 1;
        const value = argv[index];
        if (std.mem.eql(u8, arg, "--example")) {
            result.example = std.meta.stringToEnum(Example, value) orelse
                return error.InvalidExample;
        } else if (std.mem.eql(u8, arg, "--log-n-rows")) {
            log_n_rows_override = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--log-rows")) {
            result.wide_fibonacci.log_n_rows = try std.fmt.parseInt(u32, value, 10);
            saw_wide_parameter = true;
        } else if (std.mem.eql(u8, arg, "--sequence-len")) {
            result.wide_fibonacci.sequence_len = try std.fmt.parseInt(u32, value, 10);
            saw_wide_parameter = true;
        } else if (std.mem.eql(u8, arg, "--log-size")) {
            result.xor.log_size = try std.fmt.parseInt(u32, value, 10);
            saw_xor_parameter = true;
        } else if (std.mem.eql(u8, arg, "--log-step")) {
            result.xor.log_step = try std.fmt.parseInt(u32, value, 10);
            saw_xor_parameter = true;
        } else if (std.mem.eql(u8, arg, "--offset")) {
            result.xor.offset = try std.fmt.parseInt(usize, value, 10);
            saw_xor_parameter = true;
        } else if (std.mem.eql(u8, arg, "--initial-x")) {
            result.state_machine.initial_x = try std.fmt.parseInt(u32, value, 10);
            saw_state_machine_parameter = true;
        } else if (std.mem.eql(u8, arg, "--initial-y")) {
            result.state_machine.initial_y = try std.fmt.parseInt(u32, value, 10);
            saw_state_machine_parameter = true;
        } else if (std.mem.eql(u8, arg, "--n-rounds")) {
            result.blake.n_rounds = try std.fmt.parseInt(u32, value, 10);
            saw_blake_parameter = true;
        } else if (std.mem.eql(u8, arg, "--log-n-instances")) {
            result.poseidon.log_n_instances = try std.fmt.parseInt(u32, value, 10);
            saw_poseidon_parameter = true;
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            result.protocol = std.meta.stringToEnum(Protocol, value) orelse
                return error.InvalidProtocol;
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            result.warmups = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            result.samples = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--proof-artifact-out")) {
            result.proof_artifact_out = value;
        } else {
            return error.UnknownArgument;
        }
    }
    if (log_n_rows_override) |log_n_rows| switch (result.example) {
        .wide_fibonacci => result.wide_fibonacci.log_n_rows = log_n_rows,
        .plonk => result.plonk.log_n_rows = log_n_rows,
        .state_machine => result.state_machine.log_n_rows = log_n_rows,
        .blake => result.blake.log_n_rows = log_n_rows,
        .xor, .poseidon => return error.IrrelevantWorkloadParameter,
    };
    if (result.example == .wide_fibonacci and
        (saw_xor_parameter or saw_state_machine_parameter or saw_blake_parameter or saw_poseidon_parameter))
        return error.IrrelevantWorkloadParameter;
    if (result.example == .xor and
        (saw_wide_parameter or saw_state_machine_parameter or saw_blake_parameter or saw_poseidon_parameter))
        return error.IrrelevantWorkloadParameter;
    if (result.example == .plonk and
        (saw_wide_parameter or saw_xor_parameter or saw_state_machine_parameter or saw_blake_parameter or saw_poseidon_parameter))
        return error.IrrelevantWorkloadParameter;
    if (result.example == .state_machine and
        (saw_wide_parameter or saw_xor_parameter or saw_blake_parameter or saw_poseidon_parameter))
        return error.IrrelevantWorkloadParameter;
    if (result.example == .blake and
        (saw_wide_parameter or saw_xor_parameter or saw_state_machine_parameter or saw_poseidon_parameter))
        return error.IrrelevantWorkloadParameter;
    if (result.example == .poseidon and
        (saw_wide_parameter or saw_xor_parameter or saw_state_machine_parameter or saw_blake_parameter))
        return error.IrrelevantWorkloadParameter;
    try validate(result);
    return .{ .run = result };
}

fn validate(args: Args) !void {
    const committed_cells = switch (args.workload()) {
        .wide_fibonacci => |parameters| blk: {
            if (parameters.log_n_rows == 0 or parameters.log_n_rows > MAX_LOG_ROWS)
                return error.InvalidLogRows;
            if (parameters.sequence_len < 2 or parameters.sequence_len > MAX_SEQUENCE_LEN)
                return error.InvalidSequenceLength;
            const rows = @as(u64, 1) << @intCast(parameters.log_n_rows);
            break :blk try std.math.mul(u64, rows, parameters.sequence_len);
        },
        .xor => |parameters| blk: {
            if (parameters.log_size == 0 or parameters.log_size > MAX_LOG_ROWS)
                return error.InvalidLogRows;
            if (parameters.log_step > parameters.log_size) return error.InvalidStep;
            if (parameters.offset > MAX_XOR_OFFSET) return error.InvalidOffset;
            const period = @as(usize, 1) << @intCast(parameters.log_step);
            if (parameters.offset >= period) return error.InvalidOffset;
            const rows = @as(u64, 1) << @intCast(parameters.log_size);
            break :blk try std.math.mul(u64, rows, 3);
        },
        .plonk => |parameters| blk: {
            if (parameters.log_n_rows == 0 or parameters.log_n_rows > MAX_LOG_ROWS)
                return error.InvalidLogRows;
            const rows = @as(u64, 1) << @intCast(parameters.log_n_rows);
            break :blk try std.math.mul(u64, rows, 8);
        },
        .state_machine => |parameters| blk: {
            if (parameters.log_n_rows == 0 or parameters.log_n_rows > MAX_LOG_ROWS)
                return error.InvalidLogRows;
            if (parameters.initial_x >= M31_MODULUS or parameters.initial_y >= M31_MODULUS)
                return error.InvalidInitialState;
            const rows = @as(u64, 1) << @intCast(parameters.log_n_rows);
            break :blk try std.math.mul(u64, rows, 3);
        },
        .blake => |parameters| blk: {
            if (parameters.log_n_rows == 0 or parameters.log_n_rows > MAX_LOG_ROWS)
                return error.InvalidLogRows;
            if (parameters.n_rounds == 0 or parameters.n_rounds > MAX_BLAKE_ROUNDS)
                return error.InvalidRoundCount;
            const rows = @as(u64, 1) << @intCast(parameters.log_n_rows);
            const columns = try std.math.mul(u64, parameters.n_rounds, 96);
            break :blk try std.math.mul(u64, rows, columns);
        },
        .poseidon => |parameters| blk: {
            if (parameters.log_n_instances <= POSEIDON_LOG_INSTANCES_PER_ROW or
                parameters.log_n_instances > MAX_LOG_ROWS + POSEIDON_LOG_INSTANCES_PER_ROW)
                return error.InvalidLogNInstances;
            const log_n_rows = parameters.log_n_instances - POSEIDON_LOG_INSTANCES_PER_ROW;
            const rows = @as(u64, 1) << @intCast(log_n_rows);
            break :blk try std.math.mul(u64, rows, POSEIDON_COLUMNS);
        },
    };
    if (committed_cells > MAX_COMMITTED_CELLS) return error.TooManyCommittedCells;
    if (args.warmups > MAX_WARMUPS) return error.TooManyWarmups;
    if (args.samples == 0 or args.samples > 21) return error.InvalidSampleCount;
    if (args.proof_artifact_out) |path| if (path.len == 0)
        return error.InvalidProofArtifactPath;
}

pub fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: native-proof-bench-{cpu|metal} [options]
        \\
        \\  --example NAME       wide_fibonacci, xor, plonk, state_machine, blake, or poseidon
        \\  --log-n-rows N       Wide Fibonacci, Plonk, State Machine, or Blake log2 rows
        \\  --log-rows N         Legacy Wide Fibonacci log2 rows alias
        \\  --sequence-len N     Wide Fibonacci trace column count
        \\  --log-size N         XOR log2 rows
        \\  --log-step N         XOR periodic-indicator log2 step
        \\  --offset N           XOR periodic-indicator offset
        \\  --initial-x N        State Machine initial x coordinate
        \\  --initial-y N        State Machine initial y coordinate
        \\  --n-rounds N         Blake round count (maximum: 32)
        \\  --log-n-instances N  Poseidon log2 instance count
        \\  --protocol NAME      smoke or functional (default: functional)
        \\  --warmups N          Verified untimed warmups (headline minimum: 10)
        \\  --samples N          Verified timed samples (maximum: 21)
        \\  --proof-artifact-out PATH
        \\  --profiled           Diagnostic instrumentation; never headline MHz
        \\  -h, --help           Show this help
        \\
    );
}

test "native proof config: parses tagged workloads and legacy wide requests" {
    const xor_args = (try parseArgs(&.{
        "--example", "xor", "--log-size",           "8",               "--log-step", "3",
        "--offset",  "5",   "--protocol",           "smoke",           "--warmups",  "0",
        "--samples", "5",   "--proof-artifact-out", "/tmp/proof.json",
    })).run;
    try std.testing.expectEqual(Example.xor, xor_args.example);
    try std.testing.expectEqual(@as(u32, 8), xor_args.xor.log_size);
    try std.testing.expectEqual(@as(usize, 5), xor_args.xor.offset);

    const wide = (try parseArgs(&.{ "--log-rows", "7", "--sequence-len", "9" })).run;
    try std.testing.expectEqual(@as(u32, 7), wide.wide_fibonacci.log_n_rows);
    try std.testing.expectEqual(@as(u32, 9), wide.wide_fibonacci.sequence_len);

    const plonk = (try parseArgs(&.{ "--log-n-rows", "8", "--example", "plonk" })).run;
    try std.testing.expectEqual(Example.plonk, plonk.example);
    try std.testing.expectEqual(@as(u32, 8), plonk.plonk.log_n_rows);

    const state = (try parseArgs(&.{
        "--example",   "state_machine", "--log-n-rows", "8",
        "--initial-x", "17",            "--initial-y",  "19",
    })).run;
    try std.testing.expectEqual(Example.state_machine, state.example);
    try std.testing.expectEqual(@as(u32, 17), state.state_machine.initial_x);
    try std.testing.expectEqual(@as(u32, 19), state.state_machine.initial_y);

    const blake = (try parseArgs(&.{
        "--example", "blake", "--log-n-rows", "7", "--n-rounds", "3",
    })).run;
    try std.testing.expectEqual(Example.blake, blake.example);
    try std.testing.expectEqual(@as(u32, 7), blake.blake.log_n_rows);
    try std.testing.expectEqual(@as(u32, 3), blake.blake.n_rounds);

    const poseidon = (try parseArgs(&.{
        "--example", "poseidon", "--log-n-instances", "13",
    })).run;
    try std.testing.expectEqual(Example.poseidon, poseidon.example);
    try std.testing.expectEqual(@as(u32, 13), poseidon.poseidon.log_n_instances);
}

test "native proof config: bounds and tags fail closed" {
    try std.testing.expectError(error.InvalidSampleCount, parseArgs(&.{ "--samples", "0" }));
    try std.testing.expectError(error.InvalidStep, parseArgs(&.{ "--example", "xor", "--log-step", "11" }));
    try std.testing.expectError(error.InvalidOffset, parseArgs(&.{ "--example", "xor", "--offset", "4" }));
    try std.testing.expectError(error.IrrelevantWorkloadParameter, parseArgs(&.{ "--example", "xor", "--log-rows", "5" }));
    try std.testing.expectError(error.IrrelevantWorkloadParameter, parseArgs(&.{ "--example", "plonk", "--sequence-len", "4" }));
    try std.testing.expectError(error.InvalidInitialState, parseArgs(&.{ "--example", "state_machine", "--initial-x", "2147483647" }));
    try std.testing.expectError(error.IrrelevantWorkloadParameter, parseArgs(&.{ "--example", "state_machine", "--offset", "1" }));
    try std.testing.expectError(error.InvalidRoundCount, parseArgs(&.{ "--example", "blake", "--n-rounds", "0" }));
    try std.testing.expectError(error.InvalidRoundCount, parseArgs(&.{ "--example", "blake", "--n-rounds", "33" }));
    try std.testing.expectError(error.TooManyCommittedCells, parseArgs(&.{ "--example", "blake", "--log-n-rows", "18", "--n-rounds", "2" }));
    try std.testing.expectError(error.IrrelevantWorkloadParameter, parseArgs(&.{ "--example", "plonk", "--n-rounds", "2" }));
    try std.testing.expectError(error.InvalidLogNInstances, parseArgs(&.{ "--example", "poseidon", "--log-n-instances", "3" }));
    try std.testing.expectError(error.TooManyCommittedCells, parseArgs(&.{ "--example", "poseidon", "--log-n-instances", "18" }));
    try std.testing.expectError(error.IrrelevantWorkloadParameter, parseArgs(&.{ "--example", "poseidon", "--log-n-rows", "8" }));
    try std.testing.expectError(error.IrrelevantWorkloadParameter, parseArgs(&.{ "--example", "blake", "--log-n-instances", "8" }));
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(&.{"--log-rows"}));
}

test "native proof config: headline warmup floor defaults to ten" {
    const defaults = (try parseArgs(&.{})).run;
    try std.testing.expectEqual(MIN_HEADLINE_WARMUPS, defaults.warmups);

    const diagnostic = (try parseArgs(&.{ "--warmups", "1" })).run;
    try std.testing.expectEqual(@as(usize, 1), diagnostic.warmups);
    try std.testing.expectEqual(
        EvidenceClass.correctness_only,
        diagnostic.evidenceClass(false),
    );
}
