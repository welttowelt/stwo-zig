//! Closed workload registry for the native CPU/Metal proof suite.

const std = @import("std");
const stwo = @import("stwo");
const config = @import("config.zig");
const report = @import("report.zig");

const artifacts = stwo.interop.examples_artifact;
const stage_profile = stwo.prover.stage_profile;
const plonk = stwo.examples.plonk;
const wide_fibonacci = stwo.examples.wide_fibonacci;
const xor = stwo.examples.xor;

pub const Geometry = struct {
    trace_log_rows: u32,
    trace_rows: u64,
    committed_trees: u32 = 2,
    committed_columns: u64,
    committed_trace_cells: u64,
    native_unit: []const u8,
    native_units: u64,
};

pub fn name(workload: config.Workload) []const u8 {
    return switch (workload) {
        .wide_fibonacci => "wide_fibonacci",
        .xor => "xor",
        .plonk => "plonk",
    };
}

pub fn parameters(workload: config.Workload) report.WorkloadParameters {
    return switch (workload) {
        .wide_fibonacci => |value| .{ .wide_fibonacci = value },
        .xor => |value| .{ .xor = value },
        .plonk => |value| .{ .plonk = value },
    };
}

pub fn geometry(workload: config.Workload) !Geometry {
    return switch (workload) {
        .wide_fibonacci => |value| blk: {
            const rows = @as(u64, 1) << @intCast(value.log_n_rows);
            break :blk .{
                .trace_log_rows = value.log_n_rows,
                .trace_rows = rows,
                .committed_columns = value.sequence_len,
                .committed_trace_cells = try std.math.mul(u64, rows, value.sequence_len),
                .native_unit = "trace_rows",
                .native_units = rows,
            };
        },
        .xor => |value| blk: {
            const rows = @as(u64, 1) << @intCast(value.log_size);
            break :blk .{
                .trace_log_rows = value.log_size,
                .trace_rows = rows,
                .committed_columns = 3,
                .committed_trace_cells = try std.math.mul(u64, rows, 3),
                .native_unit = "xor_rows",
                .native_units = rows,
            };
        },
        .plonk => |value| blk: {
            const rows = @as(u64, 1) << @intCast(value.log_n_rows);
            break :blk .{
                .trace_log_rows = value.log_n_rows,
                .trace_rows = rows,
                .committed_columns = 8,
                .committed_trace_cells = try std.math.mul(u64, rows, 8),
                .native_unit = "plonk_rows",
                .native_units = rows,
            };
        },
    };
}

pub fn descriptorDigest(
    workload: config.Workload,
    protocol: config.Protocol,
) [32]u8 {
    const protocol_parameters = protocol.parameters();
    var buffer: [512]u8 = undefined;
    const prefix = switch (workload) {
        .wide_fibonacci => |value| std.fmt.bufPrint(
            &buffer,
            "native-proof-workload-v3|example=wide_fibonacci|log_n_rows={d}|sequence_len={d}",
            .{ value.log_n_rows, value.sequence_len },
        ) catch unreachable,
        .xor => |value| std.fmt.bufPrint(
            &buffer,
            "native-proof-workload-v3|example=xor|log_size={d}|log_step={d}|offset={d}",
            .{ value.log_size, value.log_step, value.offset },
        ) catch unreachable,
        .plonk => |value| std.fmt.bufPrint(
            &buffer,
            "native-proof-workload-v3|example=plonk|log_n_rows={d}",
            .{value.log_n_rows},
        ) catch unreachable,
    };
    const description = std.fmt.bufPrint(
        buffer[prefix.len..],
        "|protocol={s}|pow_bits={d}|log_blowup_factor={d}|log_last_layer_degree_bound={d}|n_queries={d}|fold_step={d}",
        .{
            @tagName(protocol),
            protocol_parameters.pow_bits,
            protocol_parameters.log_blowup_factor,
            protocol_parameters.log_last_layer_degree_bound,
            protocol_parameters.n_queries,
            protocol_parameters.fold_step,
        },
    ) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buffer[0 .. prefix.len + description.len], &digest, .{});
    return digest;
}

