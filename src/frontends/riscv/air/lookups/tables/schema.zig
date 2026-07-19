//! Exact preprocessed lookup-table schemas at the pinned Stark-V revision.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const QM31 = @import("stwo_core").fields.qm31.QM31;
const infra = @import("../../../infra_trace.zig");
const entry = @import("../entry.zig");

pub const MAX_ARITY: usize = 4;

pub const Kind = enum(u8) {
    bitwise,
    range_check_20,
    range_check_8_11,
    range_check_8_8_4,
    range_check_8_8,
    range_check_m31,
};

pub const KIND_COUNT: usize = @typeInfo(Kind).@"enum".fields.len;

pub const Error = error{
    InvalidArity,
    InvalidRelationDomain,
    NonBaseFieldValue,
    ValueOutOfRange,
    InvalidTuple,
};

pub fn domain(kind: Kind) entry.Domain {
    return switch (kind) {
        .bitwise => .bitwise,
        .range_check_20 => .range_check_20,
        .range_check_8_11 => .range_check_8_11,
        .range_check_8_8_4 => .range_check_8_8_4,
        .range_check_8_8 => .range_check_8_8,
        .range_check_m31 => .range_check_m31,
    };
}

pub fn logSize(kind: Kind) u32 {
    return switch (kind) {
        .bitwise => 18,
        .range_check_20 => 20,
        .range_check_8_11 => 19,
        .range_check_8_8_4 => 20,
        .range_check_8_8 => 16,
        .range_check_m31 => 15,
    };
}

pub fn arity(kind: Kind) usize {
    return switch (kind) {
        .bitwise => 4,
        .range_check_20 => 1,
        .range_check_8_11, .range_check_8_8, .range_check_m31 => 2,
        .range_check_8_8_4 => 3,
    };
}

pub fn size(kind: Kind) usize {
    return @as(usize, 1) << @intCast(logSize(kind));
}

pub const Tuple = struct {
    values: [MAX_ARITY]M31 = .{M31.zero()} ** MAX_ARITY,
    len: usize,

    pub fn slice(self: *const Tuple) []const M31 {
        return self.values[0..self.len];
    }
};

/// Canonical table row before the circle-domain bit-reversal permutation.
pub fn tupleAt(kind: Kind, row: usize) Error!Tuple {
    if (row >= size(kind)) return error.ValueOutOfRange;
    var result = Tuple{ .len = arity(kind) };
    switch (kind) {
        .bitwise => {
            const lhs: u32 = @intCast(row & 0xff);
            const rhs: u32 = @intCast((row >> 8) & 0xff);
            const operation: u32 = @intCast((row >> 16) & 0x3);
            const value = switch (operation) {
                0 => lhs & rhs,
                1 => lhs | rhs,
                2 => lhs ^ rhs,
                3 => 0,
                else => unreachable,
            };
            result.values[0] = M31.fromU64(lhs);
            result.values[1] = M31.fromU64(rhs);
            result.values[2] = M31.fromU64(value);
            result.values[3] = M31.fromU64(operation);
        },
        .range_check_20 => result.values[0] = M31.fromU64(row),
        .range_check_8_11 => {
            result.values[0] = M31.fromU64(row & 0xff);
            result.values[1] = M31.fromU64(row >> 8);
        },
        .range_check_8_8_4 => {
            result.values[0] = M31.fromU64(row & 0xff);
            result.values[1] = M31.fromU64((row >> 8) & 0xff);
            result.values[2] = M31.fromU64(row >> 16);
        },
        .range_check_8_8 => {
            result.values[0] = M31.fromU64(row & 0xff);
            result.values[1] = M31.fromU64(row >> 8);
        },
        .range_check_m31 => {
            if (row == size(kind) - 1) return .{ .len = 2 };
            result.values[0] = M31.fromU64(row & 0xff);
            result.values[1] = M31.fromU64(row >> 8);
        },
    }
    return result;
}

pub fn indexBase(kind: Kind, values: []const M31) Error!usize {
    if (values.len != arity(kind)) return error.InvalidArity;
    var raw: [MAX_ARITY]u32 = .{0} ** MAX_ARITY;
    for (values, raw[0..values.len]) |value, *dst| dst.* = value.toU32();
    return checkedIndex(kind, raw);
}

