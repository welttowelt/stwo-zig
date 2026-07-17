//! Strict JSON interchange for pinned Rust Cairo base-trace receipts.

const std = @import("std");
const checkpoint = @import("checkpoint.zig");

pub const schema = "stwo-cairo-base-trace-checkpoint-v1";
pub const max_receipt_bytes = 32 * 1024 * 1024;
pub const max_components = 256;
pub const max_columns = 16 * 1024;

pub const Authority = struct {
    stwo_cairo_revision: []const u8,
    stwo_revision: []const u8,
};

const WireAuthority = struct {
    stwo_cairo_revision: []const u8,
    stwo_revision: []const u8,
};

const WireColumn = struct {
    ordinal: u32,
    row_count: u64,
    sha256: []const u8,
};

const WireComponent = struct {
    ordinal: u32,
    label: []const u8,
    columns: []const WireColumn,
    accumulator_sha256: []const u8,
};

const WireReceipt = struct {
    schema: []const u8,
    input_sha256: []const u8,
    authority: WireAuthority,
    components: []const WireComponent,
    final_accumulator_sha256: []const u8,
};

pub const Expected = struct {
    input_sha256: checkpoint.Digest,
    authority: Authority,
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(WireReceipt),
    components: []checkpoint.Component,
    columns: []checkpoint.Column,
    final_accumulator: checkpoint.Digest,

    pub fn deinit(self: *Loaded) void {
        self.allocator.free(self.columns);
        self.allocator.free(self.components);
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const Error = error{
    ReceiptTooLarge,
    InvalidSchema,
    AuthorityMismatch,
    InputMismatch,
    InvalidComponentCount,
    InvalidComponentOrdinal,
    DuplicateComponent,
    InvalidColumnCount,
    InvalidColumnOrdinal,
    InconsistentRowCount,
    InvalidDigest,
    AccumulatorMismatch,
    ColumnCountOverflow,
};

pub fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: Expected,
) !Loaded {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    if (size == 0 or size > max_receipt_bytes) return Error.ReceiptTooLarge;
    const encoded = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(encoded);
    if (try file.readAll(encoded) != encoded.len) return error.TruncatedReceipt;
    return parse(allocator, encoded, expected);
}

pub fn parse(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected: Expected,
) !Loaded {
    if (encoded.len == 0 or encoded.len > max_receipt_bytes) return Error.ReceiptTooLarge;
    var parsed = try std.json.parseFromSlice(WireReceipt, allocator, encoded, .{});
    errdefer parsed.deinit();
    const wire = parsed.value;
    if (!std.mem.eql(u8, wire.schema, schema)) return Error.InvalidSchema;
    if (!std.mem.eql(u8, wire.authority.stwo_cairo_revision, expected.authority.stwo_cairo_revision) or
        !std.mem.eql(u8, wire.authority.stwo_revision, expected.authority.stwo_revision))
        return Error.AuthorityMismatch;
    if (!std.mem.eql(u8, &(try decodeDigest(wire.input_sha256)), &expected.input_sha256))
        return Error.InputMismatch;
    if (wire.components.len == 0 or wire.components.len > max_components)
        return Error.InvalidComponentCount;

    var total_columns: usize = 0;
    for (wire.components) |component| {
        if (component.columns.len == 0 or component.columns.len > max_columns)
            return Error.InvalidColumnCount;
        total_columns = std.math.add(usize, total_columns, component.columns.len) catch
            return Error.ColumnCountOverflow;
        if (total_columns > max_columns) return Error.InvalidColumnCount;
    }
    const components = try allocator.alloc(checkpoint.Component, wire.components.len);
    errdefer allocator.free(components);
    const columns = try allocator.alloc(checkpoint.Column, total_columns);
    errdefer allocator.free(columns);

    var cursor: usize = 0;
    var accumulator = checkpoint.initial_accumulator;
    for (wire.components, components, 0..) |wire_component, *component, component_index| {
        if (wire_component.ordinal != component_index) return Error.InvalidComponentOrdinal;
        for (wire.components[0..component_index]) |previous| {
            if (std.mem.eql(u8, previous.label, wire_component.label)) return Error.DuplicateComponent;
        }
        const component_columns = columns[cursor .. cursor + wire_component.columns.len];
        cursor += wire_component.columns.len;
        var row_count: ?u64 = null;
        for (wire_component.columns, component_columns, 0..) |wire_column, *column, column_index| {
            if (wire_column.ordinal != column_index) return Error.InvalidColumnOrdinal;
            if (row_count) |expected_rows| {
                if (wire_column.row_count != expected_rows) return Error.InconsistentRowCount;
            } else {
                row_count = wire_column.row_count;
            }
            column.* = .{
                .ordinal = wire_column.ordinal,
                .row_count = wire_column.row_count,
                .sha256 = try decodeDigest(wire_column.sha256),
            };
        }
        accumulator = try checkpoint.extendAccumulator(
            accumulator,
            wire_component.ordinal,
            wire_component.label,
            component_columns,
        );
        const stated_accumulator = try decodeDigest(wire_component.accumulator_sha256);
        if (!std.mem.eql(u8, &accumulator, &stated_accumulator)) return Error.AccumulatorMismatch;
        component.* = .{
            .ordinal = wire_component.ordinal,
            .label = wire_component.label,
            .columns = component_columns,
            .accumulator = accumulator,
        };
    }
    const final_accumulator = try decodeDigest(wire.final_accumulator_sha256);
    if (!std.mem.eql(u8, &accumulator, &final_accumulator)) return Error.AccumulatorMismatch;
    return .{
        .allocator = allocator,
        .parsed = parsed,
        .components = components,
        .columns = columns,
        .final_accumulator = final_accumulator,
    };
}

fn decodeDigest(encoded: []const u8) Error!checkpoint.Digest {
    if (encoded.len != 64) return Error.InvalidDigest;
    for (encoded) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return Error.InvalidDigest,
    };
    var digest: checkpoint.Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return Error.InvalidDigest;
    return digest;
}

