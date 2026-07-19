//! Minimal pinned Stark-V Poseidon2-M31 permutation for sparse memory roots.
//!
//! Memory commitment nodes hash two scalar children in lanes 0 and 1 and use
//! output lane 0. This deliberately excludes trace generation; the Poseidon2
//! AIR component must separately consume the same `(input, output)` calls.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const constants = @import("poseidon2_constants.zig");

pub const WIDTH: usize = 16;
pub const State = [WIDTH]M31;
pub const DEFAULT_HASHES = constants.DEFAULT_HASHES;

pub fn hashPair(left: u32, right: u32) u32 {
    var state: State = .{M31.zero()} ** WIDTH;
    state[0] = M31.fromU64(left);
    state[1] = M31.fromU64(right);
    permute(&state);
    return state[0].v;
}

pub fn permute(state: *State) void {
    externalMatrix(state);
    for (constants.EXTERNAL_ROUND[0..4]) |round| fullRound(state, round);
    for (constants.INTERNAL_ROUND) |round_constant| {
        state[0] = sbox(state[0].add(M31.fromCanonical(round_constant)));
        internalMatrix(state);
    }
    for (constants.EXTERNAL_ROUND[4..8]) |round| fullRound(state, round);
}

fn fullRound(state: *State, round: [WIDTH]u32) void {
    for (state, round) |*value, constant| {
        value.* = sbox(value.add(M31.fromCanonical(constant)));
    }
    externalMatrix(state);
}

inline fn sbox(value: M31) M31 {
    return value.square().square().mul(value);
}

fn externalMatrix(state: *State) void {
    for (0..4) |block| {
        const base = 4 * block;
        const output = m4(state[base..][0..4].*);
        @memcpy(state[base..][0..4], &output);
    }

    for (0..4) |lane| {
        const sum = state[lane]
            .add(state[lane + 4])
            .add(state[lane + 8])
            .add(state[lane + 12]);
        for (0..4) |block| {
            const index = 4 * block + lane;
            state[index] = state[index].add(sum);
        }
    }
}

fn m4(input: [4]M31) [4]M31 {
    const t0 = input[0].add(input[1]);
    const t1 = input[2].add(input[3]);
    const t2 = input[1].add(input[1]).add(t1);
    const t3 = input[3].add(input[3]).add(t0);
    const t4 = t1.add(t1).add(t1.add(t1)).add(t3);
    const t5 = t0.add(t0).add(t0.add(t0)).add(t2);
    return .{ t3.add(t5), t5, t2.add(t4), t4 };
}

fn internalMatrix(state: *State) void {
    var sum = M31.zero();
    for (state) |value| sum = sum.add(value);
    for (state, constants.INTERNAL_MATRIX) |*value, diagonal| {
        value.* = value.mul(M31.fromCanonical(diagonal)).add(sum);
    }
}

test "memory Poseidon2: pinned default hash chain" {
    var expected = [_]u32{0} ** constants.DEFAULT_HASHES.len;
    var depth: usize = expected.len - 1;
    while (depth > 0) {
        depth -= 1;
        expected[depth] = hashPair(expected[depth + 1], expected[depth + 1]);
    }
    try std.testing.expectEqualSlices(u32, &constants.DEFAULT_HASHES, &expected);
}

test "memory Poseidon2: scalar pair vector is stable" {
    try std.testing.expectEqual(@as(u32, 1975699496), hashPair(1, 2));
}
