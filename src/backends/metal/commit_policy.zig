//! Shared cost model for Metal-backed lifted Merkle commitments.

const std = @import("std");
const qm31 = @import("../../core/fields/qm31.zig");

/// Commitments below this aggregate M31 cell count use the CPU implementation.
pub const merkle_cell_threshold: usize = 1 << 24;

/// First-FRI quotient trees pay one resident decommit readback later in the
/// proof. Production A/B places their complete-proof crossover at lifting log
/// 13; smaller quotient trees retain the CPU commitment path.
pub const quotient_resident_merkle_log_threshold: u32 = 13;

/// PR #6 begins Metal folds at log 16. Local complete-proof A/B keeps the
/// combined fold-plus-tree transaction conservative at log 18.
pub const fri_fold_commit_log_threshold: u32 = 18;

pub fn usesResidentMerkle(cell_count: usize) bool {
    return cell_count >= merkle_cell_threshold;
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
    return lifting_log_size >= quotient_resident_merkle_log_threshold;
}

pub fn friFoldCommitUsesResidentMerkle(value_count: usize, fold_count: u32) bool {
    if (fold_count != 1 or value_count == 0 or !std.math.isPowerOfTwo(value_count)) return false;
    return std.math.log2_int(usize, value_count) >= fri_fold_commit_log_threshold;
}
