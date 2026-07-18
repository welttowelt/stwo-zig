//! RISC-V trace dumper CLI for cross-verification.
//!
//! Runs a RISC-V RV32IM ELF binary through the Zig execution engine and
//! writes a JSON trace suitable for equivalence comparison with the Rust
//! stark-v trace dumper.
//!
//! Usage:
//!   riscv-trace-dump --elf <path> [--output <trace.json>] [--max-steps N]
//!
//! When --output is omitted the JSON is written to stdout.

const std = @import("std");
const runner = @import("frontends/riscv/runner/mod.zig");
const trace_dump = @import("frontends/riscv/runner/trace_dump.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var elf_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var decode_file: ?[]const u8 = null;
    var program_tuples: ?[]const u8 = null;
    var poseidon2_file: ?[]const u8 = null;
    var transcript_prefix: ?[]const u8 = null;
    var witness_rows: ?[]const u8 = null;
    var ordered_accesses: ?[]const u8 = null;
    var max_steps: usize = 1_000_000;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--elf") and i + 1 < args.len) {
            i += 1;
            elf_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--decode-file") and i + 1 < args.len) {
            i += 1;
            decode_file = args[i];
        } else if (std.mem.eql(u8, args[i], "--program-tuples") and i + 1 < args.len) {
            i += 1;
            program_tuples = args[i];
        } else if (std.mem.eql(u8, args[i], "--poseidon2-file") and i + 1 < args.len) {
            i += 1;
            poseidon2_file = args[i];
        } else if (std.mem.eql(u8, args[i], "--transcript-prefix") and i + 1 < args.len) {
            i += 1;
            transcript_prefix = args[i];
        } else if (std.mem.eql(u8, args[i], "--witness-rows") and i + 1 < args.len) {
            i += 1;
            witness_rows = args[i];
        } else if (std.mem.eql(u8, args[i], "--ordered-accesses") and i + 1 < args.len) {
            i += 1;
            ordered_accesses = args[i];
        } else if (std.mem.eql(u8, args[i], "--max-steps") and i + 1 < args.len) {
            i += 1;
            max_steps = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
    }

    if (decode_file) |path| {
        try dumpDecodeMatrix(allocator, path);
        return;
    }

    if (program_tuples) |path| {
        try dumpProgramTuples(allocator, path);
        return;
    }

    if (poseidon2_file) |path| {
        try dumpPoseidon2(allocator, path);
        return;
    }

    if (transcript_prefix) |path| {
        try dumpTranscriptPrefix(allocator, path);
        return;
    }

    if (witness_rows) |path| {
        try dumpWitnessRows(allocator, path, max_steps);
        return;
    }

    if (ordered_accesses) |path| {
        try dumpOrderedAccesses(allocator, path, max_steps);
        return;
    }

    if (elf_path == null) {
        printUsage();
        std.process.exit(1);
    }

    // Read ELF binary.
    const elf_bytes = std.fs.cwd().readFileAlloc(allocator, elf_path.?, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error: cannot read ELF file '{s}': {}\n", .{ elf_path.?, err });
        std.process.exit(1);
    };
    defer allocator.free(elf_bytes);

    // Execute.
    var result = runner.run(allocator, elf_bytes, max_steps) catch |err| {
        std.debug.print("error: execution failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer result.deinit();

    // Serialize trace to an in-memory buffer, then write it out.
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);
    try trace_dump.writeTraceJson(json_buf.writer(allocator), &result.execution_trace, result.cpu_final);

    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(json_buf.items);
    } else {
        // Write to stdout.
        try json_buf.append(allocator, '\n');
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        try stdout.writeAll(json_buf.items);
    }
}

const Family = runner.trace.OpcodeFamily;