pub fn indexSecure(kind: Kind, values: []const QM31) Error!usize {
    if (values.len != arity(kind)) return error.InvalidArity;
    var raw: [MAX_ARITY]u32 = .{0} ** MAX_ARITY;
    for (values, raw[0..values.len]) |value, *dst| {
        const base = value.tryIntoM31() catch return error.NonBaseFieldValue;
        dst.* = base.toU32();
    }
    return checkedIndex(kind, raw);
}

fn checkedIndex(kind: Kind, raw: [MAX_ARITY]u32) Error!usize {
    const row: usize = switch (kind) {
        .bitwise => blk: {
            if (raw[0] >= 256 or raw[1] >= 256 or raw[2] >= 256 or raw[3] >= 4)
                return error.ValueOutOfRange;
            const expected = switch (raw[3]) {
                0 => raw[0] & raw[1],
                1 => raw[0] | raw[1],
                2 => raw[0] ^ raw[1],
                3 => 0,
                else => unreachable,
            };
            if (raw[2] != expected) return error.InvalidTuple;
            break :blk raw[0] | (@as(usize, raw[1]) << 8) | (@as(usize, raw[3]) << 16);
        },
        .range_check_20 => blk: {
            if (raw[0] >= 1 << 20) return error.ValueOutOfRange;
            break :blk raw[0];
        },
        .range_check_8_11 => blk: {
            if (raw[0] >= 256 or raw[1] >= 1 << 11) return error.ValueOutOfRange;
            break :blk raw[0] | (@as(usize, raw[1]) << 8);
        },
        .range_check_8_8_4 => blk: {
            if (raw[0] >= 256 or raw[1] >= 256 or raw[2] >= 16)
                return error.ValueOutOfRange;
            break :blk raw[0] | (@as(usize, raw[1]) << 8) | (@as(usize, raw[2]) << 16);
        },
        .range_check_8_8 => blk: {
            if (raw[0] >= 256 or raw[1] >= 256) return error.ValueOutOfRange;
            break :blk raw[0] | (@as(usize, raw[1]) << 8);
        },
        .range_check_m31 => blk: {
            if (raw[0] >= 256 or raw[1] >= 128) return error.ValueOutOfRange;
            if (raw[0] == 255 and raw[1] == 127) return error.InvalidTuple;
            break :blk raw[0] | (@as(usize, raw[1]) << 8);
        },
    };
    std.debug.assert(row < size(kind));
    return row;
}

pub fn validateRow(kind: Kind, row: usize, values: []const M31) Error!void {
    const expected = try tupleAt(kind, row);
    if (values.len != expected.len) return error.InvalidArity;
    for (values, expected.slice()) |actual, want| {
        if (!actual.eql(want)) return error.InvalidTuple;
    }
}

pub const PreprocessedColumns = struct {
    columns: [MAX_ARITY][]M31 = .{&.{}} ** MAX_ARITY,
    n_columns: usize,

    pub fn deinit(self: *PreprocessedColumns, allocator: std.mem.Allocator) void {
        for (self.columns[0..self.n_columns]) |column| allocator.free(column);
        self.* = undefined;
    }
};

/// Generate deterministic tuple columns in committed bit-reversed order.
pub fn generatePreprocessed(allocator: std.mem.Allocator, kind: Kind) !PreprocessedColumns {
    const n_columns = arity(kind);
    const domain_size = size(kind);
    var result = PreprocessedColumns{ .n_columns = n_columns };
    var allocated: usize = 0;
    errdefer for (result.columns[0..allocated]) |column| allocator.free(column);
    for (result.columns[0..n_columns]) |*column| {
        column.* = try allocator.alloc(M31, domain_size);
        allocated += 1;
    }
    const table = try infra.BitReversalTable.init(allocator, logSize(kind));
    defer table.deinit(allocator);
    for (0..domain_size) |row| {
        const tuple = try tupleAt(kind, row);
        const dst = table.map(row);
        for (tuple.slice(), result.columns[0..n_columns]) |value, column| column[dst] = value;
    }
    return result;
}

