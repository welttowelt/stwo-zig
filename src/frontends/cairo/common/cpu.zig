//! Cairo CPU state types.

const M31 = @import("../../../core/fields/m31.zig").M31;

/// Log2 of the memory address bound (addresses fit in 29 bits).
pub const LOG_MEMORY_ADDRESS_BOUND: u32 = 29;

/// Maximum memory address.
pub const MEMORY_ADDRESS_BOUND: usize = 1 << LOG_MEMORY_ADDRESS_BOUND;

/// Cairo Assembly (CASM) CPU state: program counter, allocation pointer, frame pointer.
///
/// All registers are M31 values since addresses are bounded to 29 bits.
pub const CasmState = struct {
    pc: M31,
    ap: M31,
    fp: M31,

    pub fn values(self: CasmState) [3]M31 {
        return .{ self.pc, self.ap, self.fp };
    }

    pub fn eql(a: CasmState, b: CasmState) bool {
        return a.pc.eql(b.pc) and a.ap.eql(b.ap) and a.fp.eql(b.fp);
    }
};
