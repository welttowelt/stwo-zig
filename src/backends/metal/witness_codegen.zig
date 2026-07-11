const std = @import("std");
const witness = @import("../../frontends/cairo/witness/program.zig");

pub const codegen_version: u64 = 1;

pub fn preambleSource() []const u8 {
    return @embedFile("kernels.metal");
}

pub fn kernelName(allocator: std.mem.Allocator, semantic_hash: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "stwo_zig_witness_{x:0>16}", .{semantic_hash});
}

pub fn generateKernel(
    allocator: std.mem.Allocator,
    program: witness.Program,
    semantic_hash: u64,
) ![]u8 {
    try program.validate();
    var source = std.ArrayList(u8).empty;
    errdefer source.deinit(allocator);
    const writer = source.writer(allocator);
    const name = try kernelName(allocator, semantic_hash);
    defer allocator.free(name);
    try writer.print(
        \\kernel void {s}(
        \\    device uint *arena [[buffer(0)]],
        \\    constant WitnessArgs &args [[buffer(1)]],
        \\    uint row [[thread_position_in_grid]]) {{
        \\    if (row >= args.row_count) return;
        \\
    , .{name});

    const declared = try allocator.alloc(bool, program.n_regs);
    defer allocator.free(declared);
    @memset(declared, false);
    const keep = try liveInstructions(allocator, program);
    defer allocator.free(keep);
    var deduce_args = std.ArrayList(u32).empty;
    defer deduce_args.deinit(allocator);
    var deduce_sequence: u32 = 0;

    for (program.insts, keep) |inst, retain| {
        if (!retain) continue;
        const op: witness.Op = @enumFromInt(inst.op);
        switch (op) {
            .col_write => {
                try writer.print("    arena[arena[args.output_offsets + {}u] + row] = r{};\n", .{ inst.imm, inst.a });
                continue;
            },
            .mult_push => {
                try writer.print(
                    "    atomic_fetch_add_explicit((device atomic_uint *)(arena + arena[args.multiplicity_offsets + {}u] + r{}), 1u, memory_order_relaxed);\n",
                    .{ inst.imm, inst.a },
                );
                continue;
            },
            .lookup_word => {
                try writer.print("    arena[args.lookup_words + {}u * args.row_count + row] = r{};\n", .{ inst.imm, inst.a });
                continue;
            },
            .sub_word => {
                try writer.print("    arena[args.sub_words + {}u * args.row_count + row] = r{};\n", .{ inst.imm, inst.a });
                continue;
            },
            .deduce_arg => {
                try deduce_args.append(allocator, inst.a);
                continue;
            },
            .deduce_call => {
                if (deduce_args.items.len == 0 or inst.b == 0) return error.InvalidDeduce;
                try writer.print("    uint dargs{}[{}] = {{ ", .{ deduce_sequence, deduce_args.items.len });
                for (deduce_args.items, 0..) |register, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try writer.print("r{}", .{register});
                }
                try writer.writeAll(" };\n");
                try writer.print("    uint douts{}[{}];\n", .{ deduce_sequence, inst.b });
                try writer.print(
                    "    witness_deduce_{}(arena, args, dargs{}, douts{});\n",
                    .{ inst.imm, deduce_sequence, deduce_sequence },
                );
                for (0..inst.b) |output| {
                    const register = @as(usize, inst.dst) + output;
                    const declaration = if (!declared[register]) "uint " else "";
                    declared[register] = true;
                    try writer.print("    {s}r{} = douts{}[{}];\n", .{ declaration, register, deduce_sequence, output });
                }
                deduce_args.clearRetainingCapacity();
                deduce_sequence += 1;
                continue;
            },
            else => {},
        }

        const destination: usize = inst.dst;
        const declaration = if (!declared[destination]) "uint " else "";
        declared[destination] = true;
        try writer.print("    {s}r{} = ", .{ declaration, destination });
        switch (op) {
            .input => try writer.print("arena[arena[args.input_offsets + {}u] + row]", .{inst.a}),
            .constant => try writer.print("{}u", .{inst.imm}),
            .m31_add => try writer.print("m31_add(r{}, r{})", .{ inst.a, inst.b }),
            .m31_sub => try writer.print("m31_sub(r{}, r{})", .{ inst.a, inst.b }),
            .m31_mul => try writer.print("m31_mul(r{}, r{})", .{ inst.a, inst.b }),
            .m31_neg => try writer.print("m31_neg(r{})", .{inst.a}),
            .u16_add => try writer.print("(r{} + r{}) & 0xffffu", .{ inst.a, inst.b }),
            .u16_shl => try writer.print("(r{} << {}u) & 0xffffu", .{ inst.a, inst.imm }),
            .u16_shr => try writer.print("(r{} & 0xffffu) >> {}u", .{ inst.a, inst.imm }),
            .u16_and, .u32_and => try writer.print("r{} & {}u", .{ inst.a, inst.imm }),
            .u32_add => try writer.print("r{} + r{}", .{ inst.a, inst.b }),
            .u32_sub => try writer.print("r{} - r{}", .{ inst.a, inst.b }),
            .u32_mul => try writer.print("r{} * r{}", .{ inst.a, inst.b }),
            .u32_shl => try writer.print("r{} << {}u", .{ inst.a, inst.imm }),
            .u32_shr => try writer.print("r{} >> {}u", .{ inst.a, inst.imm }),
            .u32_xor => try writer.print("r{} ^ r{}", .{ inst.a, inst.b }),
            .as_m31 => try writer.print("r{} % 0x7fffffffu", .{inst.a}),
            .trunc16 => try writer.print("r{} & 0xffffu", .{inst.a}),
            .table_limb => switch (inst.b) {
                0 => try writer.print(
                    "r{} < arena[args.table_strides] ? arena[arena[args.table_offsets] + r{}] : 0u",
                    .{ inst.a, inst.a },
                ),
                1 => try writer.print("witness_table_limb(arena, args, r{}, {}u)", .{ inst.a, inst.imm }),
                else => return error.UnsupportedTable,
            },
            .m31_inverse => try writer.print("m31_inv(r{})", .{inst.a}),
            .m31_eq => try writer.print("r{} == r{} ? 1u : 0u", .{ inst.a, inst.b }),
            else => unreachable,
        }
        try writer.writeAll(";\n");
    }
    if (deduce_args.items.len != 0) return error.InvalidDeduce;
    try writer.writeAll("}\n\n");
    return source.toOwnedSlice(allocator);
}

fn liveInstructions(allocator: std.mem.Allocator, program: witness.Program) ![]bool {
    const keep = try allocator.alloc(bool, program.insts.len);
    errdefer allocator.free(keep);
    @memset(keep, false);
    const live = try allocator.alloc(bool, program.n_regs);
    defer allocator.free(live);
    @memset(live, false);
    var index = program.insts.len;
    while (index != 0) {
        index -= 1;
        const inst = program.insts[index];
        const op: witness.Op = @enumFromInt(inst.op);
        const side_effect = switch (op) {
            .col_write, .mult_push, .lookup_word, .sub_word, .deduce_arg, .deduce_call => true,
            else => false,
        };
        const writes_register = switch (op) {
            .col_write, .mult_push, .lookup_word, .sub_word, .deduce_arg => false,
            else => true,
        };
        var needed = side_effect;
        if (writes_register) {
            const output_count: usize = if (op == .deduce_call) inst.b else 1;
            for (0..output_count) |output| needed = needed or live[@as(usize, inst.dst) + output];
        }
        if (!needed) continue;
        keep[index] = true;
        if (writes_register) {
            const output_count: usize = if (op == .deduce_call) inst.b else 1;
            for (0..output_count) |output| live[@as(usize, inst.dst) + output] = false;
        }
        const reads_a = switch (op) {
            .input, .constant, .deduce_call => false,
            else => true,
        };
        const reads_b = switch (op) {
            .m31_add, .m31_sub, .m31_mul, .m31_eq, .u16_add, .u32_add, .u32_sub, .u32_mul, .u32_xor => true,
            else => false,
        };
        if (reads_a) live[inst.a] = true;
        if (reads_b) live[inst.b] = true;
    }
    return keep;
}

test "Metal witness codegen emits arena-native SSA kernel" {
    const insts = [_]witness.Inst{
        .{ .op = @intFromEnum(witness.Op.input), .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = @intFromEnum(witness.Op.constant), .dst = 1, .a = 0, .b = 0, .imm = 3 },
        .{ .op = @intFromEnum(witness.Op.m31_mul), .dst = 2, .a = 0, .b = 1, .imm = 0 },
        .{ .op = @intFromEnum(witness.Op.col_write), .dst = 0, .a = 2, .b = 0, .imm = 0 },
    };
    const program = witness.Program{ .insts = &insts, .n_regs = 3, .n_inputs = 1, .n_cols = 1, .n_mult_tables = 0, .n_lookup_words = 0, .n_sub_words = 0 };
    const source = try generateKernel(std.testing.allocator, program, program.semanticHash());
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "m31_mul(r0, r1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "args.output_offsets") != null);
}