const CANONICAL_FAMILIES = [_]Family{
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

fn LayoutFor(comptime family: Family) type {
    const layouts = @import("frontends/riscv/air/trace_columns.zig");
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

fn familyRowCount(trace: *const runner.trace.Trace, family: Family) !usize {
    var count: usize = 0;
    for (trace.rows.items) |row| {
        if (try runner.trace.proofOpcodeFamily(row.opcode) == family) count += 1;
    }
    return count;
}

fn writeFamilyWitness(
    allocator: std.mem.Allocator,
    writer: anytype,
    trace: *const runner.trace.Trace,
    comptime family: Family,
) !void {
    const row_count = try familyRowCount(trace, family);
    const padded_count = @max(row_count, 1);
    const log_size: u32 = @intCast(std.math.log2_int_ceil(usize, padded_count));
    var columns = try trace.columnsForFamily(allocator, family, log_size);
    defer columns.deinit(allocator);
    const Layout = LayoutFor(family);
    const fields = @typeInfo(Layout).@"struct".fields;
    std.debug.assert(fields.len == columns.n_columns);

    try writer.print("family={s} rows={d} columns={d}\n", .{
        @tagName(family),
        columns.n_real_rows,
        columns.n_columns,
    });
    try writer.writeAll("names=");
    inline for (fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(field.name);
    }
    try writer.writeByte('\n');
    for (0..columns.n_real_rows) |row| {
        try writer.print("row={d}", .{row});
        for (columns.columns[0..columns.n_columns]) |column| {
            try writer.print(" {d}", .{column[row].v});
        }
        try writer.writeByte('\n');
    }
}

fn dumpWitnessRows(allocator: std.mem.Allocator, path: []const u8, max_steps: usize) !void {
    const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(elf_bytes);
    var result = try runner.run(allocator, elf_bytes, max_steps);
    defer result.deinit();

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    inline for (CANONICAL_FAMILIES) |family| {
        try writeFamilyWitness(allocator, writer, &result.execution_trace, family);
    }
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}

const OrderedAccess = struct {
    clock: u32,
    kind: u8,
    ordinal: u8,
    family_index: usize,
    family: []const u8,
    role: []const u8,
    addr_space: u32,
    addr: u32,
    previous_clock: u32,
    previous: u32,
    next: u32,
};

fn canonicalFamilyIndex(family: Family) usize {
    inline for (CANONICAL_FAMILIES, 0..) |candidate, index| {
        if (family == candidate) return index;
    }
    unreachable;
}

fn columnIndex(comptime Layout: type, comptime name: []const u8) usize {
    inline for (@typeInfo(Layout).@"struct".fields, 0..) |field, index| {
        if (comptime std.mem.eql(u8, field.name, name)) return index;
    }
    @compileError("missing witness column " ++ name);
}

fn columnValue(
    columns: *const runner.trace.TraceColumns,
    comptime Layout: type,
    comptime name: []const u8,
    row: usize,
) u32 {
    return columns.columns[columnIndex(Layout, name)][row].v;
}

fn columnWord(
    columns: *const runner.trace.TraceColumns,
    comptime Layout: type,
    comptime role: []const u8,
    comptime phase: []const u8,
    row: usize,
) u32 {
    return columnValue(columns, Layout, role ++ "_" ++ phase ++ "_0", row) |
        (columnValue(columns, Layout, role ++ "_" ++ phase ++ "_1", row) << 8) |
        (columnValue(columns, Layout, role ++ "_" ++ phase ++ "_2", row) << 16) |
        (columnValue(columns, Layout, role ++ "_" ++ phase ++ "_3", row) << 24);
}

fn appendColumnAccess(
    allocator: std.mem.Allocator,
    accesses: *std.ArrayList(OrderedAccess),
    columns: *const runner.trace.TraceColumns,
    comptime family: Family,
    row: usize,
    ordinal: u8,
    comptime role: []const u8,
    addr_space: u32,
) !void {
    const Layout = LayoutFor(family);
    try accesses.append(allocator, .{
        .clock = columnValue(columns, Layout, "clock", row),
        .kind = 1,
        .ordinal = ordinal,
        .family_index = canonicalFamilyIndex(family),
        .family = @tagName(family),
        .role = role,
        .addr_space = addr_space,
        .addr = columnValue(columns, Layout, role ++ "_addr", row),
        .previous_clock = columnValue(columns, Layout, role ++ "_clock_prev", row),
        .previous = columnWord(columns, Layout, role, "prev", row),
        .next = columnWord(columns, Layout, role, "next", row),
    });
}

fn appendFamilyAccesses(
    allocator: std.mem.Allocator,
    accesses: *std.ArrayList(OrderedAccess),
    trace: *const runner.trace.Trace,
    comptime family: Family,
) !void {
    const row_count = try familyRowCount(trace, family);
    const log_size: u32 = @intCast(std.math.log2_int_ceil(usize, @max(row_count, 1)));
    var columns = try trace.columnsForFamily(allocator, family, log_size);
    defer columns.deinit(allocator);
    for (0..columns.n_real_rows) |row| switch (family) {
        .base_alu_reg, .shifts_reg, .lt_reg, .mul, .mulh, .div => {
            try appendColumnAccess(allocator, accesses, &columns, family, row, 0, "rs1", 0);
            try appendColumnAccess(allocator, accesses, &columns, family, row, 1, "rs2", 0);
            try appendColumnAccess(allocator, accesses, &columns, family, row, 2, "rd", 0);
        },
        .base_alu_imm, .shifts_imm, .lt_imm, .jalr => {
            try appendColumnAccess(allocator, accesses, &columns, family, row, 0, "rs1", 0);
            try appendColumnAccess(allocator, accesses, &columns, family, row, 1, "rd", 0);
        },
        .branch_eq, .branch_lt => {
            try appendColumnAccess(allocator, accesses, &columns, family, row, 0, "rs1", 0);
            try appendColumnAccess(allocator, accesses, &columns, family, row, 1, "rs2", 0);
        },
        .lui, .auipc, .jal => try appendColumnAccess(allocator, accesses, &columns, family, row, 0, "rd", 0),
        .load_store => {
            const Layout = LayoutFor(family);
            const is_store = columnValue(&columns, Layout, "opcode_sb_flag", row) +
                columnValue(&columns, Layout, "opcode_sh_flag", row) +
                columnValue(&columns, Layout, "opcode_sw_flag", row) != 0;
            try appendColumnAccess(allocator, accesses, &columns, family, row, 0, "rs1", 0);
            try appendColumnAccess(
                allocator,
                accesses,
                &columns,
                family,
                row,
                1,
                "src",
                if (is_store) 0 else 1,
            );
            try appendColumnAccess(
                allocator,
                accesses,
                &columns,
                family,
                row,
                2,
                "dst",
                if (is_store) 1 else 0,
            );
        },
    };
}

fn limbsToWord(limbs: [4]@import("core/fields/m31.zig").M31) u32 {
    var value: u32 = 0;
    for (limbs, 0..) |limb, index| value |= limb.v << @intCast(8 * index);
    return value;
}

fn orderedAccessLessThan(_: void, lhs: OrderedAccess, rhs: OrderedAccess) bool {
    if (lhs.clock != rhs.clock) return lhs.clock < rhs.clock;
    if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
    if (lhs.ordinal != rhs.ordinal) return lhs.ordinal < rhs.ordinal;
    if (lhs.addr_space != rhs.addr_space) return lhs.addr_space < rhs.addr_space;
    if (lhs.addr != rhs.addr) return lhs.addr < rhs.addr;
    return lhs.family_index < rhs.family_index;
}

fn dumpOrderedAccesses(allocator: std.mem.Allocator, path: []const u8, max_steps: usize) !void {
    const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(elf_bytes);
    var result = try runner.run(allocator, elf_bytes, max_steps);
    defer result.deinit();

    var accesses: std.ArrayList(OrderedAccess) = .{};
    defer accesses.deinit(allocator);
    inline for (CANONICAL_FAMILIES) |family| {
        try appendFamilyAccesses(allocator, &accesses, &result.execution_trace, family);
    }
    for (result.state_chain_tracker.clock_updates_reg.items) |gap| {
        const value = limbsToWord(gap.value_limbs);
        try accesses.append(allocator, .{
            .clock = gap.clk,
            .kind = 0,
            .ordinal = 0,
            .family_index = std.math.maxInt(usize),
            .family = "clock_update",
            .role = "clock_update",
            .addr_space = gap.addr_space,
            .addr = gap.addr,
            .previous_clock = gap.clk_prev,
            .previous = value,
            .next = value,
        });
    }
    for (result.state_chain_tracker.clock_updates_mem.items) |gap| {
        const value = limbsToWord(gap.value_limbs);
        try accesses.append(allocator, .{
            .clock = gap.clk,
            .kind = 0,
            .ordinal = 0,
            .family_index = std.math.maxInt(usize),
            .family = "clock_update",
            .role = "clock_update",
            .addr_space = gap.addr_space,
            .addr = gap.addr,
            .previous_clock = gap.clk_prev,
            .previous = value,
            .next = value,
        });
    }
    std.mem.sort(OrderedAccess, accesses.items, {}, orderedAccessLessThan);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    for (accesses.items) |access| {
        try writer.print(
            "clock={d} ordinal={d} family={s} role={s} space={d} addr={d} previous_clock={d} previous={d} next={d}\n",
            .{
                access.clock,
                access.ordinal,
                access.family,
                access.role,
                access.addr_space,
                access.addr,
                access.previous_clock,
                access.previous,
                access.next,
            },
        );
    }
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: riscv-trace-dump --elf <path> [--output <trace.json>] [--max-steps N]
        \\
        \\Options:
        \\  --elf <path>         Path to a RISC-V RV32IM ELF binary (required)
        \\  --output <path>      Write JSON trace to file (default: stdout)
        \\  --max-steps <N>      Maximum execution steps (default: 1000000)
        \\  --help, -h           Show this message
        \\
    , .{});
}

/// Decode-matrix mode for oracle parity: canonical one-line-per-word output
/// byte-compared against the pinned Stark-V decoder over the same corpus.
fn dumpDecodeMatrix(allocator: std.mem.Allocator, path: []const u8) !void {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(raw);
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    var offset: usize = 0;
    while (offset + 4 <= raw.len) : (offset += 4) {
        const word = std.mem.readInt(u32, raw[offset..][0..4], .little);
        if (runner.DecodedInst.decode(word)) |inst| {
            try writer.print("{x:0>8} {s} {d} {d} {d} {d}\n", .{
                word,
                @tagName(inst.opcode),
                inst.rd,
                inst.rs1,
                inst.rs2,
                inst.imm,
            });
        } else |_| {
            try writer.print("{x:0>8} -\n", .{word});
        }
    }
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}

/// Program-tuple mode for oracle parity: decode_program rows over the
/// declared region, canonical line format, byte-compared with the oracle.
fn dumpProgramTuples(allocator: std.mem.Allocator, path: []const u8) !void {
    const program_decode = @import("frontends/riscv/air/program/decode.zig");
    const memory_mod = @import("frontends/riscv/runner/memory.zig");
    const elf_loader = @import("frontends/riscv/runner/elf_loader.zig");

    const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(elf_bytes);
    var mem = memory_mod.Memory.init(allocator);
    defer mem.deinit();
    const elf_info = try elf_loader.loadElf(elf_bytes, &mem);
    const layout = elf_info.memory_layout;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    var addr: u32 = layout.program_base;
    while (addr < layout.program_end) : (addr += 4) {
        const word = mem.readU32(addr);
        const values = try program_decode.decodeProgramWord(word);
        try writer.print("{x:0>8} {d} {d} {d} {d}\n", .{
            addr, values[0], values[1], values[2], values[3],
        });
    }
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}

/// Poseidon2 permutation parity mode: 16-word LE states in, permuted states
/// out, byte-compared with the pinned oracle over the same corpus.
fn dumpPoseidon2(allocator: std.mem.Allocator, path: []const u8) !void {
    const poseidon2 = @import("frontends/riscv/air/memory_commitment/poseidon2.zig");
    const M31 = @import("core/fields/m31.zig").M31;

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(raw);
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    var offset: usize = 0;
    while (offset + 64 <= raw.len) : (offset += 64) {
        var state: poseidon2.State = undefined;
        for (0..16) |i| {
            const word = std.mem.readInt(u32, raw[offset + i * 4 ..][0..4], .little);
            state[i] = M31.fromU64(word);
        }
        poseidon2.permute(&state);
        for (state, 0..) |value, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.print("{d}", .{value.v});
        }
        try writer.writeByte('\n');
    }
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}

