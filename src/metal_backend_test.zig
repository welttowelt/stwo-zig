const std = @import("std");
const metal = @import("backends/metal/runtime.zig");
const m31 = @import("core/fields/m31.zig");
const blake2_merkle = @import("core/vcs_lifted/blake2_merkle.zig");
const merkle_prover = @import("prover/vcs_lifted/prover.zig");
const riscv_prover = @import("frontends/riscv/prover.zig");
const trace_mod = @import("frontends/riscv/runner/trace.zig");
const pcs_core = @import("core/pcs/mod.zig");
const MetalProverEngine = @import("backends/metal/prover_engine.zig").MetalProverEngine;
const canonic = @import("core/poly/circle/canonic.zig");
const circle_poly = @import("prover/poly/circle/poly.zig");
const twiddles = @import("prover/poly/twiddles.zig");

const M31 = m31.M31;
const Hasher = blake2_merkle.Blake2sMerkleHasher;

test "metal: batched circle IFFT and RFFT match CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();

    for ([_]u32{ 3, 8, 12 }) |log_size| {
        const domain = canonic.CanonicCoset.new(log_size).circleDomain();
        var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
        defer twiddles.deinitM31(allocator, &tree);

        var cpu: [3][]M31 = undefined;
        var gpu: [3][]M31 = undefined;
        defer for (&cpu) |column| allocator.free(column);
        defer for (&gpu) |column| allocator.free(column);
        for (0..cpu.len) |column_index| {
            cpu[column_index] = try allocator.alloc(M31, domain.size());
            gpu[column_index] = try allocator.alloc(M31, domain.size());
            for (cpu[column_index], 0..) |*value, row| {
                value.* = M31.fromCanonical(@intCast((column_index * 3571 + row * 7919 + 23) % m31.Modulus));
            }
            @memcpy(gpu[column_index], cpu[column_index]);
        }

        const const_tree = twiddles.TwiddleTree([]const M31).init(tree.root_coset, tree.twiddles, tree.itwiddles);
        try circle_poly.interpolateBuffersWithTwiddles(&cpu, domain, const_tree);
        _ = try runtime.transformCircle(allocator, &gpu, tree.itwiddles, log_size, true);
        for (cpu, gpu) |cpu_column, gpu_column| {
            try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
        }

        try circle_poly.evaluateBuffersWithTwiddles(&cpu, domain, const_tree);
        _ = try runtime.transformCircle(allocator, &gpu, tree.twiddles, log_size, false);
        for (cpu, gpu) |cpu_column, gpu_column| {
            try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
        }
    }
}

