//! Constraint quotient operation contracts for prover backends.
//!
//! A backend must provide quotient polynomial accumulation over its domain.

/// Validates that backend `B` declares the required quotient operations.
///
/// Required declarations:
///   - `accumulateQuotients(allocator, domain, columns, random_coeff,
///      sample_batches, quotient_constants) !SecureColumnByCoords(B)`
pub fn assertQuotientOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "accumulateQuotients")) {
            @compileError("Backend must declare `accumulateQuotients`.");
        }
    }
}
