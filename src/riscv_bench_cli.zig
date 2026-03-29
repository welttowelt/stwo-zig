//! RISC-V end-to-end proving benchmark — comparable to stark-v.
//!
//! Measures the FULL pipeline: ELF execution → trace → STARK prove → verify.
//! Reports throughput in kHz (VM cycles / total_time / 1000) for direct
//! comparison with stark-v's published ~567 kHz on M2 Max.
//!
//! Usage:
//!   ./riscv_bench --fib-n 500000

const std = @import("std");
const runner = @import("frontends/riscv/runner/mod.zig");
const riscv_prover = @import("frontends/riscv/prover.zig");
const pcs_core = @import("core/pcs/mod.zig");
const trace_mod = @import("frontends/riscv/runner/trace.zig");

const Timer = struct {
    start: i128,
    fn begin() Timer { return .{ .start = std.time.nanoTimestamp() }; }
    fn elapsedMs(self: Timer) f64 {
        const ns = std.time.nanoTimestamp() - self.start;
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }
    fn elapsedSec(self: Timer) f64 {
        return self.elapsedMs() / 1000.0;
    }
};

fn makeFibElf(allocator: std.mem.Allocator, n: u32) ![]u8 {
    var n_lo: u32 = n & 0xFFF;
    var n_hi: u32 = n & 0xFFFFF000;
    if (n_lo >= 0x800) {
        n_hi +%= 0x1000;
        n_lo = n_lo;
    }

    const instructions = [_]u32{
        // ADDI x1, x0, 0    (a = 0)
        @as(u32, 0) << 20 | (0 << 15) | (0b000 << 12) | (1 << 7) | 0x13,
        // ADDI x2, x0, 1    (b = 1)
        @as(u32, 1) << 20 | (0 << 15) | (0b000 << 12) | (2 << 7) | 0x13,
        // ADDI x3, x0, 2    (i = 2)
        @as(u32, 2) << 20 | (0 << 15) | (0b000 << 12) | (3 << 7) | 0x13,
        // ADDI x4, x0, N_lo
        (n_lo << 20) | (0 << 15) | (0b000 << 12) | (4 << 7) | 0x13,
        // LUI x5, N_hi
        (n_hi & 0xFFFFF000) | (5 << 7) | 0x37,
        // ADD x4, x4, x5    (N = N_lo + N_hi)
        (5 << 20) | (4 << 15) | (0b000 << 12) | (4 << 7) | 0x33,
        // loop: ADD x6, x1, x2  (tmp = a + b)
        (2 << 20) | (1 << 15) | (0b000 << 12) | (6 << 7) | 0x33,
        // ADDI x1, x2, 0    (a = b)
        (0 << 20) | (2 << 15) | (0b000 << 12) | (1 << 7) | 0x13,
        // ADDI x2, x6, 0    (b = tmp)
        (0 << 20) | (6 << 15) | (0b000 << 12) | (2 << 7) | 0x13,
        // ADDI x3, x3, 1    (i++)
        (1 << 20) | (3 << 15) | (0b000 << 12) | (3 << 7) | 0x13,
        // BNE x3, x4, -16   (if i != N, loop back 4 instructions)
        encodeBne(3, 4, @as(i13, -16)),
        // ECALL
        0x00000073,
    };

    const code_size = instructions.len * 4;
    const elf_size = 84 + code_size;
    const buf = try allocator.alloc(u8, elf_size);
    @memset(buf, 0);

    // ELF header
    buf[0] = 0x7F; buf[1] = 'E'; buf[2] = 'L'; buf[3] = 'F';
    buf[4] = 1; buf[5] = 1; buf[6] = 1;
    buf[16] = 2; buf[18] = 0xF3; buf[20] = 1;
    std.mem.writeInt(u32, buf[24..28], 0x10000, .little);
    buf[28] = 52; buf[40] = 52; buf[42] = 32; buf[44] = 1;
    buf[52] = 1; buf[56] = 84;
    std.mem.writeInt(u32, buf[60..64], 0x10000, .little);
    std.mem.writeInt(u32, buf[68..72], @intCast(code_size), .little);
    std.mem.writeInt(u32, buf[72..76], @intCast(code_size), .little);

    for (instructions, 0..) |inst, i| {
        const off = 84 + i * 4;
        std.mem.writeInt(u32, buf[off..][0..4], inst, .little);
    }
    return buf;
}

