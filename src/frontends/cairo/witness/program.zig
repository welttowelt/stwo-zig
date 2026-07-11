//! Canonical stwo-cairo witness bytecode shared with the generated Rust writers.

const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;

pub const Op = enum(u8) {
    input = 0,
    constant = 1,
    m31_add = 2,
    m31_sub = 3,
    m31_mul = 4,
    m31_neg = 5,
    u16_add = 6,
    u16_shl = 7,
    u16_shr = 8,
    u16_and = 9,
    u32_add = 10,
    u32_sub = 11,
    u32_mul = 12,
    u32_shl = 13,
    u32_shr = 14,
    u32_and = 15,
    u32_xor = 16,
    as_m31 = 17,
    trunc16 = 18,
    table_limb = 19,
    col_write = 20,
    mult_push = 21,
    lookup_word = 22,
    sub_word = 23,
    m31_inverse = 24,
    m31_eq = 25,
    deduce_arg = 26,
    deduce_call = 27,
};

pub const Inst = extern struct {
    op: u8,
    pad: u8 = 0,
    dst: u16,
    a: u32,
    b: u32,
    imm: u32,
};

comptime {
    if (@sizeOf(Inst) != 16 or @alignOf(Inst) != 4) @compileError("Cairo witness instruction ABI drift");
}

pub const Program = struct {
    insts: []const Inst,
    n_regs: u32,
    n_inputs: u32,
    n_cols: u32,
    n_mult_tables: u32,
    n_lookup_words: u32,
    n_sub_words: u32,

    pub fn semanticHash(self: Program) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (std.mem.sliceAsBytes(self.insts)) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
        for ([_]u32{ self.n_regs, self.n_inputs, self.n_cols, self.n_mult_tables, self.n_lookup_words, self.n_sub_words }) |count| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, count, .little);
            for (bytes) |byte| {
                hash ^= byte;
                hash *%= 0x100000001b3;
            }
        }
        return hash;
    }

    pub fn validate(self: Program) !void {
        var next_register: u32 = 0;
        var pending_deduce_args: u32 = 0;
        for (self.insts) |inst| {
            if (inst.pad != 0) return error.InvalidPadding;
            const op = std.meta.intToEnum(Op, inst.op) catch return error.InvalidOpcode;
            const reads_a = switch (op) {
                .input, .constant, .deduce_call => false,
                else => true,
            };
            const reads_b = switch (op) {
                .m31_add, .m31_sub, .m31_mul, .m31_eq, .u16_add, .u32_add, .u32_sub, .u32_mul, .u32_xor => true,
                else => false,
            };
            if (reads_a and inst.a >= next_register) return error.InvalidRegister;
            if (reads_b and inst.b >= next_register) return error.InvalidRegister;
            switch (op) {
                .input => if (inst.a >= self.n_inputs) return error.InvalidInput,
                .col_write => if (inst.imm >= self.n_cols) return error.InvalidOutput,
                .mult_push => if (inst.imm >= self.n_mult_tables) return error.InvalidOutput,
                .lookup_word => if (inst.imm >= self.n_lookup_words) return error.InvalidOutput,
                .sub_word => if (inst.imm >= self.n_sub_words) return error.InvalidOutput,
                .deduce_arg => pending_deduce_args += 1,
                .deduce_call => {
                    if (pending_deduce_args == 0 or inst.b == 0) return error.InvalidDeduce;
                    if (inst.dst != next_register) return error.InvalidRegister;
                    next_register += inst.b;
                    pending_deduce_args = 0;
                    continue;
                },
                else => {},
            }
            if (writesRegister(op)) {
                if (inst.dst != next_register) return error.InvalidRegister;
                next_register += 1;
            }
        }
        if (pending_deduce_args != 0 or next_register != self.n_regs) return error.InvalidRegister;
    }
};

fn writesRegister(op: Op) bool {
    return switch (op) {
        .col_write, .mult_push, .lookup_word, .sub_word, .deduce_arg => false,
        else => true,
    };
}

pub const Outputs = struct {
    columns: []u32,
    lookup_words: []u32,
    sub_words: []u32,
    mult_tables: []u32,

    pub fn deinit(self: *Outputs, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.lookup_words);
        allocator.free(self.sub_words);
        allocator.free(self.mult_tables);
        self.* = undefined;
    }
};

