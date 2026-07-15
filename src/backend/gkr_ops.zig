//! GKR (Goldwasser-Kalai-Rothblum) operation contracts for prover backends.
//!
//! A backend must provide GKR circuit proving on its column type.

/// Validates that backend `B` declares the required GKR operations.
///
/// Required declarations:
///   - `genEqEvals(allocator, y) !Mle(B, QM31)`
///   - `nextLayer(allocator, layer) !Layer`
///   - `sumAsPolyInFirstVariable(allocator, claim) !UnivariatePoly(QM31)`
pub fn assertGkrOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "genEqEvals")) {
            @compileError("Backend must declare `genEqEvals`.");
        }
        if (!@hasDecl(B, "nextLayer")) {
            @compileError("Backend must declare `nextLayer`.");
        }
        if (!@hasDecl(B, "sumAsPolyInFirstVariable")) {
            @compileError("Backend must declare `sumAsPolyInFirstVariable`.");
        }
    }
}
