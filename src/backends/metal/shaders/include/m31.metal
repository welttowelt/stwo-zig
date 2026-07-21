#ifndef STWO_ZIG_M31_METAL
#define STWO_ZIG_M31_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

inline uint m31_reduce(ulong value) {
    ulong reduced = (value & 0x7ffffffful) + (value >> 31u);
    reduced = (reduced & 0x7ffffffful) + (reduced >> 31u);
    uint result = (uint)reduced;
    return result >= 0x7fffffffu ? result - 0x7fffffffu : result;
}

// Canonical operands sum to less than 2p, so addition needs no 64-bit fold.
inline uint m31_add(uint lhs, uint rhs) {
    uint sum = lhs + rhs;
    return sum >= 0x7fffffffu ? sum - 0x7fffffffu : sum;
}
inline uint m31_sub(uint lhs, uint rhs) { return lhs >= rhs ? lhs - rhs : lhs + 0x7fffffffu - rhs; }
// A product of canonical operands is below p^2. One Mersenne fold is then
// below 2p, and one conditional subtraction produces the canonical residue.
inline uint m31_mul(uint lhs, uint rhs) {
    ulong product = (ulong)lhs * rhs;
    ulong folded = (product & 0x7ffffffful) + (product >> 31u);
    uint result = (uint)folded;
    return result >= 0x7fffffffu ? result - 0x7fffffffu : result;
}
inline uint m31_neg(uint value) { return value == 0u ? 0u : 0x7fffffffu - value; }

inline uint m31_inv(uint value) {
    uint base = value;
    uint result = 1u;
    uint exponent = 0x7ffffffdu;
    while (exponent != 0u) {
        if ((exponent & 1u) != 0u) result = m31_mul(result, base);
        base = m31_mul(base, base);
        exponent >>= 1u;
    }
    return result;
}

#endif