pub fn interpretCore(
    allocator: std.mem.Allocator,
    program: Program,
    inputs: []const u32,
    tableContext: anytype,
) !Outputs {
    try program.validate();
    if (inputs.len < program.n_inputs) return error.InvalidInput;
    const registers = try allocator.alloc(u32, program.n_regs);
    defer allocator.free(registers);
    var outputs = Outputs{
        .columns = try allocator.alloc(u32, program.n_cols),
        .lookup_words = try allocator.alloc(u32, program.n_lookup_words),
        .sub_words = try allocator.alloc(u32, program.n_sub_words),
        .mult_tables = try allocator.alloc(u32, program.n_mult_tables),
    };
    errdefer outputs.deinit(allocator);
    @memset(outputs.columns, 0);
    @memset(outputs.lookup_words, 0);
    @memset(outputs.sub_words, 0);
    @memset(outputs.mult_tables, 0);

    for (program.insts) |inst| {
        const op: Op = @enumFromInt(inst.op);
        const a = if (inst.a < registers.len) registers[inst.a] else 0;
        const b = if (inst.b < registers.len) registers[inst.b] else 0;
        const value: u32 = switch (op) {
            .input => inputs[inst.a],
            .constant => inst.imm,
            .m31_add => M31.fromCanonical(a).add(M31.fromCanonical(b)).v,
            .m31_sub => M31.fromCanonical(a).sub(M31.fromCanonical(b)).v,
            .m31_mul => M31.fromCanonical(a).mul(M31.fromCanonical(b)).v,
            .m31_neg => M31.fromCanonical(a).neg().v,
            .u16_add => (a +% b) & 0xffff,
            .u16_shl => (a << @intCast(inst.imm & 15)) & 0xffff,
            .u16_shr => (a & 0xffff) >> @intCast(inst.imm & 15),
            .u16_and, .u32_and => a & inst.imm,
            .u32_add => a +% b,
            .u32_sub => a -% b,
            .u32_mul => a *% b,
            .u32_shl => a << @intCast(inst.imm & 31),
            .u32_shr => a >> @intCast(inst.imm & 31),
            .u32_xor => a ^ b,
            .as_m31 => a % @import("../../../core/fields/m31.zig").Modulus,
            .trunc16 => a & 0xffff,
            .table_limb => tableContext.tableLimb(inst.b, a, inst.imm),
            .m31_inverse => (M31.fromCanonical(a).inv() catch M31.zero()).v,
            .m31_eq => @intFromBool(a == b),
            .col_write => {
                outputs.columns[inst.imm] = a;
                continue;
            },
            .lookup_word => {
                outputs.lookup_words[inst.imm] = a;
                continue;
            },
            .sub_word => {
                outputs.sub_words[inst.imm] = a;
                continue;
            },
            .mult_push => {
                outputs.mult_tables[inst.imm] +%= 1;
                continue;
            },
            .deduce_arg, .deduce_call => return error.ComputedDeduceRequired,
        };
        registers[inst.dst] = value;
    }
    return outputs;
}

test "cairo witness program: ABI, validation, and core interpretation" {
    const insts = [_]Inst{
        .{ .op = @intFromEnum(Op.input), .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = @intFromEnum(Op.constant), .dst = 1, .a = 0, .b = 0, .imm = 7 },
        .{ .op = @intFromEnum(Op.m31_mul), .dst = 2, .a = 0, .b = 1, .imm = 0 },
        .{ .op = @intFromEnum(Op.col_write), .dst = 0, .a = 2, .b = 0, .imm = 0 },
    };
    const program = Program{ .insts = &insts, .n_regs = 3, .n_inputs = 1, .n_cols = 1, .n_mult_tables = 0, .n_lookup_words = 0, .n_sub_words = 0 };
    try program.validate();
    const NoTables = struct {
        fn tableLimb(_: @This(), _: u32, _: u32, _: u32) u32 {
            return 0;
        }
    };
    var outputs = try interpretCore(std.testing.allocator, program, &.{9}, NoTables{});
    defer outputs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 63), outputs.columns[0]);
}
