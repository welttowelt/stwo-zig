//! Merkle tree operation contracts for prover backends.
//!
//! A backend must provide hash-function-parameterized leaf and layer
//! construction for Merkle commitments.

/// Validates that backend `B` declares the required Merkle operations
/// for hash function `H`.
///
/// Required declarations:
///   - `commitOnLayer(comptime H: type, allocator, prev_layer, columns) ![]H.Hash`
pub fn assertMerkleOps(comptime B: type, comptime H: type) void {
    _ = H;
    comptime {
        if (!@hasDecl(B, "commitOnLayer")) {
            @compileError("Backend must declare `commitOnLayer`.");
        }
    }
}
