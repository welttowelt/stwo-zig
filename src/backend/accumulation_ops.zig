//! Constraint accumulation operation contracts for prover backends.
//!
//! A backend must provide domain-wide constraint evaluation accumulation.

/// Validates that backend `B` declares the required accumulation operations.
///
/// Required declarations:
///   - `accumulate(allocator, dst_column, src_column) !void`
pub fn assertAccumulationOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "accumulate")) {
            @compileError("Backend must declare `accumulate`.");
        }
    }
}
