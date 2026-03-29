//! Field operation contracts for prover backends.
//!
//! A backend must provide batch field arithmetic on its column type.

/// Validates that backend `B` declares the required field operations.
///
/// Required declarations:
///   - `batchInverse(allocator, col) !Column(F)` — Montgomery batch inverse
pub fn assertFieldOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "batchInverse")) {
            @compileError("Backend must declare `batchInverse`.");
        }
    }
}
