const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;

pub const STATE_WIDTH: usize = 16;
pub const N_FULL_ROUNDS_FIRST: usize = 4;
pub const N_PARTIAL_ROUNDS: usize = 14;
pub const N_FULL_ROUNDS_LAST: usize = 4;
pub const N_FULL_ROUNDS: usize = N_FULL_ROUNDS_FIRST + N_FULL_ROUNDS_LAST;

pub const State = [STATE_WIDTH]M31;

/// Apply the Poseidon2 permutation in-place.
pub fn permute(state: *State) void {
    // Initial linear layer
    externalLinearLayer(state);

    // First 4 full rounds
    for (0..N_FULL_ROUNDS_FIRST) |r| {
        addRoundConstants(state, FULL_ROUND_CONSTANTS[r]);
        sboxFull(state);
        externalLinearLayer(state);
    }

    // 14 partial rounds
    for (0..N_PARTIAL_ROUNDS) |r| {
        state[0] = state[0].add(PARTIAL_ROUND_CONSTANTS[r]);
        state[0] = sbox(state[0]);
        internalLinearLayer(state);
    }

    // Last 4 full rounds
    for (0..N_FULL_ROUNDS_LAST) |r| {
        addRoundConstants(state, FULL_ROUND_CONSTANTS[N_FULL_ROUNDS_FIRST + r]);
        sboxFull(state);
        externalLinearLayer(state);
    }
}

/// S-box: x^5 in M31.
inline fn sbox(x: M31) M31 {
    const x2 = x.square();
    const x4 = x2.square();
    return x4.mul(x);
}

/// Apply S-box to all state elements.
fn sboxFull(state: *State) void {
    for (state) |*x| x.* = sbox(x.*);
}

/// Add round constants to state.
fn addRoundConstants(state: *State, constants: [STATE_WIDTH]M31) void {
    for (state, constants) |*s, c| s.* = s.*.add(c);
}

/// External linear layer: MDS matrix for Poseidon2 (M31 version).
/// Uses the 4x4 circulant matrix structure extended to width 16.
fn externalLinearLayer(state: *State) void {
    // Split state into 4 groups of 4, apply 4x4 MDS to each,
    // then mix across groups.
    var groups: [4][4]M31 = undefined;
    for (0..4) |g| {
        for (0..4) |i| groups[g][i] = state[g * 4 + i];
    }

    // Apply 4x4 mixing within each group
    for (0..4) |g| {
        mds4x4(&groups[g]);
    }

    // Mix across groups: add sum of all groups to each element
    for (0..4) |i| {
        const sum = groups[0][i].add(groups[1][i]).add(groups[2][i]).add(groups[3][i]);
        for (0..4) |g| {
            state[g * 4 + i] = groups[g][i].add(sum);
        }
    }
}

/// 4x4 MDS mixing using circulant matrix circ(2, 3, 1, 1).
///
/// out[0] = 2*v[0] + 3*v[1] + v[2] + v[3]
/// out[1] = v[0] + 2*v[1] + 3*v[2] + v[3]
/// out[2] = v[0] + v[1] + 2*v[2] + 3*v[3]
/// out[3] = 3*v[0] + v[1] + v[2] + 2*v[3]
fn mds4x4(v: *[4]M31) void {
    const sum_all = v[0].add(v[1]).add(v[2]).add(v[3]);
    // circ(2,3,1,1) * v = (sum of all) + v[i] (for the +2 diagonal)
    //                    + 2*v[(i+1) mod 4] (for the +3 off-diagonal)
    // Since circ(2,3,1,1)[i][j] = 1 for all j, + 1 more for j==i, + 2 more for j==(i+1)%4
    const r0 = sum_all.add(v[0]).add(v[1]).add(v[1]);
    const r1 = sum_all.add(v[1]).add(v[2]).add(v[2]);
    const r2 = sum_all.add(v[2]).add(v[3]).add(v[3]);
    const r3 = sum_all.add(v[3]).add(v[0]).add(v[0]);
    v[0] = r0;
    v[1] = r1;
    v[2] = r2;
    v[3] = r3;
}

/// Internal linear layer (for partial rounds).
/// Applies a diagonal matrix + 1s everywhere (cheaper than full MDS).
fn internalLinearLayer(state: *State) void {
    // Sum all elements
    var sum = M31.zero();
    for (state) |s| sum = sum.add(s);

    // Each element: state[i] = state[i] * DIAG[i] + sum
    for (state, 0..) |*s, i| {
        s.* = s.*.mul(INTERNAL_DIAG[i]).add(sum);
    }
}

/// Hash two Poseidon2 digests (for Merkle tree).
/// Input: left (8 M31), right (8 M31). Output: 8 M31.
pub fn hashPair(left: [8]M31, right: [8]M31) [8]M31 {
    var state: State = [_]M31{M31.zero()} ** STATE_WIDTH;
    for (0..8) |i| state[i] = left[i];
    for (0..8) |i| state[8 + i] = right[i];
    permute(&state);
    var result: [8]M31 = undefined;
    @memcpy(&result, state[0..8]);
    return result;
}

