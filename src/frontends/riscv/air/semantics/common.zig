//! Shared scalar building blocks for RISC-V opcode semantics.
//!
//! The component evaluator works over `QM31` at both the out-of-domain point
//! and the lifted evaluation domain. Keeping these functions scalar makes the
//! same formulas usable in both paths without an expression-tree adapter.

const M31 = @import("../../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../../core/fields/qm31.zig").QM31;

pub const BYTE_RADIX = q(1 << 8);
pub const WORD_RADIX = q(@as(u64, 1) << 32);
pub const INV_BYTE_RADIX = QM31.fromBase(M31.fromCanonical(1 << 8).invUncheckedNonZero());

pub fn ConstraintSet(comptime n: usize) type {
    return struct {
        values: [n]QM31,

        pub fn allZero(self: @This()) bool {
            for (self.values) |value| {
                if (!value.isZero()) return false;
            }
            return true;
        }
    };
}

/// Canonical Stark-V program relation tuple.
///
/// This decoded tuple is deliberately distinct from the current Zig raw-word
/// program bus. A lookup against a ROM table built by decoding the ELF is the
/// sound way to bind opcode flags and operands to the fetched instruction.
pub const ProgramTuple = struct {
    pc: QM31,
    opcode_id: QM31,
    rd: QM31,
    rs1: QM31,
    operand: QM31,

    pub fn values(self: @This()) [5]QM31 {
        return .{ self.pc, self.opcode_id, self.rd, self.rs1, self.operand };
    }
};

/// One `(lhs byte, rhs byte, result byte, operation id)` lookup request.
pub const BitwiseTuple = struct {
    lhs: QM31,
    rhs: QM31,
    result: QM31,
    operation_id: QM31,

    pub fn values(self: @This()) [4]QM31 {
        return .{ self.lhs, self.rhs, self.result, self.operation_id };
    }
};

/// One committed register or memory access block.
pub const Access = struct {
    addr: QM31,
    previous: [4]QM31,
    previous_clock: QM31,
    next: [4]QM31,
};

/// Canonical Stark-V `memory_access` relation tuple.
pub const MemoryAccessTuple = struct {
    addr_space: QM31,
    addr: QM31,
    clock: QM31,
    limbs: [4]QM31,

    pub fn values(self: @This()) [7]QM31 {
        return .{
            self.addr_space,
            self.addr,
            self.clock,
            self.limbs[0],
            self.limbs[1],
            self.limbs[2],
            self.limbs[3],
        };
    }
};

/// The two sides of one access-chain transition. The caller consumes
/// `previous` with a negative numerator and emits `next` with a positive
/// numerator, both gated by the component enabler. `clock_gap` is a sibling
/// `range_check_20` request.
pub const AccessChain = struct {
    previous: MemoryAccessTuple,
    next: MemoryAccessTuple,
    clock_gap: QM31,
};

pub fn registerAccessChain(access: Access, row_clock: QM31) AccessChain {
    return .{
        .previous = .{
            .addr_space = QM31.zero(),
            .addr = access.addr,
            .clock = access.previous_clock,
            .limbs = access.previous,
        },
        .next = .{
            .addr_space = QM31.zero(),
            .addr = access.addr,
            .clock = row_clock,
            .limbs = access.next,
        },
        .clock_gap = row_clock.sub(access.previous_clock),
    };
}

pub inline fn q(value: u64) QM31 {
    return QM31.fromBase(M31.fromU64(value));
}

pub inline fn bit(value: QM31) QM31 {
    return value.mul(value.sub(QM31.one()));
}

pub inline fn selected(selector: QM31, value: QM31) QM31 {
    return selector.mul(value);
}

pub fn composeU32(limbs: [4]QM31) QM31 {
    var value = limbs[3];
    value = value.mul(BYTE_RADIX).add(limbs[2]);
    value = value.mul(BYTE_RADIX).add(limbs[1]);
    return value.mul(BYTE_RADIX).add(limbs[0]);
}

/// Constrain a derived base-256 carry to be a bit when `selector == 1`.
/// Byte-range lookups for every input and output limb are a required sibling
/// constraint; without them, a field element is not necessarily a byte.
pub inline fn selectedCarryBit(selector: QM31, numerator: QM31) QM31 {
    const carry = numerator.mul(INV_BYTE_RADIX);
    return selected(selector, bit(carry));
}

test "semantics common: compose little-endian word" {
    const std = @import("std");
    const actual = composeU32(.{ q(0x78), q(0x56), q(0x34), q(0x12) });
    try std.testing.expect(actual.eql(q(0x12345678)));
}