test "Cairo checkpoint receipt authenticates the Rust authority and accumulator chain" {
    const input_digest = [_]u8{0x11} ** 32;
    const column_digest = try checkpoint.digestColumn(0, "ret_opcode", 0, &.{ 1, 2, 3, 5 });
    const columns = [_]checkpoint.Column{.{
        .ordinal = 0,
        .row_count = 4,
        .sha256 = column_digest,
    }};
    const accumulator = try checkpoint.extendAccumulator(
        checkpoint.initial_accumulator,
        0,
        "ret_opcode",
        &columns,
    );
    const input_hex = std.fmt.bytesToHex(input_digest, .lower);
    const column_hex = std.fmt.bytesToHex(column_digest, .lower);
    const accumulator_hex = std.fmt.bytesToHex(accumulator, .lower);
    const encoded = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"{s}\",\"input_sha256\":\"{s}\",\"authority\":{{\"stwo_cairo_revision\":\"cairo-pin\",\"stwo_revision\":\"stwo-pin\"}},\"components\":[{{\"ordinal\":0,\"label\":\"ret_opcode\",\"columns\":[{{\"ordinal\":0,\"row_count\":4,\"sha256\":\"{s}\"}}],\"accumulator_sha256\":\"{s}\"}}],\"final_accumulator_sha256\":\"{s}\"}}",
        .{ schema, &input_hex, &column_hex, &accumulator_hex, &accumulator_hex },
    );
    defer std.testing.allocator.free(encoded);
    var loaded = try parse(std.testing.allocator, encoded, .{
        .input_sha256 = input_digest,
        .authority = .{
            .stwo_cairo_revision = "cairo-pin",
            .stwo_revision = "stwo-pin",
        },
    });
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.components.len);
    try std.testing.expect(checkpoint.compare(loaded.components[0], loaded.components[0]) == null);
}

test "Cairo checkpoint receipt rejects a forged component accumulator" {
    const input_digest = [_]u8{0x22} ** 32;
    const input_hex = std.fmt.bytesToHex(input_digest, .lower);
    const zero_hex = std.fmt.bytesToHex([_]u8{0} ** 32, .lower);
    const encoded = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"{s}\",\"input_sha256\":\"{s}\",\"authority\":{{\"stwo_cairo_revision\":\"cairo-pin\",\"stwo_revision\":\"stwo-pin\"}},\"components\":[{{\"ordinal\":0,\"label\":\"ret_opcode\",\"columns\":[{{\"ordinal\":0,\"row_count\":1,\"sha256\":\"{s}\"}}],\"accumulator_sha256\":\"{s}\"}}],\"final_accumulator_sha256\":\"{s}\"}}",
        .{ schema, &input_hex, &zero_hex, &zero_hex, &zero_hex },
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(Error.AccumulatorMismatch, parse(std.testing.allocator, encoded, .{
        .input_sha256 = input_digest,
        .authority = .{
            .stwo_cairo_revision = "cairo-pin",
            .stwo_revision = "stwo-pin",
        },
    }));
}
