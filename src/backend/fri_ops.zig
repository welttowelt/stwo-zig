//! FRI (Fast Reed-Solomon IOP) operation contracts for prover backends.
//!
//! A backend must provide circle-to-line and line-to-line folding.

/// Validates that backend `B` declares the required FRI operations.
///
/// Required declarations:
///   - `foldCircleIntoLine(allocator, eval, alpha) !LineEvaluation(B)`
///   - `foldLine(allocator, eval, alpha) !LineEvaluation(B)`
///
/// Optional declarations:
///   - `secureColumnForMerkle(allocator, evaluation) !SecureColumnByCoords`
///   - `secureColumnFromLine(evaluation) !SecureColumnByCoords` (legacy fallback)
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
