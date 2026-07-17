const std = @import("std");

pub const Backend = enum {
    cpu_native,
    metal_hybrid,
};

pub const EvidenceClass = enum {
    verified_unprofiled,
    profiled_diagnostic,
    correctness_only,
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
    log_rows: u32 = 12,
    sequence_len: u32 = 16,
    protocol: Protocol = .functional,
    warmups: usize = 1,
    samples: usize = 5,
    profiled: bool = false,

    pub fn evidenceClass(self: Args, meets_sampling_contract: bool) EvidenceClass {
        if (self.profiled) return .profiled_diagnostic;
        return if (meets_sampling_contract) .verified_unprofiled else .correctness_only;
    }
};

pub const ParseResult = union(enum) {
    run: Args,
    help,
};

pub fn parseArgs(argv: []const []const u8) !ParseResult {
    var result = Args{};
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
        if (std.mem.eql(u8, arg, "--log-rows")) {
            result.log_rows = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--sequence-len")) {
            result.sequence_len = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            result.protocol = std.meta.stringToEnum(Protocol, value) orelse return error.InvalidProtocol;
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            result.warmups = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            result.samples = try std.fmt.parseInt(usize, value, 10);
        } else {
            return error.UnknownArgument;
        }
    }
    try validate(result);
    return .{ .run = result };
}

fn validate(args: Args) !void {
    if (args.log_rows == 0 or args.log_rows >= 31) return error.InvalidLogRows;
    if (args.sequence_len < 2) return error.InvalidSequenceLength;
    if (args.warmups > 100) return error.TooManyWarmups;
    if (args.samples == 0 or args.samples > 101) return error.InvalidSampleCount;
}

pub fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: native-proof-bench-{cpu|metal} [options]
        \\
        \\  --log-rows N       Wide Fibonacci trace log2 rows (default: 12)
        \\  --sequence-len N   Trace column count (default: 16)
        \\  --protocol NAME    smoke or functional (default: functional)
        \\  --warmups N        Verified untimed warmups (default: 1)
        \\  --samples N        Verified timed samples (default: 5)
        \\  --profiled         Diagnostic instrumentation; never headline MHz
        \\  -h, --help         Show this help
        \\
    );
}

test "native proof config: parses a complete benchmark request" {
    const parsed = try parseArgs(&.{
        "--log-rows", "8", "--sequence-len", "32", "--protocol", "smoke",
        "--warmups",  "0", "--samples",      "5",  "--profiled",
    });
    const args = parsed.run;
    try std.testing.expectEqual(@as(u32, 8), args.log_rows);
    try std.testing.expectEqual(@as(u32, 32), args.sequence_len);
    try std.testing.expectEqual(Protocol.smoke, args.protocol);
    try std.testing.expectEqual(@as(usize, 0), args.warmups);
    try std.testing.expectEqual(@as(usize, 5), args.samples);
    try std.testing.expectEqual(EvidenceClass.profiled_diagnostic, args.evidenceClass(true));
}

test "native proof config: rejects invalid and incomplete requests" {
    try std.testing.expectError(error.InvalidSampleCount, parseArgs(&.{ "--samples", "0" }));
    try std.testing.expectError(error.InvalidSequenceLength, parseArgs(&.{ "--sequence-len", "1" }));
    try std.testing.expectError(error.InvalidProtocol, parseArgs(&.{ "--protocol", "production" }));
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(&.{"--log-rows"}));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "--other", "1" }));
}

test "native proof config: undersampled unprofiled runs are correctness-only" {
    const args = (try parseArgs(&.{ "--warmups", "0", "--samples", "1" })).run;
    try std.testing.expectEqual(EvidenceClass.correctness_only, args.evidenceClass(false));
}