pub const WideFibonacciSpec = struct {
    pub const Request = wide_fibonacci.Statement;
    pub const PreparedInput = wide_fibonacci.PreparedInput;
    pub const Statement = wide_fibonacci.Statement;
    pub const Proof = wide_fibonacci.Proof;
    pub const ProveOutput = wide_fibonacci.ProveOutput;
    pub const example_name = "wide_fibonacci";

    pub fn request(value: config.WideFibonacciParameters) Request {
        return .{ .log_n_rows = value.log_n_rows, .sequence_len = value.sequence_len };
    }

    pub fn prepareInput(allocator: std.mem.Allocator, value: Request) !PreparedInput {
        return wide_fibonacci.prepareInput(allocator, value);
    }

    pub fn requiredCircleLog(value: Request, pcs_config: stwo.core.pcs.PcsConfig) !u32 {
        return wide_fibonacci.requiredTwiddleCircleLog(value, pcs_config);
    }

    pub fn provePrepared(
        comptime Engine: type,
        session: *const Engine.Session,
        allocator: std.mem.Allocator,
        pcs_config: stwo.core.pcs.PcsConfig,
        prepared: PreparedInput,
        recorder: ?*stage_profile.Recorder,
    ) !ProveOutput {
        return wide_fibonacci.provePreparedWithSessionAndEngine(
            Engine,
            session,
            allocator,
            pcs_config,
            prepared,
            recorder,
        );
    }

    pub fn verify(
        allocator: std.mem.Allocator,
        pcs_config: stwo.core.pcs.PcsConfig,
        statement: Statement,
        proof: Proof,
    ) !void {
        return wide_fibonacci.verify(allocator, pcs_config, statement, proof);
    }

    pub fn writeArtifact(
        allocator: std.mem.Allocator,
        path: []const u8,
        pcs_config: stwo.core.pcs.PcsConfig,
        statement: Statement,
        proof_bytes: []const u8,
    ) !void {
        return artifacts.writeNativeProofArtifact(
            allocator,
            path,
            pcs_config,
            "prove",
            .{ .wide_fibonacci = statement },
            proof_bytes,
        );
    }
};

pub const XorSpec = struct {
    pub const Request = xor.Statement;
    pub const PreparedInput = xor.PreparedInput;
    pub const Statement = xor.Statement;
    pub const Proof = xor.Proof;
    pub const ProveOutput = xor.ProveOutput;
    pub const example_name = "xor";

    pub fn request(value: config.XorParameters) Request {
        return .{ .log_size = value.log_size, .log_step = value.log_step, .offset = value.offset };
    }

    pub fn prepareInput(allocator: std.mem.Allocator, value: Request) !PreparedInput {
        return xor.prepareInput(allocator, value);
    }

    pub fn requiredCircleLog(value: Request, pcs_config: stwo.core.pcs.PcsConfig) !u32 {
        return xor.requiredTwiddleCircleLog(value, pcs_config);
    }

    pub fn provePrepared(
        comptime Engine: type,
        session: *const Engine.Session,
        allocator: std.mem.Allocator,
        pcs_config: stwo.core.pcs.PcsConfig,
        prepared: PreparedInput,
        recorder: ?*stage_profile.Recorder,
    ) !ProveOutput {
        return xor.provePreparedWithSessionAndEngine(
            Engine,
            session,
            allocator,
            pcs_config,
            prepared,
            recorder,
        );
    }

    pub fn verify(
        allocator: std.mem.Allocator,
        pcs_config: stwo.core.pcs.PcsConfig,
        statement: Statement,
        proof: Proof,
    ) !void {
        return xor.verify(allocator, pcs_config, statement, proof);
    }

    pub fn writeArtifact(
        allocator: std.mem.Allocator,
        path: []const u8,
        pcs_config: stwo.core.pcs.PcsConfig,
        statement: Statement,
        proof_bytes: []const u8,
    ) !void {
        return artifacts.writeNativeProofArtifact(
            allocator,
            path,
            pcs_config,
            "prove",
            .{ .xor = statement },
            proof_bytes,
        );
    }
};

