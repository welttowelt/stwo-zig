//! Polynomial operation contracts for prover backends.
//!
//! A backend must provide FFT, inverse FFT, and polynomial evaluation
//! on its column type.

/// Validates that backend `B` declares the required polynomial operations.
///
/// Required declarations:
///   - `interpolate(allocator, values, twiddles) !CircleCoefficients(B)`
///   - `evaluateOnDomain(allocator, coeffs, domain, log_blowup) !CircleEvaluation(B)`
///   - `evalAtPoint(coeffs, point: CirclePointQM31) QM31`
pub fn assertPolyOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "interpolate")) {
            @compileError("Backend must declare `interpolate`.");
        }
        if (!@hasDecl(B, "evaluateOnDomain")) {
            @compileError("Backend must declare `evaluateOnDomain`.");
        }
        if (!@hasDecl(B, "evalAtPoint")) {
            @compileError("Backend must declare `evalAtPoint`.");
        }
    }
}
