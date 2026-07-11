const std = @import("std");
const eval = @import("../../frontends/cairo/witness/eval_program.zig");

pub const codegen_version: u64 = 1;

pub fn kernelName(allocator: std.mem.Allocator, semantic_hash: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "stwo_zig_eval_{x:0>16}", .{semantic_hash});
}

pub fn cacheKey(semantic_hash: u64) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (std.mem.asBytes(&semantic_hash)) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    for (std.mem.asBytes(&codegen_version)) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

pub fn generate(allocator: std.mem.Allocator, program: eval.Program) ![]u8 {
    return generateKernel(allocator, program, true);
}

pub fn preambleSource() []const u8 {
    return preamble;
}

pub fn generateKernel(allocator: std.mem.Allocator, program: eval.Program, include_preamble: bool) ![]u8 {
    try program.validate();
    var source = std.ArrayList(u8).empty;
    errdefer source.deinit(allocator);
    const writer = source.writer(allocator);
    if (include_preamble) try writer.writeAll(preamble);
    const name = try kernelName(allocator, program.header.semantic_hash);
    defer allocator.free(name);
    try writer.print(
        \\kernel void {s}(
        \\    device uint *arena [[buffer(0)]],
        \\    constant EvalArgs &args [[buffer(1)]],
        \\    uint row [[thread_position_in_grid]]) {{
        \\    if (row >= args.row_count) return;
        \\
    , .{name});

    const base_declared = try allocator.alloc(bool, program.header.max_base_regs);
    defer allocator.free(base_declared);
    @memset(base_declared, false);
    for (program.base_insts) |inst| {
        const decl = if (!base_declared[inst.dst]) "uint " else "";
        base_declared[inst.dst] = true;
        switch (inst.op) {
            .trace_col, .preprocessed_col => try writer.print(
                "    {s}b{} = trace_value(arena, args, {}u, {}u, row, {});\n",
                .{ decl, inst.dst, inst.interaction, inst.a, inst.imm },
            ),
            .param => try writer.print("    {s}b{} = arena[args.base_params + {}u];\n", .{ decl, inst.dst, inst.a }),
            .constant => try writer.print("    {s}b{} = {}u;\n", .{ decl, inst.dst, inst.a }),
            .add => try writer.print("    {s}b{} = m31_add(b{}, b{});\n", .{ decl, inst.dst, inst.a, inst.b }),
            .sub => try writer.print("    {s}b{} = m31_sub(b{}, b{});\n", .{ decl, inst.dst, inst.a, inst.b }),
            .mul => try writer.print("    {s}b{} = m31_mul(b{}, b{});\n", .{ decl, inst.dst, inst.a, inst.b }),
            .neg => try writer.print("    {s}b{} = m31_neg(b{});\n", .{ decl, inst.dst, inst.a }),
            .inv => try writer.print("    {s}b{} = m31_inv(b{});\n", .{ decl, inst.dst, inst.a }),
        }
    }

    const ext_declared = try allocator.alloc(bool, program.header.max_ext_regs);
    defer allocator.free(ext_declared);
    @memset(ext_declared, false);
    for (program.ext_insts) |inst| {
        const decl = if (!ext_declared[inst.dst]) "Qm31 " else "";
        ext_declared[inst.dst] = true;
        switch (inst.op) {
            .secure_col => try writer.print("    {s}e{} = {{ b{}, b{}, b{}, b{} }};\n", .{ decl, inst.dst, inst.a, inst.b, inst.c, inst.d }),
            .param => try writer.print("    {s}e{} = load_qm31(arena, args.ext_params + {}u * 4u);\n", .{ decl, inst.dst, inst.a }),
            .constant => try writer.print("    {s}e{} = {{ {}u, {}u, {}u, {}u }};\n", .{ decl, inst.dst, inst.a, inst.b, inst.c, inst.d }),
            .add => try writer.print("    {s}e{} = qm_add(e{}, e{});\n", .{ decl, inst.dst, inst.a, inst.b }),
            .sub => try writer.print("    {s}e{} = qm_sub(e{}, e{});\n", .{ decl, inst.dst, inst.a, inst.b }),
            .mul => try writer.print("    {s}e{} = qm_mul(e{}, e{});\n", .{ decl, inst.dst, inst.a, inst.b }),
            .neg => try writer.print("    {s}e{} = qm_neg(e{});\n", .{ decl, inst.dst, inst.a }),
        }
    }

    try writer.writeAll("    Qm31 acc = { 0u, 0u, 0u, 0u };\n");
    for (program.constraint_roots, 0..) |root, index| try writer.print(
        "    acc = qm_add(acc, qm_mul(e{}, load_qm31(arena, args.random_coeffs + (args.rc_base + {}u) * 4u)));\n",
        .{ root, index },
    );
    try writer.writeAll(
        \\    Qm31 result = qm_mul_base(acc, arena[args.denom_inv + (row >> args.trace_log_size)]);
        \\    arena[args.coord_0 + row] = m31_add(arena[args.coord_0 + row], result.a);
        \\    arena[args.coord_1 + row] = m31_add(arena[args.coord_1 + row], result.b);
        \\    arena[args.coord_2 + row] = m31_add(arena[args.coord_2 + row], result.c);
        \\    arena[args.coord_3 + row] = m31_add(arena[args.coord_3 + row], result.d);
        \\}
        \\
    );
    return source.toOwnedSlice(allocator);
}

const preamble =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\constant uint M31_P = 0x7fffffffu;
    \\struct Qm31 { uint a; uint b; uint c; uint d; };
    \\struct EvalArgs {
    \\    uint trace_offsets;
    \\    uint interaction_offsets;
    \\    uint base_params;
    \\    uint ext_params;
    \\    uint random_coeffs;
    \\    uint denom_inv;
    \\    uint coord_0;
    \\    uint coord_1;
    \\    uint coord_2;
    \\    uint coord_3;
    \\    uint row_count;
    \\    uint trace_log_size;
    \\    uint domain_log_size;
    \\    uint rc_base;
    \\};
    \\inline uint m31_reduce(ulong v) { v = (v & M31_P) + (v >> 31); v = (v & M31_P) + (v >> 31); return v == M31_P ? 0u : uint(v); }
    \\inline uint m31_add(uint a, uint b) { return m31_reduce(ulong(a) + b); }
    \\inline uint m31_sub(uint a, uint b) { return a >= b ? a - b : a + M31_P - b; }
    \\inline uint m31_mul(uint a, uint b) { return m31_reduce(ulong(a) * b); }
    \\inline uint m31_neg(uint a) { return a == 0u ? 0u : M31_P - a; }
    \\inline uint m31_inv(uint v) { uint r = 1u, b = v, e = M31_P - 2u; while (e != 0u) { if (e & 1u) r = m31_mul(r, b); b = m31_mul(b, b); e >>= 1u; } return r; }
    \\inline Qm31 qm_add(Qm31 l, Qm31 r) { return { m31_add(l.a,r.a), m31_add(l.b,r.b), m31_add(l.c,r.c), m31_add(l.d,r.d) }; }
    \\inline Qm31 qm_sub(Qm31 l, Qm31 r) { return { m31_sub(l.a,r.a), m31_sub(l.b,r.b), m31_sub(l.c,r.c), m31_sub(l.d,r.d) }; }
    \\inline Qm31 qm_neg(Qm31 v) { return { m31_neg(v.a), m31_neg(v.b), m31_neg(v.c), m31_neg(v.d) }; }
    \\inline Qm31 qm_mul_base(Qm31 v, uint s) { return { m31_mul(v.a,s), m31_mul(v.b,s), m31_mul(v.c,s), m31_mul(v.d,s) }; }
    \\inline Qm31 qm_mul(Qm31 l, Qm31 r) {
    \\    uint x0=m31_sub(m31_mul(l.a,r.a),m31_mul(l.b,r.b)), x1=m31_add(m31_mul(l.a,r.b),m31_mul(l.b,r.a));
    \\    uint y0=m31_sub(m31_mul(l.c,r.c),m31_mul(l.d,r.d)), y1=m31_add(m31_mul(l.c,r.d),m31_mul(l.d,r.c));
    \\    uint c0=m31_sub(m31_mul(l.a,r.c),m31_mul(l.b,r.d)), c1=m31_add(m31_mul(l.a,r.d),m31_mul(l.b,r.c));
    \\    uint c2=m31_sub(m31_mul(l.c,r.a),m31_mul(l.d,r.b)), c3=m31_add(m31_mul(l.c,r.b),m31_mul(l.d,r.a));
    \\    return { m31_add(x0,m31_sub(m31_add(y0,y0),y1)), m31_add(x1,m31_add(y0,m31_add(y1,y1))), m31_add(c0,c2), m31_add(c1,c3) };
    \\}
    \\inline Qm31 load_qm31(device uint *arena, uint off) { return { arena[off], arena[off+1u], arena[off+2u], arena[off+3u] }; }
    \\inline uint bit_reverse(uint i, uint bits) { return bits == 0u ? 0u : reverse_bits(i) >> (32u-bits); }
    \\inline uint offset_circle(uint i, uint domain_log, uint eval_log, int offset) {
    \\    uint prev=bit_reverse(i,eval_log), half_size=1u<<(eval_log-1u); int step=offset*int(1u<<(eval_log-domain_log-1u));
    \\    if (prev<half_size) { int p=(int(prev)+step)%int(half_size); if(p<0)p+=int(half_size); prev=uint(p); }
    \\    else { int p=(int(prev)-step)%int(half_size); if(p<0)p+=int(half_size); prev=uint(p)+half_size; }
    \\    return bit_reverse(prev,eval_log);
    \\}
    \\inline uint trace_value(device uint *arena, constant EvalArgs &args, uint interaction, uint column, uint row, int offset) {
    \\    uint target=offset==0 ? row : offset_circle(row,args.domain_log_size,ctz(args.row_count),offset);
    \\    uint global=arena[args.interaction_offsets+interaction]+column;
    \\    return arena[arena[args.trace_offsets+global]+target];
    \\}
    \\
;

test "Metal evaluation codegen: emits fused arena kernel" {
    var base = [_]eval.BaseInst{
        .{ .op = .trace_col, .interaction = 0, .dst = 0, .a = 2, .b = 0, .imm = -1 },
        .{ .op = .constant, .interaction = 0, .dst = 1, .a = 7, .b = 0, .imm = 0 },
        .{ .op = .mul, .interaction = 0, .dst = 2, .a = 0, .b = 1, .imm = 0 },
    };
    var ext = [_]eval.ExtInst{
        .{ .op = .secure_col, .dst = 0, .a = 2, .b = 1, .c = 0, .d = 1 },
        .{ .op = .param, .dst = 1, .a = 0, .b = 0, .c = 0, .d = 0 },
        .{ .op = .mul, .dst = 2, .a = 0, .b = 1, .c = 0, .d = 0 },
    };
    var roots = [_]u32{2};
    const program = eval.Program{
        .allocator = std.testing.allocator,
        .header = .{ .flags = eval.Flag.prefinalized_logup, .semantic_hash = 0x1234, .capability_bits = eval.Capability.prefinalized_logup | eval.Capability.ext_mul, .n_interactions = 1, .n_base_params = 0, .n_ext_params = 1, .n_constraints = 1, .max_base_regs = 3, .max_ext_regs = 3, .domain_log_size = 8 },
        .base_consts = &.{},
        .ext_consts = &.{},
        .base_insts = &base,
        .ext_insts = &ext,
        .constraint_roots = &roots,
    };
    const source = try generate(std.testing.allocator, program);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "b2 = m31_mul(b0, b1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "qm_mul(e0, e1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "args.coord_3 + row") != null);
}
