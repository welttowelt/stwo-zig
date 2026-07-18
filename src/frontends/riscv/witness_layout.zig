//! Canonical identity of the pinned Stark-V opcode witness layout.

const std = @import("std");
const trace = @import("runner/trace.zig");
const layouts = @import("air/trace_columns.zig");

pub const Family = trace.OpcodeFamily;

pub const canonical_families = [_]Family{
    .auipc,
    .base_alu_imm,
    .base_alu_reg,
    .branch_eq,
    .branch_lt,
    .div,
    .jal,
    .jalr,
    .load_store,
    .lt_imm,
    .lt_reg,
    .lui,
    .mul,
    .mulh,
    .shifts_imm,
    .shifts_reg,
};

pub fn LayoutFor(comptime family: Family) type {
    return switch (family) {
        .base_alu_reg => layouts.BaseAluRegColumns,
        .base_alu_imm => layouts.BaseAluImmColumns,
        .shifts_reg => layouts.ShiftsRegColumns,
        .shifts_imm => layouts.ShiftsImmColumns,
        .lt_reg => layouts.LtRegColumns,
        .lt_imm => layouts.LtImmColumns,
        .branch_eq => layouts.BranchEqColumns,
        .branch_lt => layouts.BranchLtColumns,
        .lui => layouts.LuiColumns,
        .auipc => layouts.AuipcColumns,
        .jalr => layouts.JalrColumns,
        .jal => layouts.JalColumns,
        .load_store => layouts.LoadStoreColumns,
        .mul => layouts.MulColumns,
        .mulh => layouts.MulhColumns,
        .div => layouts.DivColumns,
    };
}

/// Hash the exact byte contract consumed by the live CP-11 witness boundary.
pub fn digest() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (canonical_families) |family| updateFamily(&hasher, family);
    return hasher.finalResult();
}

fn updateFamily(hasher: *std.crypto.hash.sha2.Sha256, comptime family: Family) void {
    const Layout = LayoutFor(family);
    const fields = @typeInfo(Layout).@"struct".fields;
    var prefix: [96]u8 = undefined;
    const rendered = std.fmt.bufPrint(
        &prefix,
        "family={s} columns={d}\nnames=",
        .{ @tagName(family), fields.len },
    ) catch unreachable;
    hasher.update(rendered);
    inline for (fields, 0..) |field, index| {
        if (index != 0) hasher.update(",");
        hasher.update(field.name);
    }
    hasher.update("\n");
}

test "witness layout digest matches the live pinned-Rust receipt" {
    const expected = "8896dea17812761ba2246e07508c6d11d455f08519984c0512ce9e7093143b79";
    const actual = std.fmt.bytesToHex(digest(), .lower);
    try std.testing.expectEqualStrings(expected, &actual);
}
