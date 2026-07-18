//! Width declarations for M-extension layouts pending production AIR placement.

fn OpaqueColumns(comptime n: usize) type {
    return struct {
        pub const N_COLUMNS: usize = n;
    };
}

pub const MulColumns = OpaqueColumns(33);
pub const MulhColumns = OpaqueColumns(41);
pub const DivColumns = OpaqueColumns(65);