/// Blake2s channel wrapper that records `mix_u32s len=N digest=<hex>` lines
/// after every mix step. `PublicData.mixInto` drives the sequence — this is
/// pure instrumentation, mirroring the oracle adapter's RecordingChannel.
/// The channel mix contract is infallible, so recording failures abort
/// rather than silently truncating the transcript.
const DigestRecorder = struct {
    channel: @import("core/channel/blake2s.zig").Blake2sChannel = .{},
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),

    pub fn mixU32s(self: *DigestRecorder, values: []const u32) void {
        self.channel.mixU32s(values);
        const writer = self.out.writer(self.allocator);
        writer.print("mix_u32s len={d} ", .{values.len}) catch
            @panic("transcript prefix recording failed");
        self.appendDigest();
    }

    fn appendDigest(self: *DigestRecorder) void {
        const writer = self.out.writer(self.allocator);
        writer.print("digest=", .{}) catch
            @panic("transcript prefix recording failed");
        for (self.channel.digestBytes()) |byte| {
            writer.print("{x:0>2}", .{byte}) catch
                @panic("transcript prefix recording failed");
        }
        writer.print("\n", .{}) catch
            @panic("transcript prefix recording failed");
    }
};

/// Shared-transcript-prefix mode: run the ELF, build the prover-shaped
/// public data (with sparse-tree roots, exactly like the staged prover),
/// then replay the pinned Stark-V pre-commitment Fiat-Shamir prefix — a
/// default Blake2s channel seeded by `PublicData.mixInto` — printing the
/// channel digest after every mix step for byte comparison with the oracle.
fn dumpTranscriptPrefix(allocator: std.mem.Allocator, path: []const u8) !void {
    const public_data_mod = @import("frontends/riscv/air/public_data.zig");
    const prover_mod = @import("frontends/riscv/prover.zig");
    const memory_boundary = @import("frontends/riscv/air/memory_commitment/boundary.zig");

    const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(elf_bytes);
    var run_result = try runner.run(allocator, elf_bytes, 10_000_000);
    defer run_result.deinit();

    const input_words = try public_data_mod.packInputWords(allocator, run_result.input);
    defer allocator.free(input_words);
    const out_words = try allocator.alloc(public_data_mod.OutputWord, run_result.output_words.len);
    defer allocator.free(out_words);
    for (run_result.output_words, 0..) |word, i| out_words[i] = .{
        .addr = word.addr,
        .value = word.value,
        .clock = word.clock,
    };
    var boundary_claims = try memory_boundary.build(allocator, run_result.rw_memory.words);
    defer boundary_claims.deinit(allocator);
    const data = public_data_mod.PublicData{
        .initial_pc = run_result.initial_pc,
        .final_pc = run_result.final_pc,
        .clock = @intCast(run_result.step_count),
        .initial_regs = run_result.initial_regs,
        .final_regs = run_result.final_regs,
        .reg_last_clock = run_result.state_chain_tracker.reg_last_clk,
        .program_root = try prover_mod.buildProgramSparseRoot(allocator, &run_result.rw_memory),
        .initial_rw_root = if (boundary_claims.initial_tree) |tree| tree.root else null,
        .final_rw_root = if (boundary_claims.final_tree) |tree| tree.root else null,
        .io_entries = .{
            .input_start = run_result.input_start,
            .input_len = @intCast(run_result.input.len),
            .input_words = input_words,
            .output_len = run_result.output_len,
            .output_len_addr = run_result.output_len_addr,
            .output_data_addr = run_result.output_data_addr,
            .output_words = out_words,
        },
    };

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    var recorder = DigestRecorder{ .allocator = allocator, .out = &out };
    {
        const writer = out.writer(allocator);
        try writer.print("init ", .{});
    }
    recorder.appendDigest();
    data.mixInto(&recorder);

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}
