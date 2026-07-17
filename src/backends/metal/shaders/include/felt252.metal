#ifndef STWO_ZIG_FELT252_METAL
#define STWO_ZIG_FELT252_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif
struct Felt252Metal { ushort limbs[16]; };

constant ushort felt_p[16] = {
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0, 0, 0x0800
};
constant ushort felt_r2[16] = {
    0x0401, 0x7e00, 0xfd73, 0xffff, 0xffff, 0x330f, 0x0001, 0x0000,
    0x8000, 0xff6f, 0xffff, 0xffff, 0x8810, 0x5e00, 0xd4ab, 0x07ff
};
constant ushort felt_one_mont[16] = {
    0xffe1, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
    0xffff, 0xffff, 0xffff, 0xffff, 0xfdf0, 0xffff, 0xffff, 0x07ff
};

inline Felt252Metal felt_zero() {
    Felt252Metal result;
    for (uint i = 0; i < 16u; ++i) result.limbs[i] = 0;
    return result;
}
inline Felt252Metal felt_one_standard() {
    Felt252Metal result = felt_zero(); result.limbs[0] = 1; return result;
}
inline Felt252Metal felt_one_montgomery() {
    Felt252Metal result;
    for (uint i = 0; i < 16u; ++i) result.limbs[i] = felt_one_mont[i];
    return result;
}
inline bool felt_ge_p(thread const Felt252Metal &value) {
    for (int i = 15; i >= 0; --i) {
        if (value.limbs[i] != felt_p[i]) return value.limbs[i] > felt_p[i];
    }
    return true;
}
inline Felt252Metal felt_sub_p(Felt252Metal value) {
    int borrow = 0;
    for (uint i = 0; i < 16u; ++i) {
        int next = int(value.limbs[i]) - int(felt_p[i]) - borrow;
        value.limbs[i] = ushort(uint(next) & 0xffffu);
        borrow = next < 0;
    }
    return value;
}
inline Felt252Metal felt_mont_mul(thread const Felt252Metal &a, thread const Felt252Metal &b) {
    uint t[33];
    for (uint i = 0; i < 33u; ++i) t[i] = 0u;
    for (uint i = 0; i < 16u; ++i) {
        ulong carry = 0u;
        for (uint j = 0; j < 16u; ++j) {
            ulong z = ulong(t[i + j]) + ulong(a.limbs[i]) * ulong(b.limbs[j]) + carry;
            t[i + j] = uint(z) & 0xffffu; carry = z >> 16u;
        }
        uint k = i + 16u;
        while (carry != 0u) {
            ulong z = ulong(t[k]) + carry; t[k] = uint(z) & 0xffffu; carry = z >> 16u; ++k;
        }
    }
    for (uint i = 0; i < 16u; ++i) {
        uint m = (t[i] * 0xffffu) & 0xffffu;
        ulong carry = 0u;
        for (uint j = 0; j < 16u; ++j) {
            ulong z = ulong(t[i + j]) + ulong(m) * ulong(felt_p[j]) + carry;
            t[i + j] = uint(z) & 0xffffu; carry = z >> 16u;
        }
        uint k = i + 16u;
        while (carry != 0u) {
            ulong z = ulong(t[k]) + carry; t[k] = uint(z) & 0xffffu; carry = z >> 16u; ++k;
        }
    }
    Felt252Metal result;
    for (uint i = 0; i < 16u; ++i) result.limbs[i] = ushort(t[i + 16u]);
    if (t[32] != 0u || felt_ge_p(result)) result = felt_sub_p(result);
    return result;
}
inline Felt252Metal felt_mont_square(thread const Felt252Metal &value) {
    uint t[33];
    for (uint i = 0u; i < 33u; ++i) t[i] = 0u;
    ulong carry = 0u;
    for (uint diagonal = 0u; diagonal < 31u; ++diagonal) {
        ulong coefficient = carry;
        uint first = diagonal > 15u ? diagonal - 15u : 0u;
        uint last = min(diagonal, 15u);
        for (uint i = first; i <= last; ++i) {
            uint j = diagonal - i;
            if (i > j) break;
            ulong product = ulong(value.limbs[i]) * ulong(value.limbs[j]);
            coefficient += i == j ? product : product + product;
        }
        t[diagonal] = uint(coefficient) & 0xffffu;
        carry = coefficient >> 16u;
    }
    t[31] = uint(carry) & 0xffffu;
    t[32] = uint(carry >> 16u);
    for (uint i = 0u; i < 16u; ++i) {
        uint m = (t[i] * 0xffffu) & 0xffffu;
        ulong reduction_carry = 0u;
        for (uint j = 0u; j < 16u; ++j) {
            ulong z = ulong(t[i + j]) + ulong(m) * ulong(felt_p[j]) + reduction_carry;
            t[i + j] = uint(z) & 0xffffu; reduction_carry = z >> 16u;
        }
        uint k = i + 16u;
        while (reduction_carry != 0u) {
            ulong z = ulong(t[k]) + reduction_carry;
            t[k] = uint(z) & 0xffffu; reduction_carry = z >> 16u; ++k;
        }
    }
    Felt252Metal result;
    for (uint i = 0u; i < 16u; ++i) result.limbs[i] = ushort(t[i + 16u]);
    if (t[32] != 0u || felt_ge_p(result)) result = felt_sub_p(result);
    return result;
}
inline Felt252Metal felt_add_252(thread const Felt252Metal &a, thread const Felt252Metal &b) {
    Felt252Metal result; uint carry = 0u;
    for (uint i = 0; i < 16u; ++i) {
        uint z = uint(a.limbs[i]) + uint(b.limbs[i]) + carry;
        result.limbs[i] = ushort(z & 0xffffu); carry = z >> 16u;
    }
    if (carry != 0u || felt_ge_p(result)) result = felt_sub_p(result);
    return result;
}
inline Felt252Metal felt_sub_252(thread const Felt252Metal &a, thread const Felt252Metal &b) {
    Felt252Metal result; int borrow = 0;
    for (uint i = 0; i < 16u; ++i) {
        int z = int(a.limbs[i]) - int(b.limbs[i]) - borrow;
        result.limbs[i] = ushort(uint(z) & 0xffffu); borrow = z < 0;
    }
    if (borrow != 0) {
        uint carry = 0u;
        for (uint i = 0; i < 16u; ++i) {
            uint z = uint(result.limbs[i]) + uint(felt_p[i]) + carry;
            result.limbs[i] = ushort(z & 0xffffu); carry = z >> 16u;
        }
    }
    return result;
}
inline bool felt_equal_252(thread const Felt252Metal &a, thread const Felt252Metal &b) {
    ushort different = 0;
    for (uint i = 0; i < 16u; ++i) different |= a.limbs[i] ^ b.limbs[i];
    return different == 0;
}
inline Felt252Metal felt_to_montgomery(thread const Felt252Metal &value) {
    Felt252Metal r2; for (uint i = 0; i < 16u; ++i) r2.limbs[i] = felt_r2[i];
    return felt_mont_mul(value, r2);
}
inline Felt252Metal felt_from_montgomery(thread const Felt252Metal &value) {
    Felt252Metal one = felt_one_standard(); return felt_mont_mul(value, one);
}
inline Felt252Metal felt_inverse_252(thread const Felt252Metal &value) {
    Felt252Metal result = felt_one_montgomery();
    for (int bit = 251; bit >= 0; --bit) {
        result = felt_mont_mul(result, result);
        if (bit < 192 || bit == 196 || bit == 251) result = felt_mont_mul(result, value);
    }
    return result;
}
inline Felt252Metal felt_load_scratch(device uint *arena, uint offset) {
    Felt252Metal value;
    for (uint i = 0; i < 16u; ++i) value.limbs[i] = ushort(arena[offset + i]);
    return value;
}
inline void felt_store_scratch(device uint *arena, uint offset, thread const Felt252Metal &value) {
    for (uint i = 0; i < 16u; ++i) arena[offset + i] = uint(value.limbs[i]);
}
inline Felt252Metal felt_from_m31_words(thread const uint *words) {
    uint packed[8]; for (uint i = 0; i < 8u; ++i) packed[i] = 0u;
    for (uint i = 0; i < 28u; ++i) {
        uint bit = i * 9u, limb = bit >> 5u, shift = bit & 31u;
        packed[limb] |= words[i] << shift;
        if (shift > 23u && limb + 1u < 8u) packed[limb + 1u] |= words[i] >> (32u - shift);
    }
    Felt252Metal result;
    for (uint i = 0; i < 8u; ++i) { result.limbs[2u * i] = ushort(packed[i]); result.limbs[2u * i + 1u] = ushort(packed[i] >> 16u); }
    return result;
}
inline void felt_to_m31_words(thread const Felt252Metal &value, thread uint *words) {
    uint packed[8];
    for (uint i = 0; i < 8u; ++i) packed[i] = uint(value.limbs[2u * i]) | (uint(value.limbs[2u * i + 1u]) << 16u);
    for (uint i = 0; i < 28u; ++i) {
        uint bit = i * 9u, limb = bit >> 5u, shift = bit & 31u;
        uint word = packed[limb] >> shift;
        if (shift > 23u && limb + 1u < 8u) word |= packed[limb + 1u] << (32u - shift);
        words[i] = word & 0x1ffu;
    }
}

#endif
