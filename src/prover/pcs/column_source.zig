//! Explicit structural producers for owned commitment columns.
//!
//! A deferred source is part of the ownership transaction: backends may
//! consume it in a combined device epoch, or materialize it before entering a
//! generic commitment path. It never relies on workload names or global
//! address discovery.

pub const QuadraticRecurrence = struct {
    log_n_rows: u32,
    recipe: [7]u32,
};

pub const ColumnSource = union(enum) {
    materialized,
    quadratic_recurrence: QuadraticRecurrence,

    pub fn isMaterialized(self: ColumnSource) bool {
        return self == .materialized;
    }
};

test "column source defaults to explicit materialized state" {
    const source: ColumnSource = .materialized;
    try @import("std").testing.expect(source.isMaterialized());
}