test "table schemas match pinned log sizes, arities, and boundary tuples" {
    const expected_logs = [_]u32{ 18, 20, 19, 20, 16, 15 };
    const expected_arities = [_]usize{ 4, 1, 2, 3, 2, 2 };
    for (0..KIND_COUNT) |index| {
        const kind: Kind = @enumFromInt(index);
        try std.testing.expectEqual(expected_logs[index], logSize(kind));
        try std.testing.expectEqual(expected_arities[index], arity(kind));
    }

    const xor = try tupleAt(.bitwise, 0xaa | (0x55 << 8) | (2 << 16));
    try std.testing.expectEqualSlices(M31, &.{ M31.fromU64(0xaa), M31.fromU64(0x55), M31.fromU64(0xff), M31.fromU64(2) }, xor.slice());
    const range811 = try tupleAt(.range_check_8_11, size(.range_check_8_11) - 1);
    try std.testing.expectEqualSlices(M31, &.{ M31.fromU64(255), M31.fromU64(2047) }, range811.slice());
    const range884 = try tupleAt(.range_check_8_8_4, size(.range_check_8_8_4) - 1);
    try std.testing.expectEqualSlices(M31, &.{ M31.fromU64(255), M31.fromU64(255), M31.fromU64(15) }, range884.slice());
    const duplicate = try tupleAt(.range_check_m31, size(.range_check_m31) - 1);
    try std.testing.expectEqualSlices(M31, &.{ M31.zero(), M31.zero() }, duplicate.slice());
}

test "table indices roundtrip sampled rows and reject mutations" {
    const samples = [_]usize{ 0, 1, 17, 255, 256, 4095, 32766 };
    for (0..KIND_COUNT) |kind_index| {
        const kind: Kind = @enumFromInt(kind_index);
        for (samples) |sample| {
            const row = sample % size(kind);
            if (kind == .range_check_m31 and row == size(kind) - 1) continue;
            const tuple = try tupleAt(kind, row);
            try std.testing.expectEqual(row, try indexBase(kind, tuple.slice()));
            try validateRow(kind, row, tuple.slice());
        }
    }

    const bad_bitwise = [_]M31{ M31.fromU64(7), M31.fromU64(3), M31.fromU64(0), M31.fromU64(2) };
    try std.testing.expectError(error.InvalidTuple, indexBase(.bitwise, &bad_bitwise));
    const forbidden_m31 = [_]M31{ M31.fromU64(255), M31.fromU64(127) };
    try std.testing.expectError(error.InvalidTuple, indexBase(.range_check_m31, &forbidden_m31));
    const swapped = [_]M31{ M31.fromU64(2), M31.fromU64(1) };
    try std.testing.expectEqual(@as(usize, 258), try indexBase(.range_check_8_8, &swapped));
    try std.testing.expectError(error.InvalidTuple, validateRow(.range_check_8_8, 513, &swapped));
}

test "range M31 duplicate row is deterministic but not index-addressable" {
    const zero = [_]M31{ M31.zero(), M31.zero() };
    try std.testing.expectEqual(@as(usize, 0), try indexBase(.range_check_m31, &zero));
    try validateRow(.range_check_m31, size(.range_check_m31) - 1, &zero);
}

test "preprocessed columns use deterministic committed bit-reversed order" {
    const allocator = std.testing.allocator;
    const kind: Kind = .range_check_m31;
    var columns = try generatePreprocessed(allocator, kind);
    defer columns.deinit(allocator);
    try std.testing.expectEqual(arity(kind), columns.n_columns);
    for (columns.columns[0..columns.n_columns]) |column| {
        try std.testing.expectEqual(size(kind), column.len);
    }
    const table = try infra.BitReversalTable.init(allocator, logSize(kind));
    defer table.deinit(allocator);
    for ([_]usize{ 0, 1, 258, size(kind) - 2, size(kind) - 1 }) |row| {
        const tuple = try tupleAt(kind, row);
        const dst = table.map(row);
        var sampled: [MAX_ARITY]M31 = undefined;
        for (sampled[0..tuple.len], columns.columns[0..tuple.len]) |*value, column| {
            value.* = column[dst];
        }
        try validateRow(kind, row, sampled[0..tuple.len]);
        sampled[0] = sampled[0].add(M31.one());
        try std.testing.expectError(error.InvalidTuple, validateRow(kind, row, sampled[0..tuple.len]));
    }
}
