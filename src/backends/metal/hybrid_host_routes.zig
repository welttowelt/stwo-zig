//! Host (CPU) delegation routes for the hybrid commit policy.
//!
//! These are reached only when `commit_policy` routes sub-threshold work
//! off-device (hybrid lane; the strict Metal product never takes them).
//! Every route calls the reference CPU implementation, so outputs are
//! bit-identical to the CPU backend's by construction; UMA memory keeps
//! host-written resident columns device-visible.

const std = @import("std");
const cpu = @import("../cpu_scalar/mod.zig").CpuBackend;
const metal_merkle = @import("merkle_tree.zig");
const telemetry = @import("telemetry.zig");

const line_mod = @import("stwo_prover_impl").line;
const core_fri = @import("stwo_core").fri;
const QM31 = @import("stwo_core").fields.qm31.QM31;
const M31 = @import("stwo_core").fields.m31.M31;
const CircleDomain = @import("stwo_core").poly.circle.domain.CircleDomain;

/// Fused quotient+Merkle pipeline on the CPU backend; the resident output
/// column is written directly through unified memory.
pub fn commitLazyMerkle(
    comptime H: type,
    allocator: std.mem.Allocator,
    provider: anytype,
    out: anytype,
) !metal_merkle.MetalMerkleTree(H) {
    const host_tree = try cpu.commitLazyMerkle(H, allocator, provider, out);
    telemetry.record(.host_merkle_commit);
    return metal_merkle.MetalMerkleTree(H).fromHost(host_tree);
}

/// Line fold on the CPU without consuming the input (the generic
/// scheduler deinits the source after this returns).
pub fn foldLineEvaluationN(
    allocator: std.mem.Allocator,
    evaluation: line_mod.LineEvaluation,
    alpha: QM31,
    workspace: *core_fri.FoldLineWorkspace,
    n_folds: u32,
) !line_mod.LineEvaluation {
    const scratch = try allocator.dupe(QM31, evaluation.values);
    const folded = core_fri.foldLineInPlaceNWithWorkspace(
        allocator,
        scratch,
        evaluation.domain(),
        alpha,
        workspace,
        n_folds,
    ) catch |err| {
        // Completed fold steps realloc (and free) the input slice, so on a
        // mid-fold error the survivor cannot be named here: do not free
        // `scratch` — a leaked slice on the OOM path beats a dangling free.
        return err;
    };
    return line_mod.LineEvaluation.initOwned(folded.domain, folded.values);
}

/// Circle→line fold via the reference CPU kernel.
pub fn foldCircleIntoLine(
    allocator: std.mem.Allocator,
    dst: []QM31,
    src_columns: [4][]const M31,
    src_domain: CircleDomain,
    alpha: QM31,
    workspace: *core_fri.FoldCircleWorkspace,
) !void {
    return core_fri.foldCircleColumnsIntoLineWithWorkspace(
        allocator,
        dst,
        src_columns,
        src_domain,
        alpha,
        workspace,
    );
}

const shared_runtime = @import("shared_runtime.zig");
const LineDomain = @import("stwo_core").poly.line.LineDomain;

/// Resident allocation used by the fused cascade internals, which require
/// device-handle storage regardless of size.
pub fn residentLineEvaluation(domain: LineDomain) !line_mod.LineEvaluation {
    var lease = try shared_runtime.acquire();
    defer lease.deinit();
    var buffer = try lease.runtime.allocateResidentBuffer(domain.size() * @sizeOf(QM31));
    errdefer buffer.deinit();
    const values: [*]QM31 = @ptrCast(@alignCast(buffer.contents));
    shared_runtime.retainResidentResource();
    errdefer shared_runtime.releaseResidentResource();
    return line_mod.LineEvaluation.initResident(
        domain,
        values[0..domain.size()],
        .{
            .handle = buffer.handle,
            .destroyFn = shared_runtime.destroyResidentBuffer,
        },
    );
}
