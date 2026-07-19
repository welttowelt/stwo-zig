//! Shared pinned Stark-V shift equations.
//!
//! The hot-one markers and per-byte carries are protocol witnesses. They are
//! not interchangeable with a binary shift amount or a whole-word result.

const std = @import("std");
const QM31 = @import("stwo_core").fields.qm31.QM31;
const common = @import("common.zig");

pub const N_CONSTRAINTS: usize = 53;

pub const Row = struct {
    rd: common.Access,
    rs1: common.Access,
    rs1_sign: QM31,
    is_sll: QM31,
    is_srl: QM31,
    is_sra: QM31,
    bit_multiplier_left: QM31,
    bit_multiplier_right: QM31,
    bit_markers: [8]QM31,
    limb_markers: [4]QM31,
    carries: [4]QM31,

    pub fn active(self: Row) QM31 {
        return self.is_sll.add(self.is_srl).add(self.is_sra);
    }
};

pub const Derived = struct {
    right_shift: QM31,
    bit_multiplier: QM31,
    bit_shift: QM31,
    limb_shift: QM31,
    shift_amount: QM31,
    bit_marker_sum: QM31,
    limb_marker_sum: QM31,
};

pub fn derive(row: Row) Derived {
    var bit_multiplier = QM31.zero();
    var bit_shift = QM31.zero();
    var bit_marker_sum = QM31.zero();
    for (row.bit_markers, 0..) |marker, i| {
        bit_multiplier = bit_multiplier.add(marker.mul(common.q(@as(u64, 1) << @intCast(i))));
        bit_shift = bit_shift.add(marker.mul(common.q(i)));
        bit_marker_sum = bit_marker_sum.add(marker);
    }
    var limb_shift = QM31.zero();
    var limb_marker_sum = QM31.zero();
    for (row.limb_markers, 0..) |marker, i| {
        limb_shift = limb_shift.add(marker.mul(common.q(i)));
        limb_marker_sum = limb_marker_sum.add(marker);
    }
    return .{
        .right_shift = row.is_srl.add(row.is_sra),
        .bit_multiplier = bit_multiplier,
        .bit_shift = bit_shift,
        .limb_shift = limb_shift,
        .shift_amount = limb_shift.mul(common.q(8)).add(bit_shift),
        .bit_marker_sum = bit_marker_sum,
        .limb_marker_sum = limb_marker_sum,
    };
}

pub const Constraints = common.ConstraintSet(N_CONSTRAINTS);

/// Exact Section 3/4 shift constraints from the pinned schema. Immediate
/// shifts add `imm_truncated == shift_amount` in their family module.
pub fn evaluate(row: Row) Constraints {
    @setEvalBranchQuota(100_000);
    var out: [N_CONSTRAINTS]QM31 = undefined;
    var n: usize = 0;
    const d = derive(row);
    const enabler = row.active();

    out[n] = common.bit(enabler);
    n += 1;
    for ([_]QM31{ row.is_sll, row.is_srl, row.is_sra }) |flag| {
        out[n] = common.bit(flag);
        n += 1;
    }

    out[n] = common.bit(row.rs1_sign);
    n += 1;
    for (row.bit_markers) |marker| {
        out[n] = common.bit(marker);
        n += 1;
    }
    for (row.limb_markers) |marker| {
        out[n] = common.bit(marker);
        n += 1;
    }
    out[n] = d.bit_marker_sum.sub(enabler);
    n += 1;
    out[n] = d.limb_marker_sum.sub(enabler);
    n += 1;
    out[n] = row.bit_multiplier_left.sub(row.is_sll.mul(d.bit_multiplier));
    n += 1;
    out[n] = row.bit_multiplier_right.sub(d.right_shift.mul(d.bit_multiplier));
    n += 1;

    // Left shifts by 8*i+b, with byte carries flowing toward higher limbs.
    for (0..4) |i| {
        const marker = row.limb_markers[i];
        for (0..4) |j| {
            if (j < i) {
                out[n] = row.is_sll.mul(marker).mul(row.rd.next[j]);
            } else if (j == i) {
                out[n] = row.is_sll.mul(marker).mul(
                    row.rd.next[j].add(common.BYTE_RADIX.mul(row.carries[0])),
                ).sub(marker.mul(row.rs1.next[0]).mul(row.bit_multiplier_left));
            } else {
                const k = j - i;
                const carry_term = row.carries[k - 1].sub(common.BYTE_RADIX.mul(row.carries[k]));
                out[n] = row.is_sll.mul(marker).mul(row.rd.next[j].sub(carry_term))
                    .sub(marker.mul(row.rs1.next[k]).mul(row.bit_multiplier_left));
            }
            n += 1;
        }
    }

    // Right shifts by 8*i+b, with arithmetic sign fill where SRA is active.
    for (0..4) |i| {
        const marker = row.limb_markers[i];
        for (0..4) |j| {
            const input = i + j;
            if (input < 3) {
                out[n] = marker.mul(
                    row.carries[input + 1].mul(d.right_shift).mul(common.BYTE_RADIX)
                        .add(d.right_shift.mul(row.rs1.next[input].sub(row.carries[input])))
                        .sub(row.rd.next[j].mul(row.bit_multiplier_right)),
                );
            } else if (input == 3) {
                out[n] = marker.mul(
                    row.rs1_sign.mul(row.bit_multiplier_right.sub(QM31.one())).mul(common.BYTE_RADIX)
                        .add(d.right_shift.mul(row.rs1.next[3].sub(row.carries[3])))
                        .sub(row.rd.next[j].mul(row.bit_multiplier_right)),
                );
            } else {
                out[n] = d.right_shift.mul(marker).mul(
                    row.rd.next[j].sub(row.rs1_sign.mul(common.q(255))),
                );
            }
            n += 1;
        }
    }
    std.debug.assert(n == out.len);
    return .{ .values = out };
}

pub fn carryRangePairs(row: Row) [2][2]QM31 {
    const enabler = row.active();
    const upper = derive(row).bit_multiplier.sub(enabler);
    return .{
        .{ upper.sub(row.carries[0]), upper.sub(row.carries[1]) },
        .{ upper.sub(row.carries[2]), upper.sub(row.carries[3]) },
    };
}

pub fn rdRangePairs(row: Row) [2][2]QM31 {
    return .{
        .{ row.rd.next[0], row.rd.next[1] },
        .{ row.rd.next[2], row.rd.next[3] },
    };
}
