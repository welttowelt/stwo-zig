//! FRI (Fast Reed-Solomon IOP) operation contracts for prover backends.
//!
//! A backend must provide circle-to-line and line-to-line folding.

const line_evaluation = @import("line_evaluation.zig");
const secure_column = @import("secure_column.zig");

pub fn FoldLineAndCommitResult(comptime Tree: type) type {
    return struct {
        evaluation: line_evaluation.LineEvaluation,
        /// Coordinate planes already used for the pending tree. A scheduler
        /// that consumes the hook must move this into the next layer instead
        /// of materializing the evaluation a second time.
        column: ?secure_column.SecureColumnByCoords = null,
        tree: Tree,
    };
}

/// Validates that backend `B` declares the required FRI operations.
///
/// Required declarations:
///   - `foldCircleIntoLine(allocator, eval, alpha) !LineEvaluation(B)`
///   - `foldLine(allocator, eval, alpha) !LineEvaluation(B)`
///
/// Optional declarations:
///   - `secureColumnForMerkle(allocator, evaluation) !SecureColumnByCoords`
///   - `secureColumnFromLine(evaluation) !SecureColumnByCoords` (legacy fallback)
///   - `foldLineAndCommitNext(...) !FoldLineAndCommitResult(MerkleTree(H))`
pub fn assertFriOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "foldCircleIntoLine")) {
            @compileError("Backend must declare `foldCircleIntoLine`.");
        }
        if (!@hasDecl(B, "foldLine")) {
            @compileError("Backend must declare `foldLine`.");
        }
    }
}
