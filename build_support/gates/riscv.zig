const std = @import("std");

pub const Context = struct {
    b: *std.Build,
    release_phase: []const u8,
    evidence_dir: []const u8,
};

pub fn addGates(context: Context) void {
    const b = context.b;
    const receipt = b.fmt("{s}/oracle-receipt.json", .{context.evidence_dir});

    // CP-13 remains independent of the ordinary release chains until RF-01.
    const contract = b.addSystemCommand(&.{
        "python3", "scripts/check_riscv_release_contract.py", "--all", "--phase", context.release_phase,
    });
    const vectors = b.addSystemCommand(&.{ "python3", "scripts/riscv_trace_vectors.py" });
    vectors.step.dependOn(&contract.step);
    const smoke = b.addSystemCommand(&.{
        "python3", "scripts/riscv_staged_smoke.py", "--phase", context.release_phase,
    });
    smoke.step.dependOn(&vectors.step);
    const evidence = b.addSystemCommand(&.{
        "python3", "scripts/riscv_release_evidence.py", "--receipt", receipt, "--candidate-head",
    });
    evidence.step.dependOn(&smoke.step);
    b.step(
        "riscv-release-gate",
        "Run the staged CLI and validate complete candidate-bound CP-11 evidence",
    ).dependOn(&evidence.step);
}
