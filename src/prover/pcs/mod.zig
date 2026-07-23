//! Public map for prover-side polynomial commitment scheme facilities.

const scheme = @import("scheme.zig");

pub const quotient_ops = scheme.quotient_ops;
pub const CommitmentSchemeError = scheme.CommitmentSchemeError;
pub const ColumnEvaluation = scheme.ColumnEvaluation;
pub const ColumnSource = @import("column_source.zig").ColumnSource;

pub fn CommitmentTreeProver(comptime H: type) type {
    return scheme.CommitmentTreeProver(H);
}

pub fn TreeDecommitmentResult(comptime H: type) type {
    return scheme.TreeDecommitmentResult(H);
}

pub fn CommitmentSchemeProver(comptime B: type, comptime H: type, comptime MC: type) type {
    return scheme.CommitmentSchemeProver(B, H, MC);
}

pub fn TreeBuilder(comptime B: type, comptime H: type, comptime MC: type) type {
    return scheme.TreeBuilder(B, H, MC);
}

pub fn StreamingTreeBuilder(comptime B: type, comptime H: type, comptime MC: type) type {
    return scheme.StreamingTreeBuilder(B, H, MC);
}