fn encodeBne(rs1: u5, rs2: u5, offset: i13) u32 {
    const off: u13 = @bitCast(offset);
    const imm12: u1 = @truncate(off >> 12);
    const imm10_5: u6 = @truncate(off >> 5);
    const imm4_1: u4 = @truncate(off >> 1);
    const imm11: u1 = @truncate(off >> 11);
    return (@as(u32, imm12) << 31) | (@as(u32, imm10_5) << 25) |
        (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (0b001 << 12) | (@as(u32, imm4_1) << 8) | (@as(u32, imm11) << 7) | 0x63;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var fib_n: u32 = 10000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--fib-n") and i + 1 < args.len) {
            i += 1;
            fib_n = try std.fmt.parseInt(u32, args[i], 10);
        }
    }

    std.debug.print("RISC-V End-to-End Proving Benchmark\n", .{});
    std.debug.print("====================================\n", .{});
    std.debug.print("fib(N) = fib({d})\n\n", .{fib_n});

    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };

    // Stage 1: Generate ELF
    const t_total = Timer.begin();
    const elf_bytes = try makeFibElf(allocator, fib_n);
    defer allocator.free(elf_bytes);

    // Stage 2: Execute
    const t_exec = Timer.begin();
    var run_result = try runner.run(allocator, elf_bytes, fib_n * 6);
    defer run_result.deinit();
    const exec_ms = t_exec.elapsedMs();

    const cycles = run_result.execution_trace.step_count;
    std.debug.print("Execute:  {d:.1}ms  ({d} cycles, {d:.0} kHz)\n", .{
        exec_ms, cycles, @as(f64, @floatFromInt(cycles)) / exec_ms,
    });

    // Stage 3: Prove
    const t_prove = Timer.begin();
    var output = try riscv_prover.proveRiscV(allocator, config, &run_result.execution_trace);
    defer output.deinit(allocator);
    const prove_ms = t_prove.elapsedMs();

    std.debug.print("Prove:    {d:.1}ms\n", .{prove_ms});

    // Stage 4: Verify
    const t_verify = Timer.begin();
    try riscv_prover.verifyRiscV(allocator, config, output.statement, output.proof);
    const verify_ms = t_verify.elapsedMs();

    std.debug.print("Verify:   {d:.1}ms\n", .{verify_ms});

    const total_ms = t_total.elapsedMs();
    const prove_verify_ms = prove_ms + verify_ms;
    const run_prove_ms = exec_ms + prove_ms;

    std.debug.print("\n", .{});
    std.debug.print("Total:    {d:.1}ms\n", .{total_ms});
    std.debug.print("Run+Prove:{d:.1}ms  ({d:.1} kHz)\n", .{
        run_prove_ms,
        @as(f64, @floatFromInt(cycles)) / run_prove_ms,
    });
    std.debug.print("Prove+Verify: {d:.1}ms\n", .{prove_verify_ms});
    std.debug.print("\n", .{});

    // stark-v comparison
    const run_prove_khz = @as(f64, @floatFromInt(cycles)) / run_prove_ms;
    std.debug.print("Throughput (run+prove): {d:.1} kHz\n", .{run_prove_khz});
    std.debug.print("stark-v reference:     567.0 kHz (M2 Max, fib 5M)\n", .{});
    std.debug.print("Ratio:                 {d:.2}x\n", .{run_prove_khz / 567.0});
}