pub const PlonkSpec = struct {
    pub const Request = plonk.Statement;
    pub const PreparedInput = plonk.PreparedInput;
    pub const Statement = plonk.Statement;
    pub const Proof = plonk.Proof;
    pub const ProveOutput = plonk.ProveOutput;
    pub const example_name = "plonk";

    pub fn request(value: config.PlonkParameters) Request {
        return .{ .log_n_rows = value.log_n_rows };
    }

    pub fn prepareInput(allocator: std.mem.Allocator, value: Request) !PreparedInput {
        return plonk.prepareInput(allocator, value);
    }

    pub fn requiredCircleLog(value: Request, pcs_config: stwo.core.pcs.PcsConfig) !u32 {
        return plonk.requiredTwiddleCircleLog(value, pcs_config);
    }

    pub fn provePrepared(
        comptime Engine: type,
        session: *const Engine.Session,
        allocator: std.mem.Allocator,
        pcs_config: stwo.core.pcs.PcsConfig,
        prepared: PreparedInput,
        recorder: ?*stage_profile.Recorder,
    ) !ProveOutput {
        return plonk.provePreparedWithSessionAndEngine(
            Engine,
            session,
            allocator,
            pcs_config,
            prepared,
            recorder,
        );
    }

    pub fn verify(
        allocator: std.mem.Allocator,
        pcs_config: stwo.core.pcs.PcsConfig,
        statement: Statement,
        proof: Proof,
    ) !void {
        return plonk.verify(allocator, pcs_config, statement, proof);
    }

    pub fn writeArtifact(
        allocator: std.mem.Allocator,
        path: []const u8,
        pcs_config: stwo.core.pcs.PcsConfig,
        statement: Statement,
        proof_bytes: []const u8,
    ) !void {
        return artifacts.writeNativeProofArtifact(
            allocator,
            path,
            pcs_config,
            "prove",
            .{ .plonk = statement },
            proof_bytes,
        );
    }
};

test "native proof examples: geometry and descriptors are tagged" {
    const wide: config.Workload = .{ .wide_fibonacci = .{ .log_n_rows = 5, .sequence_len = 8 } };
    const xor_workload: config.Workload = .{ .xor = .{ .log_size = 5, .log_step = 2, .offset = 3 } };
    const plonk_workload: config.Workload = .{ .plonk = .{ .log_n_rows = 5 } };
    const wide_geometry = try geometry(wide);
    const xor_geometry = try geometry(xor_workload);
    const plonk_geometry = try geometry(plonk_workload);
    try std.testing.expectEqual(@as(u64, 256), wide_geometry.committed_trace_cells);
    try std.testing.expectEqual(@as(u64, 96), xor_geometry.committed_trace_cells);
    try std.testing.expectEqual(@as(u64, 256), plonk_geometry.committed_trace_cells);
    try std.testing.expect(!std.mem.eql(
        u8,
        &descriptorDigest(wide, .smoke),
        &descriptorDigest(xor_workload, .smoke),
    ));
}

test "native proof examples: descriptor digests match independent fixed vectors" {
    const wide: config.Workload = .{ .wide_fibonacci = .{ .log_n_rows = 10, .sequence_len = 8 } };
    const xor_workload: config.Workload = .{ .xor = .{ .log_size = 10, .log_step = 2, .offset = 3 } };
    const plonk_workload: config.Workload = .{ .plonk = .{ .log_n_rows = 10 } };
    var expected_wide: [32]u8 = undefined;
    var expected_xor: [32]u8 = undefined;
    var expected_plonk: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_wide,
        "8586bce9ae8c0673453803b3b65ca8d4fc677638d53e5933e7692af4dd38586f",
    );
    _ = try std.fmt.hexToBytes(
        &expected_xor,
        "b0272044b4e572bf519aa58c00ee3520f2961b409d2ecb67ba86c5760a991c0e",
    );
    _ = try std.fmt.hexToBytes(
        &expected_plonk,
        "8e22d72f97cfe01bdb3fdf94e362160418ca16022db7cdaccacf073e2ef67cee",
    );
    try std.testing.expectEqualSlices(u8, &expected_wide, &descriptorDigest(wide, .functional));
    try std.testing.expectEqualSlices(u8, &expected_xor, &descriptorDigest(xor_workload, .functional));
    try std.testing.expectEqualSlices(u8, &expected_plonk, &descriptorDigest(plonk_workload, .functional));
}