// ---------------------------------------------------------------------------
// Round constants
// ---------------------------------------------------------------------------
//
// Deterministic placeholder constants generated via a simple LCG PRNG.
// The exact constants should be replaced with those from stark-v's
// constants.rs when available.

/// LCG step: advance seed and return a value in [0, Modulus).
fn lcgNext(seed: *u64) u32 {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    // Use bits [33..63] to get a ~31-bit value, then reduce mod p.
    const raw: u32 = @truncate(seed.* >> 33);
    return raw % (0x7fffffff); // ensure < Modulus
}

// Full round constants: 8 rounds x 16 elements
const FULL_ROUND_CONSTANTS: [N_FULL_ROUNDS][STATE_WIDTH]M31 = blk: {
    var constants: [N_FULL_ROUNDS][STATE_WIDTH]M31 = undefined;
    var seed: u64 = 0x506F736569646F6E; // "Poseidon" as u64
    for (0..N_FULL_ROUNDS) |r| {
        for (0..STATE_WIDTH) |i| {
            constants[r][i] = M31.fromCanonical(lcgNext(&seed));
        }
    }
    break :blk constants;
};

// Partial round constants: 14 elements
const PARTIAL_ROUND_CONSTANTS: [N_PARTIAL_ROUNDS]M31 = blk: {
    var constants: [N_PARTIAL_ROUNDS]M31 = undefined;
    var seed: u64 = 0x5061727469616C52; // "PartialR" as u64
    for (0..N_PARTIAL_ROUNDS) |i| {
        constants[i] = M31.fromCanonical(lcgNext(&seed));
    }
    break :blk constants;
};

// Internal diagonal for partial rounds
const INTERNAL_DIAG: [STATE_WIDTH]M31 = blk: {
    var diag: [STATE_WIDTH]M31 = undefined;
    var seed: u64 = 0x496E7465726E616C; // "Internal" as u64
    for (0..STATE_WIDTH) |i| {
        diag[i] = M31.fromCanonical(lcgNext(&seed));
    }
    break :blk diag;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "poseidon2: permutation is deterministic" {
    var state1: State = [_]M31{M31.zero()} ** STATE_WIDTH;
    var state2: State = [_]M31{M31.zero()} ** STATE_WIDTH;
    state1[0] = M31.fromCanonical(42);
    state2[0] = M31.fromCanonical(42);
    permute(&state1);
    permute(&state2);
    for (0..STATE_WIDTH) |i| {
        try std.testing.expect(state1[i].eql(state2[i]));
    }
}

test "poseidon2: non-zero output from zero input" {
    var state: State = [_]M31{M31.zero()} ** STATE_WIDTH;
    permute(&state);
    var any_nonzero = false;
    for (state) |s| if (!s.isZero()) {
        any_nonzero = true;
        break;
    };
    try std.testing.expect(any_nonzero);
}

test "poseidon2: hashPair produces 8 elements" {
    const left = [_]M31{M31.fromCanonical(1)} ** 8;
    const right = [_]M31{M31.fromCanonical(2)} ** 8;
    const result = hashPair(left, right);
    var any_nonzero = false;
    for (result) |r| if (!r.isZero()) {
        any_nonzero = true;
        break;
    };
    try std.testing.expect(any_nonzero);
}

test "poseidon2: sbox is x^5" {
    const x = M31.fromCanonical(7);
    const expected = x.mul(x).mul(x).mul(x).mul(x); // 7^5 = 16807
    try std.testing.expect(sbox(x).eql(expected));
}

test "poseidon2: mds4x4 circulant correctness" {
    // Test that mds4x4 implements circ(2,3,1,1) correctly.
    var v = [4]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(2),
        M31.fromCanonical(3),
        M31.fromCanonical(4),
    };
    mds4x4(&v);
    // Expected: circ(2,3,1,1) * [1,2,3,4]
    // out[0] = 2*1 + 3*2 + 1*3 + 1*4 = 2+6+3+4 = 15
    // out[1] = 1*1 + 2*2 + 3*3 + 1*4 = 1+4+9+4 = 18
    // out[2] = 1*1 + 1*2 + 2*3 + 3*4 = 1+2+6+12 = 21
    // out[3] = 3*1 + 1*2 + 1*3 + 2*4 = 3+2+3+8 = 16
    try std.testing.expect(v[0].eql(M31.fromCanonical(15)));
    try std.testing.expect(v[1].eql(M31.fromCanonical(18)));
    try std.testing.expect(v[2].eql(M31.fromCanonical(21)));
    try std.testing.expect(v[3].eql(M31.fromCanonical(16)));
}
