//! Shared cost model for Metal-backed lifted Merkle commitments.
//!
//! STRICT Metal (default, the core_metal board's contract): every
//! non-empty commitment is resident; performance selection may not
//! silently move work to CPU. The explicitly hybrid lane (board
//! `core_hybrid` / lane `metal_hybrid`) OPTS IN at process start via
//! `STWO_ZIG_HYBRID_COMMIT_ROUTING=1`, which routes sub-threshold
//! commitments, quotients, and FRI folds through the CPU path with the
//! thresholds below. The strict product's behavior is bit-for-bit
//! unchanged when the variable is unset.

const std = @import("std");
const qm31 = @import("stwo_core").fields.qm31;

/// Strict-product values (upstream contract).
pub const merkle_cell_threshold: usize = 1;
pub const quotient_resident_merkle_log_threshold: u32 = 1;
pub const fri_fold_commit_log_threshold: u32 = 1;

/// Hybrid-lane values: below these, work routes to the CPU. Coherence
/// invariant (host evaluations must never reach resident-only dispatch):
/// hybrid_merkle_cell_threshold == 4 << hybrid_log_threshold-2 ... i.e.
/// 1<<15 cells == QM31's four planes at 1<<13 values.
pub const hybrid_merkle_cell_threshold: usize = 1 << 15;
pub const hybrid_log_threshold: u32 = 13;

const Mode = enum(u8) { unresolved, strict, hybrid };
var routing_mode = std.atomic.Value(u8).init(@intFromEnum(Mode.unresolved));

/// Process-constant after first read; benign race (all writers agree).
fn hybridRoutingEnabled() bool {
    switch (@as(Mode, @enumFromInt(routing_mode.load(.monotonic)))) {
        .strict => return false,
        .hybrid => return true,
        .unresolved => {
            const on = if (std.posix.getenv("STWO_ZIG_HYBRID_COMMIT_ROUTING")) |v|
                v.len > 0 and !std.mem.eql(u8, v, "0")
            else
                false;
            routing_mode.store(
                @intFromEnum(if (on) Mode.hybrid else Mode.strict),
                .monotonic,
            );
            return on;
        },
    }
}

/// Test hook: force a mode regardless of environment.
pub fn overrideRoutingForTest(hybrid: bool) void {
    routing_mode.store(
        @intFromEnum(if (hybrid) Mode.hybrid else Mode.strict),
        .monotonic,
    );
}

fn activeCellThreshold() usize {
    return if (hybridRoutingEnabled()) hybrid_merkle_cell_threshold else merkle_cell_threshold;
}

fn activeLogThreshold() u32 {
    return if (hybridRoutingEnabled()) hybrid_log_threshold else fri_fold_commit_log_threshold;
}

pub fn usesResidentMerkle(cell_count: usize) bool {
    return cell_count >= activeCellThreshold();
}

/// Whether a QM31 evaluation's four coordinate planes will use resident Merkle.
/// Overflow cannot describe a valid host allocation, so it stays on the resident
/// route and lets the commitment's checked size calculation report the error.
pub fn secureColumnUsesResidentMerkle(value_count: usize) bool {
    const cell_count = std.math.mul(
        usize,
        value_count,
        qm31.SECURE_EXTENSION_DEGREE,
    ) catch return true;
    return usesResidentMerkle(cell_count);
}

pub fn quotientUsesResidentMerkle(lifting_log_size: u32) bool {
    const threshold = if (hybridRoutingEnabled())
        hybrid_log_threshold
    else
        quotient_resident_merkle_log_threshold;
    return lifting_log_size >= threshold;
}

pub fn friFoldCommitUsesResidentMerkle(value_count: usize, fold_count: u32) bool {
    if (fold_count != 1 or value_count == 0 or !std.math.isPowerOfTwo(value_count)) return false;
    return std.math.log2_int(usize, value_count) >= activeLogThreshold();
}

test "commit policy: strict default admits every non-empty commitment" {
    overrideRoutingForTest(false);
    try std.testing.expect(usesResidentMerkle(1));
    try std.testing.expect(quotientUsesResidentMerkle(1));
    try std.testing.expect(friFoldCommitUsesResidentMerkle(2, 1));
}

test "commit policy: hybrid mode routes sub-threshold work to host" {
    overrideRoutingForTest(true);
    defer overrideRoutingForTest(false);
    try std.testing.expect(!usesResidentMerkle((1 << 15) - 1));
    try std.testing.expect(usesResidentMerkle(1 << 15));
    try std.testing.expect(!secureColumnUsesResidentMerkle((1 << 13) - 1));
    try std.testing.expect(secureColumnUsesResidentMerkle(1 << 13));
    try std.testing.expect(!quotientUsesResidentMerkle(12));
    try std.testing.expect(quotientUsesResidentMerkle(13));
    try std.testing.expect(!friFoldCommitUsesResidentMerkle(1 << 12, 1));
    try std.testing.expect(friFoldCommitUsesResidentMerkle(1 << 13, 1));
}