test "metal: fused circle LDE matches CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();

    const base_log_size: u32 = 12;
    const extended_log_size: u32 = 13;
    const base_domain = canonic.CanonicCoset.new(base_log_size).circleDomain();
    const extended_domain = canonic.CanonicCoset.new(extended_log_size).circleDomain();
    var base_tree = try twiddles.precomputeM31(allocator, base_domain.half_coset);
    defer twiddles.deinitM31(allocator, &base_tree);
    var extended_tree = try twiddles.precomputeM31(allocator, extended_domain.half_coset);
    defer twiddles.deinitM31(allocator, &extended_tree);

    var cpu_base: [3][]M31 = undefined;
    var cpu_extended: [3][]M31 = undefined;
    var gpu_base: [3][]M31 = undefined;
    var gpu_extended: [3][]M31 = undefined;
    defer for (&cpu_base) |column| allocator.free(column);
    defer for (&cpu_extended) |column| allocator.free(column);
    defer for (&gpu_base) |column| allocator.free(column);
    defer for (&gpu_extended) |column| allocator.free(column);
    for (0..cpu_base.len) |column_index| {
        cpu_base[column_index] = try allocator.alloc(M31, base_domain.size());
        cpu_extended[column_index] = try allocator.alloc(M31, extended_domain.size());
        gpu_base[column_index] = try allocator.alloc(M31, base_domain.size());
        gpu_extended[column_index] = try allocator.alloc(M31, extended_domain.size());
        for (cpu_base[column_index], 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 65537 + row * 8191 + 31) % m31.Modulus));
        }
        @memcpy(gpu_base[column_index], cpu_base[column_index]);
    }

    const base_const_tree = twiddles.TwiddleTree([]const M31).init(base_tree.root_coset, base_tree.twiddles, base_tree.itwiddles);
    const extended_const_tree = twiddles.TwiddleTree([]const M31).init(extended_tree.root_coset, extended_tree.twiddles, extended_tree.itwiddles);
    try circle_poly.interpolateBuffersWithTwiddles(&cpu_base, base_domain, base_const_tree);
    for (cpu_base, cpu_extended) |base, extended| {
        @memcpy(extended[0..base.len], base);
        @memset(extended[base.len..], M31.zero());
    }
    try circle_poly.evaluateBuffersWithTwiddles(&cpu_extended, extended_domain, extended_const_tree);

    _ = try runtime.transformCircleLde(
        allocator,
        &gpu_base,
        &gpu_base,
        &gpu_extended,
        base_tree.itwiddles,
        extended_tree.twiddles,
        base_log_size,
        extended_log_size,
    );
    for (cpu_base, gpu_base) |cpu_column, gpu_column| try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
    for (cpu_extended, gpu_extended) |cpu_column, gpu_column| try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
}

test "metal: resident lifted Merkle root matches CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();

    const log_sizes = [_]u32{ 10, 9, 10, 8, 9, 10, 7, 10, 8, 10, 9, 10, 6, 10, 9, 10, 8 };
    var owned: [log_sizes.len][]M31 = undefined;
    var initialized: usize = 0;
    defer {
        for (owned[0..initialized]) |column| allocator.free(column);
    }
    var cpu_columns: [log_sizes.len][]const M31 = undefined;
    var gpu_columns: [log_sizes.len][]const u32 = undefined;
    for (log_sizes, 0..) |log_size, column_index| {
        const column = try allocator.alloc(M31, @as(usize, 1) << @intCast(log_size));
        owned[column_index] = column;
        initialized += 1;
        for (column, 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 7919 + row * 104729 + 17) % m31.Modulus));
        }
        cpu_columns[column_index] = column;
        gpu_columns[column_index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column));
    }

    const CpuTree = merkle_prover.MerkleProverLifted(Hasher);
    var cpu_tree = try CpuTree.commit(allocator, &cpu_columns);
    defer cpu_tree.deinit(allocator);

    var gpu_tree = try runtime.commitColumns(
        allocator,
        &gpu_columns,
        &log_sizes,
        10,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
    );
    defer gpu_tree.deinit();
    const result = try gpu_tree.root();

    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &result.hash);
    try std.testing.expect(result.gpu_ms > 0);

    var compatible_tree = try CpuTree.commitMetal(&runtime, allocator, &cpu_columns);
    defer compatible_tree.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &compatible_tree.root());
}

test "metal: transaction engine proves and CPU verifier accepts" {
    const allocator = std.testing.allocator;
    var trace = trace_mod.Trace.init(allocator);
    defer trace.deinit();
    trace.initial_pc = 0x1000;
    for (0..8) |row| {
        try trace.append(.{
            .clk = @intCast(row),
            .pc = @intCast(0x1000 + row * 4),
            .opcode = .ADDI,
            .rd = 1,
            .rs1 = 0,
            .rs2 = 0,
            .imm = 1,
            .rs1_val = 0,
            .rs2_val = 0,
            .rd_val = @intCast(row + 1),
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1000 + (row + 1) * 4),
        });
    }
    trace.final_pc = 0x1020;
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };
    const output = try riscv_prover.proveRiscVWithEngine(
        MetalProverEngine,
        allocator,
        config,
        &trace,
        null,
        null,
    );
    try riscv_prover.verifyRiscV(allocator, config, output.statement, output.proof);
}
