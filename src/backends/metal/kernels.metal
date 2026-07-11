#include <metal_stdlib>
using namespace metal;

constant uint blake2s_iv[8] = {
    0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
    0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u,
};

constant uchar blake2s_sigma[10][16] = {
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
};

inline uint rotr32(uint value, uint shift) {
    return (value >> shift) | (value << (32u - shift));
}

inline void blake2s_g(
    thread const uint *message,
    uint round,
    uint index,
    thread uint &a,
    thread uint &b,
    thread uint &c,
    thread uint &d
) {
    a = a + b + message[blake2s_sigma[round][2u * index]];
    d = rotr32(d ^ a, 16u);
    c += d;
    b = rotr32(b ^ c, 12u);
    a = a + b + message[blake2s_sigma[round][2u * index + 1u]];
    d = rotr32(d ^ a, 8u);
    c += d;
    b = rotr32(b ^ c, 7u);
}

inline void blake2s_compress(
    thread uint *state,
    thread const uint *message,
    uint total_bytes,
    bool is_last
) {
    uint v[16];
    for (uint i = 0; i < 8u; ++i) {
        v[i] = state[i];
        v[i + 8u] = blake2s_iv[i];
    }
    v[12] ^= total_bytes;
    if (is_last) v[14] ^= 0xFFFFFFFFu;

    for (uint round = 0; round < 10u; ++round) {
        blake2s_g(message, round, 0u, v[0], v[4], v[8], v[12]);
        blake2s_g(message, round, 1u, v[1], v[5], v[9], v[13]);
        blake2s_g(message, round, 2u, v[2], v[6], v[10], v[14]);
        blake2s_g(message, round, 3u, v[3], v[7], v[11], v[15]);
        blake2s_g(message, round, 4u, v[0], v[5], v[10], v[15]);
        blake2s_g(message, round, 5u, v[1], v[6], v[11], v[12]);
        blake2s_g(message, round, 6u, v[2], v[7], v[8], v[13]);
        blake2s_g(message, round, 7u, v[3], v[4], v[9], v[14]);
    }
    for (uint i = 0; i < 8u; ++i) state[i] ^= v[i] ^ v[i + 8u];
}

inline uint lifted_index(uint index, uint log_ratio) {
    if (log_ratio == 0u) return index;
    return ((index >> (log_ratio + 1u)) << 1u) | (index & 1u);
}

kernel void stwo_zig_blake2s_leaves(
    device const uint *flat_columns [[buffer(0)]],
    device const uint *column_offsets [[buffer(1)]],
    device const uint *column_log_sizes [[buffer(2)]],
    device uint *destination [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    constant uint &lifting_log_size [[buffer(5)]],
    constant uint *leaf_seed [[buffer(6)]],
    uint row [[thread_position_in_grid]]
) {
    uint row_count = 1u << lifting_log_size;
    if (row >= row_count) return;

    uint state[8];
    for (uint i = 0; i < 8u; ++i) state[i] = leaf_seed[i];

    uint message[16];
    uint in_block = 0u;
    uint total_bytes = 64u;
    for (uint column = 0; column < column_count; ++column) {
        uint log_size = column_log_sizes[column];
        uint source = lifted_index(row, lifting_log_size - log_size);
        message[in_block++] = flat_columns[column_offsets[column] + source];
        total_bytes += 4u;
        if (in_block == 16u) {
            bool last = column + 1u == column_count;
            blake2s_compress(state, message, total_bytes, last);
            in_block = 0u;
        }
    }
    if (in_block != 0u) {
        for (uint i = in_block; i < 16u; ++i) message[i] = 0u;
        blake2s_compress(state, message, total_bytes, true);
    }
    uint base = row * 8u;
    for (uint i = 0; i < 8u; ++i) destination[base + i] = state[i];
}

kernel void stwo_zig_blake2s_parents(
    device const uint *children [[buffer(0)]],
    device uint *destination [[buffer(1)]],
    constant uint &parent_count [[buffer(2)]],
    constant uint *node_seed [[buffer(3)]],
    uint parent [[thread_position_in_grid]]
) {
    if (parent >= parent_count) return;
    uint state[8];
    uint message[16];
    for (uint i = 0; i < 8u; ++i) state[i] = node_seed[i];
    for (uint i = 0; i < 16u; ++i) message[i] = children[parent * 16u + i];
    blake2s_compress(state, message, 128u, true);
    for (uint i = 0; i < 8u; ++i) destination[parent * 8u + i] = state[i];
}

kernel void stwo_zig_blake2s_parents_sparse(
    device uint *arena [[buffer(0)]], constant uint &child_offset [[buffer(1)]],
    constant uint &destination_offset [[buffer(2)]], constant uint &parent_count [[buffer(3)]],
    constant uint *node_seed [[buffer(4)]], uint parent [[thread_position_in_grid]]
) {
    if (parent >= parent_count) return;
    uint state[8], message[16];
    for (uint i = 0; i < 8u; ++i) state[i] = node_seed[i];
    for (uint i = 0; i < 16u; ++i) message[i] = arena[child_offset + parent * 16u + i];
    blake2s_compress(state, message, 128u, true);
    for (uint i = 0; i < 8u; ++i) arena[destination_offset + parent * 8u + i] = state[i];
}

struct Qm31Value { uint a, b, c, d; };
inline Qm31Value qm_mul_m31(Qm31Value value, uint scalar);
inline Qm31Value qm_mul(Qm31Value lhs, Qm31Value rhs);
struct Cm31Value { uint a, b; };
struct QuotientView { uint offset, length, batch, shift, direct; };
struct RawQuotientView {
    uint offset, length, batch, shift, direct;
    uint coeff_a, coeff_b, coeff_c, coeff_d;
};

inline uint m31_reduce(ulong value) {
    ulong reduced = (value & 0x7ffffffful) + (value >> 31u);
    reduced = (reduced & 0x7ffffffful) + (reduced >> 31u);
    uint result = (uint)reduced;
    return result >= 0x7fffffffu ? result - 0x7fffffffu : result;
}
inline uint m31_add(uint lhs, uint rhs) { return m31_reduce((ulong)lhs + rhs); }
inline uint m31_sub(uint lhs, uint rhs) { return lhs >= rhs ? lhs - rhs : lhs + 0x7fffffffu - rhs; }
inline uint m31_mul(uint lhs, uint rhs) { return m31_reduce((ulong)lhs * rhs); }
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

struct Felt252Metal { ushort limbs[16]; };
struct EcPointMetal { Felt252Metal x; Felt252Metal y; };

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

kernel void stwo_zig_felt252_oracle(
    device const uint *inputs [[buffer(0)]], device uint *outputs [[buffer(1)]],
    constant uint &count [[buffer(2)]], uint index [[thread_position_in_grid]]
) {
    if (index >= count) return;
    Felt252Metal a, b;
    for (uint i = 0; i < 8u; ++i) {
        uint av = inputs[index * 16u + i], bv = inputs[index * 16u + 8u + i];
        a.limbs[2u * i] = ushort(av); a.limbs[2u * i + 1u] = ushort(av >> 16u);
        b.limbs[2u * i] = ushort(bv); b.limbs[2u * i + 1u] = ushort(bv >> 16u);
    }
    Felt252Metal am = felt_to_montgomery(a), bm = felt_to_montgomery(b);
    Felt252Metal product = felt_from_montgomery(felt_mont_mul(am, bm));
    Felt252Metal inverse = felt_from_montgomery(felt_inverse_252(am));
    for (uint i = 0; i < 8u; ++i) {
        outputs[index * 16u + i] = uint(product.limbs[2u * i]) | (uint(product.limbs[2u * i + 1u]) << 16u);
        outputs[index * 16u + 8u + i] = uint(inverse.limbs[2u * i]) | (uint(inverse.limbs[2u * i + 1u]) << 16u);
    }
}

inline void ec_double_with_inverse(thread EcPointMetal &point, thread const Felt252Metal &inverse) {
    Felt252Metal x2 = felt_mont_mul(point.x, point.x);
    Felt252Metal numerator = felt_add_252(felt_add_252(x2, x2), x2);
    numerator = felt_add_252(numerator, felt_one_montgomery());
    Felt252Metal lambda = felt_mont_mul(numerator, inverse);
    Felt252Metal x3 = felt_sub_252(felt_mont_mul(lambda, lambda), felt_add_252(point.x, point.x));
    Felt252Metal y3 = felt_sub_252(felt_mont_mul(lambda, felt_sub_252(point.x, x3)), point.y);
    point.x = x3; point.y = y3;
}
inline void ec_add_with_inverse(
    thread EcPointMetal &left, thread const EcPointMetal &right,
    thread const Felt252Metal &inverse, bool equal
) {
    if (equal) { ec_double_with_inverse(left, inverse); return; }
    Felt252Metal lambda = felt_mont_mul(felt_sub_252(right.y, left.y), inverse);
    Felt252Metal x3 = felt_sub_252(felt_sub_252(felt_mont_mul(lambda, lambda), left.x), right.x);
    Felt252Metal y3 = felt_sub_252(felt_mont_mul(lambda, felt_sub_252(left.x, x3)), left.y);
    left.x = x3; left.y = y3;
}
inline void ec_store_lookup(device uint *arena, uint lookup, uint rows, uint row, uint word, uint value) {
    arena[lookup + word * rows + row] = value;
}
inline void ec_store_address_lookup(device uint *arena, uint lookup, uint rows, uint row, uint word, uint address, uint id) {
    ec_store_lookup(arena, lookup, rows, row, word, 1444891767u);
    ec_store_lookup(arena, lookup, rows, row, word + 1u, address);
    ec_store_lookup(arena, lookup, rows, row, word + 2u, id);
}
inline void ec_store_big_lookup(
    device uint *arena, uint lookup, uint rows, uint row, uint word, uint id,
    thread const uint *limbs
) {
    ec_store_lookup(arena, lookup, rows, row, word, 1662111297u);
    ec_store_lookup(arena, lookup, rows, row, word + 1u, id);
    for (uint limb = 0; limb < 28u; ++limb) ec_store_lookup(arena, lookup, rows, row, word + 2u + limb, limbs[limb]);
}
inline Felt252Metal ec_load_memory(
    device uint *arena, device const uint *execution_offsets, uint id,
    thread uint *limbs
) {
    uint tag = id >> 30u, index = id & 0x3fffffffu;
    if (tag == 1u) {
        for (uint limb = 0; limb < 28u; ++limb) limbs[limb] = arena[execution_offsets[1u + limb] + index];
    } else {
        for (uint limb = 0; limb < 8u; ++limb) limbs[limb] = arena[execution_offsets[29u + limb] + index];
        for (uint limb = 8u; limb < 28u; ++limb) limbs[limb] = 0u;
    }
    return felt_from_m31_words(limbs);
}
inline void ec_store_trace_limbs(
    device uint *arena, device const uint *trace_offsets, uint first, uint row,
    thread const uint *limbs
) {
    for (uint limb = 0; limb < 28u; ++limb) arena[trace_offsets[first + limb] + row] = limbs[limb];
}
inline void ec_count_memory(
    device uint *arena, device const uint *multiplicity_offsets,
    uint address, uint id
) {
    atomic_fetch_add_explicit((device atomic_uint *)&arena[multiplicity_offsets[0] + address - 1u], 1u, memory_order_relaxed);
    uint tag = id >> 30u, index = id & 0x3fffffffu;
    uint destination = tag == 1u ? multiplicity_offsets[1] : multiplicity_offsets[2];
    atomic_fetch_add_explicit((device atomic_uint *)&arena[destination + index], 1u, memory_order_relaxed);
}
inline void ec_store_partial(
    device uint *arena, device const uint *partial_offsets, uint destination,
    uint chain, uint round, thread const uint *m,
    thread const EcPointMetal &q, thread const EcPointMetal &accumulator,
    uint counter, uint enabler
) {
    uint limbs[28];
    arena[partial_offsets[0] + destination] = chain; arena[partial_offsets[1] + destination] = round;
    for (uint word = 0; word < 10u; ++word) arena[partial_offsets[2u + word] + destination] = m[word];
    Felt252Metal value = felt_from_montgomery(q.x); felt_to_m31_words(value, limbs);
    for (uint i = 0; i < 28u; ++i) arena[partial_offsets[12u + i] + destination] = limbs[i];
    value = felt_from_montgomery(q.y); felt_to_m31_words(value, limbs);
    for (uint i = 0; i < 28u; ++i) arena[partial_offsets[40u + i] + destination] = limbs[i];
    value = felt_from_montgomery(accumulator.x); felt_to_m31_words(value, limbs);
    for (uint i = 0; i < 28u; ++i) arena[partial_offsets[68u + i] + destination] = limbs[i];
    value = felt_from_montgomery(accumulator.y); felt_to_m31_words(value, limbs);
    for (uint i = 0; i < 28u; ++i) arena[partial_offsets[96u + i] + destination] = limbs[i];
    arena[partial_offsets[124] + destination] = counter;
    arena[partial_offsets[125] + destination] = enabler;
}
inline void ec_store_partial_lookup(
    device uint *arena, uint lookup, uint rows, uint row, uint first_word,
    uint chain, uint round, thread const uint *m,
    thread const EcPointMetal &q, thread const EcPointMetal &accumulator, uint counter
) {
    uint limbs[28], word = first_word;
    ec_store_lookup(arena, lookup, rows, row, word++, 183619546u);
    ec_store_lookup(arena, lookup, rows, row, word++, chain); ec_store_lookup(arena, lookup, rows, row, word++, round);
    for (uint i = 0; i < 10u; ++i) ec_store_lookup(arena, lookup, rows, row, word++, m[i]);
    Felt252Metal values[4] = { q.x, q.y, accumulator.x, accumulator.y };
    for (uint value_index = 0; value_index < 4u; ++value_index) {
        Felt252Metal value = felt_from_montgomery(values[value_index]); felt_to_m31_words(value, limbs);
        for (uint limb = 0; limb < 28u; ++limb) ec_store_lookup(arena, lookup, rows, row, word++, limbs[limb]);
    }
    ec_store_lookup(arena, lookup, rows, row, word, counter);
}

kernel void stwo_zig_ec_op_witness(
    device uint *arena [[buffer(0)]], device const uint *execution_offsets [[buffer(1)]],
    device const uint *trace_offsets [[buffer(2)]], device const uint *partial_offsets [[buffer(3)]],
    device const uint *multiplicity_offsets [[buffer(4)]], constant uint *params [[buffer(5)]],
    uint row [[thread_position_in_grid]], uint local_row [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]], uint group_size [[threads_per_threadgroup]]
) {
    uint lookup = params[0], segment_offset = params[1], rows = params[3];
    if (row >= rows) return;
    threadgroup Felt252Metal prefix_products[256];
    threadgroup Felt252Metal suffix_products[256];
    threadgroup Felt252Metal total_inverse;
    uint limbs[28], m[10];
    EcPointMetal accumulator, q;
    uint base = arena[segment_offset] + 7u * row;
    uint address_offset = execution_offsets[0];

    uint id = arena[address_offset + base];
    Felt252Metal standard = ec_load_memory(arena, execution_offsets, id, limbs);
    arena[trace_offsets[0] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 1, row, limbs);
    ec_count_memory(arena, multiplicity_offsets, base, id); ec_store_address_lookup(arena, lookup, rows, row, 0, base, id);
    ec_store_big_lookup(arena, lookup, rows, row, 3, id, limbs); accumulator.x = felt_to_montgomery(standard);

    id = arena[address_offset + base + 1u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    arena[trace_offsets[29] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 30, row, limbs);
    ec_count_memory(arena, multiplicity_offsets, base + 1u, id); ec_store_address_lookup(arena, lookup, rows, row, 33, base + 1u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 36, id, limbs); accumulator.y = felt_to_montgomery(standard);

    id = arena[address_offset + base + 2u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    arena[trace_offsets[58] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 59, row, limbs);
    ec_count_memory(arena, multiplicity_offsets, base + 2u, id); ec_store_address_lookup(arena, lookup, rows, row, 66, base + 2u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 69, id, limbs); q.x = felt_to_montgomery(standard);

    id = arena[address_offset + base + 3u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    arena[trace_offsets[87] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 88, row, limbs);
    ec_count_memory(arena, multiplicity_offsets, base + 3u, id); ec_store_address_lookup(arena, lookup, rows, row, 99, base + 3u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 102, id, limbs); q.y = felt_to_montgomery(standard);

    id = arena[address_offset + base + 4u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    arena[trace_offsets[116] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 117, row, limbs);
    ec_count_memory(arena, multiplicity_offsets, base + 4u, id); ec_store_address_lookup(arena, lookup, rows, row, 132, base + 4u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 135, id, limbs);
    for (uint word = 0; word < 9u; ++word) m[word] = limbs[3u * word] | (limbs[3u * word + 1u] << 9u) | (limbs[3u * word + 2u] << 18u);
    m[9] = limbs[27];
    uint ms_is_max = limbs[27] == 256u, ms_mid_max = ms_is_max && limbs[21] == 136u;
    uint rc0 = limbs[27] - ms_is_max, rc1 = ms_is_max * (120u + limbs[21] - ms_mid_max);
    arena[trace_offsets[145] + row] = ms_is_max; arena[trace_offsets[146] + row] = ms_mid_max; arena[trace_offsets[147] + row] = rc1;
    ec_store_lookup(arena, lookup, rows, row, 165, 1420243005u); ec_store_lookup(arena, lookup, rows, row, 166, rc0);
    ec_store_lookup(arena, lookup, rows, row, 167, 1420243005u); ec_store_lookup(arena, lookup, rows, row, 168, rc1);
    atomic_fetch_add_explicit((device atomic_uint *)&arena[multiplicity_offsets[3] + rc0], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit((device atomic_uint *)&arena[multiplicity_offsets[3] + rc1], 1u, memory_order_relaxed);
    uint counter = 26u;
    ec_store_partial_lookup(arena, lookup, rows, row, 169, row, 0, m, q, accumulator, counter);

    uint group_start = group * group_size, group_rows = min(group_size, rows - group_start);
    for (uint round = 0; round < 252u; ++round) {
        ec_store_partial(arena, partial_offsets, round * rows + row, row, round, m, q, accumulator, counter, 1u);
        bool add_point = (m[0] & 1u) != 0u;
        bool equal = felt_equal_252(accumulator.x, q.x) && felt_equal_252(accumulator.y, q.y);
        Felt252Metal add_denominator = !add_point ? felt_one_montgomery() :
            (equal ? felt_add_252(accumulator.y, accumulator.y) : felt_sub_252(q.x, accumulator.x));
        Felt252Metal double_denominator = felt_add_252(q.y, q.y);
        Felt252Metal product = felt_mont_mul(add_denominator, double_denominator);
        prefix_products[local_row] = product;
        suffix_products[local_row] = product;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 1u; stride < group_rows; stride <<= 1u) {
            Felt252Metal prefix = prefix_products[local_row];
            Felt252Metal suffix = suffix_products[local_row];
            Felt252Metal preceding = felt_one_montgomery();
            Felt252Metal following = felt_one_montgomery();
            if (local_row >= stride) preceding = prefix_products[local_row - stride];
            if (local_row + stride < group_rows) following = suffix_products[local_row + stride];
            threadgroup_barrier(mem_flags::mem_threadgroup);
            prefix_products[local_row] = felt_mont_mul(preceding, prefix);
            suffix_products[local_row] = felt_mont_mul(suffix, following);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        Felt252Metal preceding = felt_one_montgomery();
        Felt252Metal following = felt_one_montgomery();
        if (local_row != 0u) preceding = prefix_products[local_row - 1u];
        if (local_row + 1u < group_rows) following = suffix_products[local_row + 1u];
        if (local_row == 0u) {
            Felt252Metal total = prefix_products[group_rows - 1u];
            total_inverse = felt_inverse_252(total);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        Felt252Metal inverse = total_inverse;
        Felt252Metal inverse_product = felt_mont_mul(felt_mont_mul(inverse, preceding), following);
        Felt252Metal add_inverse = felt_mont_mul(double_denominator, inverse_product);
        Felt252Metal double_inverse = felt_mont_mul(add_denominator, inverse_product);
        if (add_point) ec_add_with_inverse(accumulator, q, add_inverse, equal);
        ec_double_with_inverse(q, double_inverse);
        if (counter == 0u) {
            for (uint word = 0; word + 1u < 10u; ++word) m[word] = m[word + 1u];
            m[9] = 0u; counter = 26u;
        } else { m[0] >>= 1u; --counter; }
        threadgroup_barrier(mem_flags::mem_device);
    }

    for (uint word = 0; word < 10u; ++word) arena[trace_offsets[148u + word] + row] = m[word];
    Felt252Metal finals[4] = { q.x, q.y, accumulator.x, accumulator.y };
    const uint trace_starts[4] = { 158u, 186u, 214u, 242u };
    for (uint value_index = 0; value_index < 4u; ++value_index) {
        standard = felt_from_montgomery(finals[value_index]); felt_to_m31_words(standard, limbs);
        ec_store_trace_limbs(arena, trace_offsets, trace_starts[value_index], row, limbs);
    }
    arena[trace_offsets[270] + row] = counter;
    ec_store_partial_lookup(arena, lookup, rows, row, 295, row, 252u, m, q, accumulator, counter);
    uint result_x_id = arena[address_offset + base + 5u]; arena[trace_offsets[271] + row] = result_x_id;
    ec_count_memory(arena, multiplicity_offsets, base + 5u, result_x_id); ec_store_address_lookup(arena, lookup, rows, row, 421, base + 5u, result_x_id);
    standard = felt_from_montgomery(accumulator.x); felt_to_m31_words(standard, limbs); ec_store_big_lookup(arena, lookup, rows, row, 424, result_x_id, limbs);
    uint result_y_id = arena[address_offset + base + 6u]; arena[trace_offsets[272] + row] = result_y_id;
    ec_count_memory(arena, multiplicity_offsets, base + 6u, result_y_id); ec_store_address_lookup(arena, lookup, rows, row, 454, base + 6u, result_y_id);
    standard = felt_from_montgomery(accumulator.y); felt_to_m31_words(standard, limbs); ec_store_big_lookup(arena, lookup, rows, row, 457, result_y_id, limbs);
    ec_store_lookup(arena, lookup, rows, row, 487, 1u);

    for (uint round = 0; round < 256u; ++round) {
        uint destination = round * rows + row;
        arena[partial_offsets[126] + destination] = destination;
    }
    for (uint pad = row; pad < 4u * rows; pad += rows) {
        uint destination = 252u * rows + pad, source = pad & 15u;
        for (uint column = 0; column < 125u; ++column) arena[partial_offsets[column] + destination] = arena[partial_offsets[column] + source];
        arena[partial_offsets[125] + destination] = 0u;
    }
}

inline uint circle_twiddle(device const uint *twiddles, uint index) {
    uint pair = index >> 2u;
    switch (index & 3u) {
        case 0u: return twiddles[2u * pair + 1u];
        case 1u: return m31_neg(twiddles[2u * pair + 1u]);
        case 2u: return m31_neg(twiddles[2u * pair]);
        default: return twiddles[2u * pair];
    }
}

kernel void stwo_zig_circle_ifft_first(
    device uint *values [[buffer(0)]],
    device const uint *twiddles [[buffer(1)]],
    constant uint &log_size [[buffer(2)]],
    constant uint &column_count [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint base = position.y << log_size;
    uint idx0 = base + (position.x << 1u);
    uint idx1 = idx0 + 1u;
    uint lhs = values[idx0];
    uint rhs = values[idx1];
    uint twiddle = circle_twiddle(twiddles, position.x);
    values[idx0] = m31_add(lhs, rhs);
    values[idx1] = m31_mul(m31_sub(lhs, rhs), twiddle);
}

kernel void stwo_zig_circle_ifft_layer(
    device uint *values [[buffer(0)]],
    device const uint *twiddles [[buffer(1)]],
    constant uint &log_size [[buffer(2)]],
    constant uint &layer [[buffer(3)]],
    constant uint &twiddle_offset [[buffer(4)]],
    constant uint &column_count [[buffer(5)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint polynomial_count = 1u << layer;
    uint twiddle_index = position.x >> layer;
    uint lane = position.x & (polynomial_count - 1u);
    uint base = (position.y << log_size) + (twiddle_index << (layer + 1u));
    uint idx0 = base + lane;
    uint idx1 = idx0 + polynomial_count;
    uint lhs = values[idx0];
    uint rhs = values[idx1];
    values[idx0] = m31_add(lhs, rhs);
    values[idx1] = m31_mul(m31_sub(lhs, rhs), twiddles[twiddle_offset + twiddle_index]);
}

kernel void stwo_zig_circle_rfft_layer(
    device uint *values [[buffer(0)]],
    device const uint *twiddles [[buffer(1)]],
    constant uint &log_size [[buffer(2)]],
    constant uint &layer [[buffer(3)]],
    constant uint &twiddle_offset [[buffer(4)]],
    constant uint &column_count [[buffer(5)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint polynomial_count = 1u << layer;
    uint twiddle_index = position.x >> layer;
    uint lane = position.x & (polynomial_count - 1u);
    uint base = (position.y << log_size) + (twiddle_index << (layer + 1u));
    uint idx0 = base + lane;
    uint idx1 = idx0 + polynomial_count;
    uint lhs = values[idx0];
    uint product = m31_mul(values[idx1], twiddles[twiddle_offset + twiddle_index]);
    values[idx0] = m31_add(lhs, product);
    values[idx1] = m31_sub(lhs, product);
}

kernel void stwo_zig_circle_rfft_last(
    device uint *values [[buffer(0)]],
    device const uint *twiddles [[buffer(1)]],
    constant uint &log_size [[buffer(2)]],
    constant uint &column_count [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint base = position.y << log_size;
    uint idx0 = base + (position.x << 1u);
    uint idx1 = idx0 + 1u;
    uint lhs = values[idx0];
    uint product = m31_mul(values[idx1], circle_twiddle(twiddles, position.x));
    values[idx0] = m31_add(lhs, product);
    values[idx1] = m31_sub(lhs, product);
}

kernel void stwo_zig_circle_rescale(
    device uint *values [[buffer(0)]],
    constant uint &value_count [[buffer(1)]],
    constant uint &factor [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index < value_count) values[index] = m31_mul(values[index], factor);
}

kernel void stwo_zig_circle_expand_coefficients(
    device const uint *coefficients [[buffer(0)]],
    device uint *extended [[buffer(1)]],
    constant uint &base_log_size [[buffer(2)]],
    constant uint &extended_log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint extended_len = 1u << extended_log_size;
    if (position.x >= extended_len || position.y >= column_count) return;
    uint base_len = 1u << base_log_size;
    uint value = position.x < base_len
        ? coefficients[(position.y << base_log_size) + position.x]
        : 0u;
    extended[(position.y << extended_log_size) + position.x] = value;
}

kernel void stwo_zig_circle_expand_sparse(
    device uint *arena [[buffer(0)]],
    device const uint *source_offsets [[buffer(1)]],
    device const uint *destination_offsets [[buffer(2)]],
    constant uint &base_log_size [[buffer(3)]],
    constant uint &extended_log_size [[buffer(4)]],
    constant uint &column_count [[buffer(5)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint extended_len = 1u << extended_log_size;
    if (position.x >= extended_len || position.y >= column_count) return;
    uint base_len = 1u << base_log_size;
    uint value = position.x < base_len ? arena[source_offsets[position.y] + position.x] : 0u;
    arena[destination_offsets[position.y] + position.x] = value;
}

kernel void stwo_zig_composition_expand_sparse(
    device uint *arena [[buffer(0)]], device const uint *source_offsets [[buffer(1)]],
    device const uint *source_log_sizes [[buffer(2)]], device const uint *destination_offsets [[buffer(3)]],
    constant uint &extended_log_size [[buffer(4)]], constant uint &column_count [[buffer(5)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint extended_len = 1u << extended_log_size;
    if (position.x >= extended_len || position.y >= column_count) return;
    uint source_len = 1u << source_log_sizes[position.y];
    arena[destination_offsets[position.y] + position.x] =
        position.x < source_len ? arena[source_offsets[position.y] + position.x] : 0u;
}

kernel void stwo_zig_circle_copy_sparse(
    device uint *arena [[buffer(0)]], device const uint *source_offsets [[buffer(1)]],
    device const uint *destination_offsets [[buffer(2)]], constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]], uint2 position [[thread_position_in_grid]]
) {
    uint length = 1u << log_size;
    if (position.x < length && position.y < column_count)
        arena[destination_offsets[position.y] + position.x] = arena[source_offsets[position.y] + position.x];
}

kernel void stwo_zig_circle_ifft_first_sparse(
    device uint *arena [[buffer(0)]], device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]], constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]], uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint idx0 = destination_offsets[position.y] + (position.x << 1u), idx1 = idx0 + 1u;
    uint lhs = arena[idx0], rhs = arena[idx1];
    arena[idx0] = m31_add(lhs, rhs);
    arena[idx1] = m31_mul(m31_sub(lhs, rhs), circle_twiddle(twiddles, position.x));
}

kernel void stwo_zig_circle_ifft_layer_sparse(
    device uint *arena [[buffer(0)]], device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]], constant uint &log_size [[buffer(3)]],
    constant uint &layer [[buffer(4)]], constant uint &twiddle_offset [[buffer(5)]],
    constant uint &column_count [[buffer(6)]], uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint polynomial_count = 1u << layer;
    uint twiddle_index = position.x >> layer, lane = position.x & (polynomial_count - 1u);
    uint base = destination_offsets[position.y] + (twiddle_index << (layer + 1u));
    uint idx0 = base + lane, idx1 = idx0 + polynomial_count;
    uint lhs = arena[idx0], rhs = arena[idx1];
    arena[idx0] = m31_add(lhs, rhs);
    arena[idx1] = m31_mul(m31_sub(lhs, rhs), twiddles[twiddle_offset + twiddle_index]);
}

kernel void stwo_zig_circle_rescale_sparse(
    device uint *arena [[buffer(0)]], device const uint *destination_offsets [[buffer(1)]],
    constant uint &log_size [[buffer(2)]], constant uint &column_count [[buffer(3)]],
    constant uint &factor [[buffer(4)]], uint2 position [[thread_position_in_grid]]
) {
    uint length = 1u << log_size;
    if (position.x < length && position.y < column_count) {
        uint index = destination_offsets[position.y] + position.x;
        arena[index] = m31_mul(arena[index], factor);
    }
}

kernel void stwo_zig_fixed_table_lookup_sparse(
    device uint *arena [[buffer(0)]], device const uint *descriptors [[buffer(1)]],
    device const uint *source_offsets [[buffer(2)]], device const uint *multiplicity_offsets [[buffer(3)]],
    constant uint &destination_offset [[buffer(4)]], constant uint &row_count [[buffer(5)]],
    constant uint &output_count [[buffer(6)]], uint index [[thread_position_in_grid]]
) {
    uint total = row_count * output_count;
    if (index >= total) return;
    uint output = index / row_count, row = index - output * row_count;
    device const uint *descriptor = descriptors + output * 4u;
    uint kind = descriptor[0], value = 0u;
    if (kind == 0u) value = descriptor[1];
    else if (kind == 1u) value = arena[source_offsets[descriptor[1]] + row];
    else if (kind == 2u) value = arena[multiplicity_offsets[descriptor[1]] + row];
    else {
        uint column = descriptor[1], limb_bits = descriptor[2], expand_bits = descriptor[3];
        uint expand_mask = (1u << expand_bits) - 1u, limb_mask = (1u << limb_bits) - 1u;
        uint a = ((column >> expand_bits) << limb_bits) | (row >> limb_bits);
        uint b = ((column & expand_mask) << limb_bits) | (row & limb_mask);
        value = kind == 3u ? a : (kind == 4u ? b : (a ^ b));
    }
    arena[destination_offset + index] = value;
}

kernel void stwo_zig_circle_rfft_layer_sparse(
    device uint *arena [[buffer(0)]],
    device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &layer [[buffer(4)]],
    constant uint &twiddle_offset [[buffer(5)]],
    constant uint &column_count [[buffer(6)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint polynomial_count = 1u << layer;
    uint twiddle_index = position.x >> layer;
    uint lane = position.x & (polynomial_count - 1u);
    uint base = destination_offsets[position.y] + (twiddle_index << (layer + 1u));
    uint idx0 = base + lane, idx1 = idx0 + polynomial_count;
    uint lhs = arena[idx0];
    uint product = m31_mul(arena[idx1], twiddles[twiddle_offset + twiddle_index]);
    arena[idx0] = m31_add(lhs, product);
    arena[idx1] = m31_sub(lhs, product);
}

kernel void stwo_zig_circle_rfft_last_sparse(
    device uint *arena [[buffer(0)]],
    device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint idx0 = destination_offsets[position.y] + (position.x << 1u), idx1 = idx0 + 1u;
    uint lhs = arena[idx0];
    uint product = m31_mul(arena[idx1], circle_twiddle(twiddles, position.x));
    arena[idx0] = m31_add(lhs, product);
    arena[idx1] = m31_sub(lhs, product);
}

kernel void stwo_zig_composition_lift_accumulate(
    device uint *arena [[buffer(0)]], constant uint &previous_offset [[buffer(1)]],
    constant uint &previous_log [[buffer(2)]], constant uint &current_offset [[buffer(3)]],
    constant uint &current_log [[buffer(4)]], uint index [[thread_position_in_grid]]
) {
    uint current_size = 1u << current_log;
    if (index >= current_size) return;
    uint previous_size = 1u << previous_log, log_ratio = current_log - previous_log;
    uint lifted = (index >> (log_ratio + 1u) << 1u) + (index & 1u);
    for (uint coordinate = 0u; coordinate < 4u; ++coordinate) {
        uint destination = current_offset + coordinate * current_size + index;
        arena[destination] = m31_add(arena[destination], arena[previous_offset + coordinate * previous_size + lifted]);
    }
}

kernel void stwo_zig_composition_split_coordinates(
    device uint *arena [[buffer(0)]], device const uint *outputs [[buffer(1)]],
    constant uint &source_offset [[buffer(2)]], constant uint &full_log [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    uint half_size = 1u << (full_log - 1u), total = half_size * 8u;
    if (index >= total) return;
    uint output = index / half_size, row = index - output * half_size;
    uint coordinate = output & 3u, half_index = output >> 2u;
    uint source = source_offset + coordinate * (half_size << 1u) + half_index * half_size + row;
    arena[outputs[output] + row] = arena[source];
}

kernel void stwo_zig_composition_random_powers(
    device uint *arena [[buffer(0)]], constant uint &random_offset [[buffer(1)]],
    constant uint &powers_offset [[buffer(2)]], constant uint &count [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= count) return;
    Qm31Value base = { arena[random_offset], arena[random_offset+1u], arena[random_offset+2u], arena[random_offset+3u] };
    Qm31Value result = { 1u, 0u, 0u, 0u };
    uint exponent = count - 1u - index;
    while (exponent != 0u) {
        if ((exponent & 1u) != 0u) result = qm_mul(result, base);
        base = qm_mul(base, base); exponent >>= 1u;
    }
    uint destination = powers_offset + index * 4u;
    arena[destination]=result.a; arena[destination+1u]=result.b;
    arena[destination+2u]=result.c; arena[destination+3u]=result.d;
}

// Descriptor: destination, kind (0 constant / 1 arena), source, scale, constant[4].
kernel void stwo_zig_composition_ext_params(
    device uint *arena [[buffer(0)]], device const uint *descriptors [[buffer(1)]],
    constant uint &count [[buffer(2)]], uint index [[thread_position_in_grid]]
) {
    if (index >= count) return;
    device const uint *descriptor = descriptors + index * 8u;
    Qm31Value value = descriptor[1] == 0u
        ? Qm31Value{descriptor[4],descriptor[5],descriptor[6],descriptor[7]}
        : Qm31Value{arena[descriptor[2]],arena[descriptor[2]+1u],arena[descriptor[2]+2u],arena[descriptor[2]+3u]};
    value = qm_mul_m31(value, descriptor[3]);
    uint destination = descriptor[0];
    arena[destination]=value.a; arena[destination+1u]=value.b;
    arena[destination+2u]=value.c; arena[destination+3u]=value.d;
}

constant uint circle_fused_tile_log = 11u;
constant uint circle_fused_tile_size = 1u << circle_fused_tile_log;
constant uint circle_fused_threads = 256u;

kernel void stwo_zig_circle_ifft_fused_tail(
    device uint *values [[buffer(0)]],
    device const uint *twiddles [[buffer(1)]],
    constant uint &log_size [[buffer(2)]],
    constant uint &column_count [[buffer(3)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    if (group.y >= column_count) return;
    threadgroup uint tile[circle_fused_tile_size];
    uint value_len = 1u << log_size;
    uint tile_offset = group.x << circle_fused_tile_log;
    uint column_offset = group.y << log_size;
    for (uint item = lane; item < circle_fused_tile_size; item += circle_fused_threads) {
        tile[item] = values[column_offset + tile_offset + item];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint pair = lane; pair < circle_fused_tile_size / 2u; pair += circle_fused_threads) {
        uint idx0 = pair << 1u;
        uint idx1 = idx0 + 1u;
        uint lhs = tile[idx0];
        uint rhs = tile[idx1];
        uint global_pair = (tile_offset >> 1u) + pair;
        tile[idx0] = m31_add(lhs, rhs);
        tile[idx1] = m31_mul(m31_sub(lhs, rhs), circle_twiddle(twiddles, global_pair));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint pair_count = value_len >> 1u;
    for (uint layer = 1u; layer < circle_fused_tile_log; ++layer) {
        uint distance = 1u << layer;
        uint stride = distance << 1u;
        uint twiddle_offset = pair_count - (1u << (log_size - layer));
        uint group_base = tile_offset / stride;
        for (uint pair = lane; pair < circle_fused_tile_size / 2u; pair += circle_fused_threads) {
            uint local_group = pair / distance;
            uint inner = pair - local_group * distance;
            uint idx0 = local_group * stride + inner;
            uint idx1 = idx0 + distance;
            uint lhs = tile[idx0];
            uint rhs = tile[idx1];
            uint twiddle = twiddles[twiddle_offset + group_base + local_group];
            tile[idx0] = m31_add(lhs, rhs);
            tile[idx1] = m31_mul(m31_sub(lhs, rhs), twiddle);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    for (uint item = lane; item < circle_fused_tile_size; item += circle_fused_threads) {
        values[column_offset + tile_offset + item] = tile[item];
    }
}

kernel void stwo_zig_circle_rfft_fused_tail(
    device uint *values [[buffer(0)]],
    device const uint *twiddles [[buffer(1)]],
    constant uint &log_size [[buffer(2)]],
    constant uint &column_count [[buffer(3)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    if (group.y >= column_count) return;
    threadgroup uint tile[circle_fused_tile_size];
    uint value_len = 1u << log_size;
    uint tile_offset = group.x << circle_fused_tile_log;
    uint column_offset = group.y << log_size;
    for (uint item = lane; item < circle_fused_tile_size; item += circle_fused_threads) {
        tile[item] = values[column_offset + tile_offset + item];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint pair_count = value_len >> 1u;
    for (uint layer = circle_fused_tile_log - 1u; layer > 0u; --layer) {
        uint distance = 1u << layer;
        uint stride = distance << 1u;
        uint twiddle_offset = pair_count - (1u << (log_size - layer));
        uint group_base = tile_offset / stride;
        for (uint pair = lane; pair < circle_fused_tile_size / 2u; pair += circle_fused_threads) {
            uint local_group = pair / distance;
            uint inner = pair - local_group * distance;
            uint idx0 = local_group * stride + inner;
            uint idx1 = idx0 + distance;
            uint lhs = tile[idx0];
            uint product = m31_mul(tile[idx1], twiddles[twiddle_offset + group_base + local_group]);
            tile[idx0] = m31_add(lhs, product);
            tile[idx1] = m31_sub(lhs, product);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    for (uint pair = lane; pair < circle_fused_tile_size / 2u; pair += circle_fused_threads) {
        uint idx0 = pair << 1u;
        uint idx1 = idx0 + 1u;
        uint lhs = tile[idx0];
        uint global_pair = (tile_offset >> 1u) + pair;
        uint product = m31_mul(tile[idx1], circle_twiddle(twiddles, global_pair));
        tile[idx0] = m31_add(lhs, product);
        tile[idx1] = m31_sub(lhs, product);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint item = lane; item < circle_fused_tile_size; item += circle_fused_threads) {
        values[column_offset + tile_offset + item] = tile[item];
    }
}

inline Cm31Value cm_add(Cm31Value lhs, Cm31Value rhs) {
    return { m31_add(lhs.a, rhs.a), m31_add(lhs.b, rhs.b) };
}
inline Cm31Value cm_sub(Cm31Value lhs, Cm31Value rhs) {
    return { m31_sub(lhs.a, rhs.a), m31_sub(lhs.b, rhs.b) };
}
inline Cm31Value cm_mul(Cm31Value lhs, Cm31Value rhs) {
    uint ac = m31_mul(lhs.a, rhs.a);
    uint bd = m31_mul(lhs.b, rhs.b);
    uint cross = m31_mul(m31_add(lhs.a, lhs.b), m31_add(rhs.a, rhs.b));
    return { m31_sub(ac, bd), m31_sub(m31_sub(cross, ac), bd) };
}
inline Cm31Value cm_inv(Cm31Value value) {
    uint denominator = m31_add(m31_mul(value.a, value.a), m31_mul(value.b, value.b));
    uint inverse = m31_inv(denominator);
    return { m31_mul(value.a, inverse), m31_mul(m31_neg(value.b), inverse) };
}
inline Cm31Value cm_mul_m31(Cm31Value value, uint scalar) {
    return { m31_mul(value.a, scalar), m31_mul(value.b, scalar) };
}

inline Qm31Value qm_add(Qm31Value lhs, Qm31Value rhs) {
    return { m31_add(lhs.a, rhs.a), m31_add(lhs.b, rhs.b),
             m31_add(lhs.c, rhs.c), m31_add(lhs.d, rhs.d) };
}
inline Qm31Value qm_sub(Qm31Value lhs, Qm31Value rhs) {
    return { m31_sub(lhs.a, rhs.a), m31_sub(lhs.b, rhs.b),
             m31_sub(lhs.c, rhs.c), m31_sub(lhs.d, rhs.d) };
}
inline Qm31Value qm_mul_cm(Qm31Value value, Cm31Value scalar) {
    Cm31Value c0 = cm_mul({ value.a, value.b }, scalar);
    Cm31Value c1 = cm_mul({ value.c, value.d }, scalar);
    return { c0.a, c0.b, c1.a, c1.b };
}
inline Qm31Value qm_mul_m31(Qm31Value value, uint scalar) {
    return { m31_mul(value.a, scalar), m31_mul(value.b, scalar),
             m31_mul(value.c, scalar), m31_mul(value.d, scalar) };
}
inline Cm31Value cm_mul_r(Cm31Value value) {
    return { m31_sub(m31_add(value.a, value.a), value.b),
             m31_add(value.a, m31_add(value.b, value.b)) };
}
inline Qm31Value qm_mul(Qm31Value lhs, Qm31Value rhs) {
    Cm31Value lhs0 = { lhs.a, lhs.b };
    Cm31Value lhs1 = { lhs.c, lhs.d };
    Cm31Value rhs0 = { rhs.a, rhs.b };
    Cm31Value rhs1 = { rhs.c, rhs.d };
    Cm31Value ac = cm_mul(lhs0, rhs0);
    Cm31Value bd = cm_mul(lhs1, rhs1);
    Cm31Value cross = cm_sub(cm_sub(cm_mul(cm_add(lhs0, lhs1), cm_add(rhs0, rhs1)), ac), bd);
    Cm31Value c0 = cm_add(ac, cm_mul_r(bd));
    return { c0.a, c0.b, cross.a, cross.b };
}
inline Qm31Value qm_inv(Qm31Value value) {
    Cm31Value c0 = { value.a, value.b };
    Cm31Value c1 = { value.c, value.d };
    Cm31Value denominator = cm_sub(cm_mul(c0, c0), cm_mul_r(cm_mul(c1, c1)));
    Cm31Value inverse = cm_inv(denominator);
    Cm31Value out0 = cm_mul(c0, inverse);
    Cm31Value out1 = cm_mul({ m31_neg(c1.a), m31_neg(c1.b) }, inverse);
    return { out0.a, out0.b, out1.a, out1.b };
}

constant uint relation_geometry_words = 10u;
constant uint relation_descriptor_words = 16u;
constant uint relation_use_words = 7u;
constant uint relation_block = 256u;

inline uint relation_instance_for_block(
    device const uint *geometry, uint count, uint block, thread uint &local_block
) {
    uint low = 0u, high = count;
    while (low < high) {
        uint middle = low + (high - low) / 2u;
        if (geometry[middle * relation_geometry_words] <= block) low = middle + 1u;
        else high = middle;
    }
    if (low == 0u) return count;
    uint instance = low - 1u;
    device const uint *g = geometry + instance * relation_geometry_words;
    local_block = block - g[0];
    return local_block < g[1] ? instance : count;
}

inline uint relation_scan_row(uint scan_index, uint rows) {
    uint circle_index = (scan_index & 1u) == 0u ? scan_index / 2u : rows - 1u - scan_index / 2u;
    uint bits = 31u - clz(rows);
    return bits == 0u ? 0u : reverse_bits(circle_index) >> (32u - bits);
}

inline uint relation_source_word(
    device const uint *arena, device const uint *source_offsets,
    uint source_base, uint rows, uint row, uint source_offset_rows,
    device const uint *use, uint word
) {
    uint kind = use[0], arg = use[1];
    if (word == 0u) return use[3];
    if (kind == 0u) return arena[source_offsets[source_base] + (arg + word) * rows + row];
    if (kind == 1u) return word == 1u ? row + 1u + arg * rows : arena[source_offsets[source_base + arg * 2u] + row];
    if (kind == 2u || kind == 4u) return arena[source_offsets[source_base + arg + word - 1u] + row];
    if (kind == 3u) return word == 1u ? ((row + source_offset_rows) | 0x40000000u) : arena[source_offsets[source_base + word - 2u] + row];
    if (kind == 5u) return word == 1u ? row + source_offset_rows : arena[source_offsets[source_base + word - 2u] + row];
    uint ah = arg >> 2u, bh = arg & 3u;
    uint a = (ah << 10u) | (row >> 10u);
    uint b = (bh << 10u) | (row & 0x3ffu);
    return word == 1u ? a : (word == 2u ? b : (a ^ b));
}

inline Qm31Value relation_combine(
    device const uint *arena, device const uint *source_offsets,
    uint source_base, uint rows, uint row, uint source_offset_rows,
    device const uint *use, device const Qm31Value *alphas, Qm31Value z
) {
    Qm31Value accumulator = { m31_neg(z.a), m31_neg(z.b), m31_neg(z.c), m31_neg(z.d) };
    for (uint word = 0u; word < use[2]; ++word) {
        accumulator = qm_add(accumulator, qm_mul_m31(alphas[word], relation_source_word(
            arena, source_offsets, source_base, rows, row, source_offset_rows, use, word)));
    }
    return accumulator;
}

inline uint relation_multiplicity(
    device const uint *arena, device const uint *source_offsets,
    uint source_base, uint rows, uint row, uint real_rows, device const uint *use
) {
    uint kind = use[4], arg = use[5], value;
    if (kind == 0u) value = 1u;
    else if (kind == 1u) value = row < real_rows ? 1u : 0u;
    else if (kind == 2u) value = arena[source_offsets[source_base] + arg * rows + row];
    else if (kind == 3u) value = arena[source_offsets[source_base + arg * 2u + 1u] + row];
    else value = arena[source_offsets[source_base + arg] + row];
    return use[6] != 0u ? m31_neg(value) : value;
}

inline void relation_fraction(
    device const uint *arena, device const uint *source_offsets, uint source_base,
    uint rows, uint row, uint real_rows, uint source_offset_rows,
    device const uint *descriptor, device const Qm31Value *alphas, Qm31Value z,
    thread Qm31Value &numerator, thread Qm31Value &denominator
) {
    device const uint *a = descriptor + 1u;
    Qm31Value da = relation_combine(arena, source_offsets, source_base, rows, row, source_offset_rows, a, alphas, z);
    uint ma = relation_multiplicity(arena, source_offsets, source_base, rows, row, real_rows, a);
    if (descriptor[0] == 2u) {
        device const uint *b = a + relation_use_words;
        Qm31Value db = relation_combine(arena, source_offsets, source_base, rows, row, source_offset_rows, b, alphas, z);
        uint mb = relation_multiplicity(arena, source_offsets, source_base, rows, row, real_rows, b);
        numerator = qm_add(qm_mul_m31(da, mb), qm_mul_m31(db, ma));
        denominator = qm_mul(da, db);
    } else {
        numerator = { ma, 0u, 0u, 0u };
        denominator = da;
    }
}

inline Qm31Value relation_denominator(
    device const uint *arena, device const uint *source_offsets, uint source_base,
    uint rows, uint row, uint source_offset_rows, device const uint *descriptor,
    device const Qm31Value *alphas, Qm31Value z
) {
    device const uint *a = descriptor + 1u;
    Qm31Value value = relation_combine(arena, source_offsets, source_base, rows, row, source_offset_rows, a, alphas, z);
    if (descriptor[0] == 2u) value = qm_mul(value, relation_combine(
        arena, source_offsets, source_base, rows, row, source_offset_rows, a + relation_use_words, alphas, z));
    return value;
}

inline void relation_store(
    device uint *arena, device const uint *output_offsets, uint output_base,
    uint column, uint row, Qm31Value value
) {
    uint base = output_base + column * 4u;
    arena[output_offsets[base] + row] = value.a;
    arena[output_offsets[base + 1u] + row] = value.b;
    arena[output_offsets[base + 2u] + row] = value.c;
    arena[output_offsets[base + 3u] + row] = value.d;
}

inline Qm31Value relation_load(
    device const uint *arena, device const uint *output_offsets, uint output_base,
    uint column, uint row
) {
    uint base = output_base + column * 4u;
    return { arena[output_offsets[base] + row], arena[output_offsets[base + 1u] + row],
             arena[output_offsets[base + 2u] + row], arena[output_offsets[base + 3u] + row] };
}

kernel void stwo_zig_relation_fused(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device const uint *source_offsets [[buffer(2)]], device const uint *descriptors [[buffer(3)]],
    device const uint *output_offsets [[buffer(4)]], device const Qm31Value *alphas [[buffer(5)]],
    device const Qm31Value *z_ptr [[buffer(6)]], constant uint &instance_count [[buffer(7)]],
    uint index [[thread_position_in_grid]]
) {
    uint block = index / relation_block, row_lane = index & (relation_block - 1u), local_block;
    uint instance = relation_instance_for_block(geometry, instance_count, block, local_block);
    if (instance == instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    uint row = local_block * relation_block + row_lane, rows = g[2];
    if (row >= rows) return;
    uint columns = g[3], source_base = g[6], descriptor_base = g[7], output_base = g[8];
    Qm31Value z = z_ptr[0], suffix = { 1u, 0u, 0u, 0u };
    for (uint column = columns; column-- > 0u;) {
        Qm31Value numerator, denominator;
        relation_fraction(arena, source_offsets, source_base, rows, row, g[4], g[5],
            descriptors + descriptor_base + column * relation_descriptor_words, alphas, z, numerator, denominator);
        relation_store(arena, output_offsets, output_base, column, row, qm_mul(numerator, suffix));
        suffix = qm_mul(suffix, denominator);
    }
    Qm31Value running = qm_inv(suffix), accumulated = { 0u, 0u, 0u, 0u };
    for (uint column = 0u; column < columns; ++column) {
        device const uint *descriptor = descriptors + descriptor_base + column * relation_descriptor_words;
        Qm31Value denominator = relation_denominator(arena, source_offsets, source_base, rows, row, g[5], descriptor, alphas, z);
        accumulated = qm_add(accumulated, qm_mul(relation_load(arena, output_offsets, output_base, column, row), running));
        relation_store(arena, output_offsets, output_base, column, row, accumulated);
        running = qm_mul(running, denominator);
    }
}

kernel void stwo_zig_relation_block_scan(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device const uint *output_offsets [[buffer(2)]], device Qm31Value *block_sums [[buffer(3)]],
    constant uint &instance_count [[buffer(4)]], uint lane [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]]
) {
    uint local_block, instance = relation_instance_for_block(geometry, instance_count, group, local_block);
    if (instance == instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    uint scan_index = local_block * relation_block + lane, rows = g[2];
    threadgroup Qm31Value values[256];
    values[lane] = scan_index < rows ? relation_load(arena, output_offsets, g[8], g[3] - 1u, relation_scan_row(scan_index, rows)) : Qm31Value{0u,0u,0u,0u};
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = 1u; offset < relation_block; offset <<= 1u) {
        Qm31Value value = values[lane];
        if (lane >= offset) value = qm_add(value, values[lane - offset]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        values[lane] = value;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (scan_index < rows) relation_store(arena, output_offsets, g[8], g[3] - 1u, relation_scan_row(scan_index, rows), values[lane]);
    uint valid = min(relation_block, rows - local_block * relation_block);
    if (lane + 1u == valid) block_sums[group] = values[lane];
}

kernel void stwo_zig_relation_scan_blocks(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device Qm31Value *block_sums [[buffer(2)]], constant uint &instance_count [[buffer(3)]],
    uint instance [[thread_position_in_grid]]
) {
    if (instance >= instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    Qm31Value sum = { 0u, 0u, 0u, 0u };
    for (uint block = 0u; block < g[1]; ++block) {
        sum = qm_add(sum, block_sums[g[0] + block]);
        block_sums[g[0] + block] = sum;
    }
    uint claimed = g[9];
    arena[claimed] = sum.a; arena[claimed + 1u] = sum.b;
    arena[claimed + 2u] = sum.c; arena[claimed + 3u] = sum.d;
}

kernel void stwo_zig_relation_scan_finalize(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device const uint *output_offsets [[buffer(2)]], device const Qm31Value *block_sums [[buffer(3)]],
    constant uint &instance_count [[buffer(4)]], uint index [[thread_position_in_grid]]
) {
    uint block = index / relation_block, lane = index & (relation_block - 1u), local_block;
    uint instance = relation_instance_for_block(geometry, instance_count, block, local_block);
    if (instance == instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    uint scan_index = local_block * relation_block + lane, rows = g[2];
    if (scan_index >= rows) return;
    uint row = relation_scan_row(scan_index, rows);
    Qm31Value value = relation_load(arena, output_offsets, g[8], g[3] - 1u, row);
    if (local_block != 0u) value = qm_add(value, block_sums[block - 1u]);
    uint claimed = g[9];
    Qm31Value total = { arena[claimed], arena[claimed + 1u], arena[claimed + 2u], arena[claimed + 3u] };
    uint shift = m31_inv(rows), prefix_count = m31_reduce((ulong)scan_index + 1u);
    value = qm_sub(value, qm_mul_m31(total, m31_mul(shift, prefix_count)));
    relation_store(arena, output_offsets, g[8], g[3] - 1u, row, value);
}

// Resident witness feed descriptor ABI, matching stwo's prepared CUDA lane.
// LUT and count "indices" are rewritten to word offsets in flat storage.
kernel void stwo_zig_witness_feed_counts(
    device atomic_uint *arena [[buffer(0)]],
    device const uint *descriptors [[buffer(1)]],
    device const uint *luts [[buffer(2)]],
    device const uint *destination_offsets [[buffer(3)]],
    device const uint *source_offsets [[buffer(4)]],
    constant uint &column_length [[buffer(5)]],
    constant uint &descriptor_count [[buffer(6)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= column_length) return;
    for (uint d = 0; d < descriptor_count; ++d) {
        device const uint *e = descriptors + d * 14u;
        uint word_base = e[0], n_words = e[1], relation = e[7];
        uint table_size = e[8], lut_offset = e[9], destination = e[10], kind = e[11];
        if (kind == 1u) {
            uint value = ((device const uint *)arena)[source_offsets[word_base] + row];
            if (value == ((1u << 30u) - 1u)) continue;
            uint tag = value >> 30u, index = value & 0x3fffffffu;
            if (tag == 1u && index < table_size) {
                atomic_fetch_add_explicit(&arena[destination_offsets[destination + relation] + index], 1u, memory_order_relaxed);
            } else if (tag == 0u && index < e[12]) {
                atomic_fetch_add_explicit(&arena[destination_offsets[e[13] + relation] + index], 1u, memory_order_relaxed);
            }
            continue;
        }
        if (kind == 2u) {
            uint bits = e[2], mask = (1u << bits) - 1u;
            uint a = ((device const uint *)arena)[source_offsets[word_base] + row];
            uint b = ((device const uint *)arena)[source_offsets[word_base + 1u] + row];
            uint c = ((device const uint *)arena)[source_offsets[word_base + 2u] + row];
            if ((a | b | c) > mask || c != (a ^ b)) continue;
            uint index = luts[lut_offset + (a << bits) + b];
            if (index < table_size) atomic_fetch_add_explicit(&arena[destination_offsets[destination + relation] + index], 1u, memory_order_relaxed);
            continue;
        }
        if (kind == 3u) {
            uint a = ((device const uint *)arena)[source_offsets[word_base] + row];
            uint b = ((device const uint *)arena)[source_offsets[word_base + 1u] + row];
            uint c = ((device const uint *)arena)[source_offsets[word_base + 2u] + row];
            if ((a | b | c) >= (1u << 12u) || c != (a ^ b)) continue;
            uint column = ((a >> 10u) << 2u) | (b >> 10u);
            uint index = ((a & 0x3ffu) << 10u) | (b & 0x3ffu);
            if (index < table_size) atomic_fetch_add_explicit(&arena[destination_offsets[destination + column] + index], 1u, memory_order_relaxed);
            continue;
        }
        uint key = 0u;
        for (uint word = 0; word < n_words; ++word) {
            key = (key << e[2u + word]) | ((device const uint *)arena)[source_offsets[word_base + word] + row];
        }
        long keyed = (long)key + (long)(int)e[12];
        if (keyed < 0 || (ulong)keyed >= table_size) continue;
        uint index = lut_offset == 0xffffffffu ? (uint)keyed : luts[lut_offset + (uint)keyed];
        if (index < table_size) atomic_fetch_add_explicit(&arena[destination_offsets[destination + relation] + index], 1u, memory_order_relaxed);
    }
}

kernel void stwo_zig_clear_arena_ranges(
    device uint *arena [[buffer(0)]],
    device const uint2 *ranges [[buffer(1)]],
    constant uint &range_count [[buffer(2)]],
    constant uint &max_length [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.y >= range_count || position.x >= max_length) return;
    uint2 range = ranges[position.y];
    if (position.x < range.y) arena[range.x + position.x] = 0u;
}

// Prepared feeds flatten variable-sized clear ranges into exact linear work.
// Each span is {arena_offset, length, linear_prefix}; binary search avoids the
// rectangular max_length * range_count over-dispatch used by the generic API.
kernel void stwo_zig_clear_arena_spans(
    device uint *arena [[buffer(0)]],
    device const uint *spans [[buffer(1)]],
    constant uint &span_count [[buffer(2)]],
    constant uint &total_words [[buffer(3)]],
    uint position [[thread_position_in_grid]]
) {
    if (position >= total_words) return;
    uint low = 0u, high = span_count;
    while (low + 1u < high) {
        uint middle = low + (high - low) / 2u;
        if (spans[middle * 3u + 2u] <= position) low = middle;
        else high = middle;
    }
    uint base = low * 3u;
    uint local = position - spans[base + 2u];
    if (local < spans[base + 1u]) arena[spans[base] + local] = 0u;
}

kernel void stwo_zig_compact_gather(
    device uint *arena [[buffer(0)]], device const uint *source_offsets [[buffer(1)]],
    device const uint *descriptors [[buffer(2)]], constant uint *params [[buffer(3)]],
    uint row [[thread_position_in_grid]]
) {
    uint edge_count = params[0], tuple_words = params[1], total_rows = params[2];
    uint sort_rows = params[3], tuples_offset = params[4], indices_offset = params[5];
    if (row >= sort_rows) return;
    if (row == 0u) arena[params[13]] = 0u;
    arena[indices_offset + row] = row;
    if (row >= total_rows) {
        for (uint word = 0; word < tuple_words; ++word)
            arena[tuples_offset + row * tuple_words + word] = 0xffffffffu;
        return;
    }
    for (uint edge = 0; edge < edge_count; ++edge) {
        uint base = edge * 5u, producer_rows = descriptors[base];
        uint edge_rows = producer_rows * descriptors[base + 3u];
        uint destination = descriptors[base + 4u];
        if (row < destination || row >= destination + edge_rows) continue;
        uint local = row - destination;
        uint instance = local / producer_rows, producer_row = local % producer_rows;
        for (uint word = 0; word < tuple_words; ++word) {
            uint source_word = descriptors[base + 1u] + instance * descriptors[base + 2u] + word;
            arena[tuples_offset + row * tuple_words + word] =
                arena[source_offsets[edge] + source_word * producer_rows + producer_row];
        }
        return;
    }
}

kernel void stwo_zig_compact_radix_histogram(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]],
    constant uint &word [[buffer(2)]], constant uint &shift [[buffer(3)]],
    constant uint &indices_offset [[buffer(4)]],
    uint row [[thread_position_in_grid]], uint lane [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]]
) {
    threadgroup atomic_uint counts[16];
    if (lane < 16u) atomic_store_explicit(&counts[lane], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint tuple_words = params[1], sort_rows = params[3], tuples_offset = params[4];
    uint counts_offset = params[7];
    if (row < sort_rows) {
        uint source = arena[indices_offset + row];
        uint digit = (arena[tuples_offset + source * tuple_words + word] >> shift) & 15u;
        atomic_fetch_add_explicit(&counts[digit], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane < 16u) arena[counts_offset + group * 16u + lane] = atomic_load_explicit(&counts[lane], memory_order_relaxed);
}

kernel void stwo_zig_compact_radix_prefix(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]],
    constant uint &block_count [[buffer(2)]], uint digit [[thread_index_in_threadgroup]]
) {
    threadgroup uint totals[16];
    uint counts_offset = params[7], offsets_offset = params[8], bases_offset = params[9];
    if (digit < 16u) {
        uint sum = 0u;
        for (uint block = 0; block < block_count; ++block) {
            uint index = block * 16u + digit;
            arena[offsets_offset + index] = sum;
            sum += arena[counts_offset + index];
        }
        totals[digit] = sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (digit == 0u) {
        uint sum = 0u;
        for (uint value = 0; value < 16u; ++value) {
            arena[bases_offset + value] = sum;
            sum += totals[value];
        }
    }
}

kernel void stwo_zig_compact_radix_scatter(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]],
    constant uint &word [[buffer(2)]], constant uint &shift [[buffer(3)]],
    constant uint &source_indices [[buffer(4)]], constant uint &destination_indices [[buffer(5)]],
    uint row [[thread_position_in_grid]], uint lane [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]], uint simd_lane [[thread_index_in_simdgroup]],
    uint simd_group [[simdgroup_index_in_threadgroup]], uint group_width [[threads_per_threadgroup]]
) {
    threadgroup uint subgroup_counts[8][16];
    uint tuple_words = params[1], tuples_offset = params[4];
    uint offsets_offset = params[8], bases_offset = params[9];
    uint source = arena[source_indices + row];
    uint digit = (arena[tuples_offset + source * tuple_words + word] >> shift) & 15u;
    uint local_rank = 0u;
    for (uint value = 0; value < 16u; ++value) {
        uint present = digit == value ? 1u : 0u;
        uint rank = simd_prefix_exclusive_sum(present);
        uint count = simd_sum(present);
        if (simd_lane == 0u) subgroup_counts[simd_group][value] = count;
        if (digit == value) local_rank = rank;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint preceding = 0u;
    for (uint subgroup = 0; subgroup < simd_group; ++subgroup) preceding += subgroup_counts[subgroup][digit];
    uint destination = arena[bases_offset + digit] + arena[offsets_offset + group * 16u + digit] + preceding + local_rank;
    arena[destination_indices + destination] = source;
}

inline bool compact_tuple_equal(
    device uint *arena, uint tuples_offset, uint tuple_words, uint lhs, uint rhs
) {
    for (uint word = 0; word < tuple_words; ++word)
        if (arena[tuples_offset + lhs * tuple_words + word] != arena[tuples_offset + rhs * tuple_words + word]) return false;
    return true;
}

inline bool compact_key_equal(
    device uint *arena, uint tuples_offset, uint tuple_words, uint key_words, uint lhs, uint rhs
) {
    for (uint word = 0; word < key_words; ++word)
        if (arena[tuples_offset + lhs * tuple_words + word] != arena[tuples_offset + rhs * tuple_words + word]) return false;
    return true;
}

kernel void stwo_zig_compact_heads(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]], uint row [[thread_position_in_grid]]
) {
    uint tuple_words = params[1], total_rows = params[2], sort_rows = params[3];
    uint tuples_offset = params[4], indices_offset = params[5], heads_offset = params[10];
    uint error_offset = params[13], key_words = params[14];
    if (row >= sort_rows) return;
    if (row >= total_rows) { arena[heads_offset + row] = 0u; return; }
    if (row == 0u) { arena[heads_offset] = 1u; return; }
    uint current = arena[indices_offset + row], previous = arena[indices_offset + row - 1u];
    bool same_tuple = compact_tuple_equal(arena, tuples_offset, tuple_words, current, previous);
    if (!same_tuple && compact_key_equal(arena, tuples_offset, tuple_words, key_words, current, previous))
        atomic_store_explicit((device atomic_uint *)&arena[error_offset], 1u, memory_order_relaxed);
    arena[heads_offset + row] = same_tuple ? 0u : 1u;
}

kernel void stwo_zig_compact_scan_local(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]],
    uint row [[thread_position_in_grid]], uint lane [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]], uint group_width [[threads_per_threadgroup]]
) {
    threadgroup uint values[256];
    uint sort_rows = params[3], heads_offset = params[10], positions_offset = params[11];
    uint block_sums_offset = params[12];
    values[lane] = row < sort_rows ? arena[heads_offset + row] : 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 1u; stride < group_width; stride <<= 1u) {
        uint addend = lane >= stride ? values[lane - stride] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        values[lane] += addend;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row < sort_rows) arena[positions_offset + row] = values[lane];
    if (lane + 1u == group_width) arena[block_sums_offset + group] = values[lane];
}

kernel void stwo_zig_compact_scan_blocks(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]],
    constant uint &block_count [[buffer(2)]], uint row [[thread_position_in_grid]]
) {
    if (row != 0u) return;
    uint block_sums_offset = params[12], sum = 0u;
    for (uint block = 0; block < block_count; ++block) {
        uint value = arena[block_sums_offset + block];
        arena[block_sums_offset + block] = sum;
        sum += value;
    }
}

kernel void stwo_zig_compact_scan_add(
    device uint *arena [[buffer(0)]], constant uint *params [[buffer(1)]],
    uint row [[thread_position_in_grid]], uint group [[threadgroup_position_in_grid]]
) {
    if (row < params[3]) arena[params[11] + row] += arena[params[12] + group];
}

kernel void stwo_zig_compact_clear_outputs(
    device uint *arena [[buffer(0)]], device const uint *output_offsets [[buffer(1)]],
    constant uint *params [[buffer(2)]], uint row [[thread_position_in_grid]]
) {
    uint input_count = params[15], consumer_rows = params[16];
    if (row >= consumer_rows) return;
    for (uint input = 0; input < input_count; ++input) arena[output_offsets[input] + row] = 0u;
}

kernel void stwo_zig_compact_scatter(
    device uint *arena [[buffer(0)]], device const uint *output_offsets [[buffer(1)]],
    constant uint *params [[buffer(2)]], uint row [[thread_position_in_grid]]
) {
    uint tuple_words = params[1], total_rows = params[2];
    if (row >= total_rows) return;
    uint tuples_offset = params[4], indices_offset = params[5], heads_offset = params[10];
    uint positions_offset = params[11], multiplicity_slot = params[19];
    uint compact_row = arena[positions_offset + row] - 1u;
    if (arena[heads_offset + row] != 0u) {
        uint source = arena[indices_offset + row];
        for (uint word = 0; word < tuple_words; ++word)
            arena[output_offsets[word] + compact_row] = arena[tuples_offset + source * tuple_words + word];
    }
    atomic_fetch_add_explicit((device atomic_uint *)&arena[output_offsets[multiplicity_slot] + compact_row], 1u, memory_order_relaxed);
}

kernel void stwo_zig_compact_finalize(
    device uint *arena [[buffer(0)]], device const uint *output_offsets [[buffer(1)]],
    constant uint *params [[buffer(2)]], uint row [[thread_position_in_grid]]
) {
    uint tuple_words = params[1], total_rows = params[2], positions_offset = params[11];
    uint error_offset = params[13], consumer_rows = params[16], unique_offset = params[17];
    uint enabler_slot = params[18], multiplicity_slot = params[19], iota_slot = params[20];
    uint unique = arena[positions_offset + total_rows - 1u];
    uint expected = unique < 16u ? 16u : 1u << (32u - clz(unique - 1u));
    bool invalid = arena[error_offset] != 0u || unique == 0u || unique > consumer_rows || expected != consumer_rows;
    if (row == 0u) arena[unique_offset] = invalid ? 0xffffffffu : unique;
    if (row >= consumer_rows || invalid) return;
    if (row >= unique) {
        for (uint word = 0; word < tuple_words; ++word)
            arena[output_offsets[word] + row] = arena[output_offsets[word]];
        arena[output_offsets[multiplicity_slot] + row] = 0u;
    }
    if (enabler_slot != 0xffffffffu) arena[output_offsets[enabler_slot] + row] = row < unique ? 1u : 0u;
    if (iota_slot != 0xffffffffu) arena[output_offsets[iota_slot] + row] = row;
}

kernel void stwo_zig_fri_fold_circle(
    device const uint *source [[buffer(0)]],
    device const uint *inverse_y [[buffer(1)]],
    constant Qm31Value &alpha [[buffer(2)]],
    device Qm31Value *destination [[buffer(3)]],
    constant uint &destination_count [[buffer(4)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= destination_count) return;
    uint source_count = destination_count << 1u;
    uint left = index << 1u;
    uint right = left + 1u;
    Qm31Value f0 = { source[left], source[source_count + left],
                     source[2u * source_count + left], source[3u * source_count + left] };
    Qm31Value f1 = { source[right], source[source_count + right],
                     source[2u * source_count + right], source[3u * source_count + right] };
    Qm31Value sum = qm_add(f0, f1);
    Qm31Value difference = qm_mul_m31(qm_sub(f0, f1), inverse_y[index]);
    destination[index] = qm_add(sum, qm_mul(alpha, difference));
}

kernel void stwo_zig_fri_fold_line(
    device const Qm31Value *source [[buffer(0)]],
    device const uint *inverse_x [[buffer(1)]],
    constant Qm31Value &alpha [[buffer(2)]],
    device Qm31Value *destination [[buffer(3)]],
    constant uint &destination_count [[buffer(4)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= destination_count) return;
    Qm31Value f0 = source[index << 1u];
    Qm31Value f1 = source[(index << 1u) + 1u];
    destination[index] = qm_add(qm_add(f0, f1), qm_mul(alpha, qm_mul_m31(qm_sub(f0, f1), inverse_x[index])));
}

kernel void stwo_zig_qm31_to_coordinates(
    device const Qm31Value *source [[buffer(0)]],
    device uint *destination [[buffer(1)]],
    constant uint &value_count [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= value_count) return;
    Qm31Value value = source[index];
    destination[index] = value.a;
    destination[value_count + index] = value.b;
    destination[2u * value_count + index] = value.c;
    destination[3u * value_count + index] = value.d;
}

kernel void stwo_zig_quotient_rows(
    device const uint *flat_views [[buffer(0)]],
    device const QuotientView *views [[buffer(1)]],
    constant uint &view_count [[buffer(2)]],
    device const uint *sample_components [[buffer(3)]],
    device const uint *linear_terms [[buffer(4)]],
    constant uint &batch_count [[buffer(5)]],
    device const uint *domain_x [[buffer(6)]],
    device const uint *domain_y [[buffer(7)]],
    device uint *output [[buffer(8)]],
    constant uint &row_count [[buffer(9)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    Qm31Value accumulator = { 0u, 0u, 0u, 0u };
    for (uint batch = 0; batch < batch_count; ++batch) {
        Qm31Value numerator_sum = { 0u, 0u, 0u, 0u };
        for (uint view_index = 0; view_index < view_count; ++view_index) {
            QuotientView view = views[view_index];
            if (view.batch != batch) continue;
            uint source = view.direct != 0u
                ? row
                : ((row >> view.shift) << 1u) | (row & 1u);
            uint base = view.offset + source;
            Qm31Value value = {
                flat_views[base],
                flat_views[base + view.length],
                flat_views[base + 2u * view.length],
                flat_views[base + 3u * view.length],
            };
            numerator_sum = qm_add(numerator_sum, value);
        }

        uint sample_base = batch * 8u;
        Cm31Value prx = { sample_components[sample_base], sample_components[sample_base + 1u] };
        Cm31Value pry = { sample_components[sample_base + 2u], sample_components[sample_base + 3u] };
        Cm31Value pix = { sample_components[sample_base + 4u], sample_components[sample_base + 5u] };
        Cm31Value piy = { sample_components[sample_base + 6u], sample_components[sample_base + 7u] };
        Cm31Value dx = { domain_x[row], 0u };
        Cm31Value dy = { domain_y[row], 0u };
        Cm31Value denominator = cm_sub(cm_mul(cm_sub(prx, dx), piy), cm_mul(cm_sub(pry, dy), pix));
        Cm31Value denominator_inverse = cm_inv(denominator);

        uint linear_base = batch * 8u;
        Qm31Value sum_a = { linear_terms[linear_base], linear_terms[linear_base + 1u],
                            linear_terms[linear_base + 2u], linear_terms[linear_base + 3u] };
        Qm31Value sum_b = { linear_terms[linear_base + 4u], linear_terms[linear_base + 5u],
                            linear_terms[linear_base + 6u], linear_terms[linear_base + 7u] };
        Qm31Value numerator = qm_sub(numerator_sum, qm_add(qm_mul_m31(sum_a, domain_y[row]), sum_b));
        accumulator = qm_add(accumulator, qm_mul_cm(numerator, denominator_inverse));
    }
    output[row] = accumulator.a;
    output[row_count + row] = accumulator.b;
    output[2u * row_count + row] = accumulator.c;
    output[3u * row_count + row] = accumulator.d;
}

kernel void stwo_zig_quotient_rows_raw(
    device const uint *flat_columns [[buffer(0)]],
    device const RawQuotientView *views [[buffer(1)]],
    constant uint &view_count [[buffer(2)]],
    device const uint *sample_components [[buffer(3)]],
    device const uint *linear_terms [[buffer(4)]],
    constant uint &batch_count [[buffer(5)]],
    device const uint *domain_x [[buffer(6)]],
    device const uint *domain_y [[buffer(7)]],
    device uint *output [[buffer(8)]],
    constant uint &row_count [[buffer(9)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    Qm31Value accumulator = { 0u, 0u, 0u, 0u };
    for (uint batch = 0; batch < batch_count; ++batch) {
        Qm31Value numerator_sum = { 0u, 0u, 0u, 0u };
        for (uint view_index = 0; view_index < view_count; ++view_index) {
            RawQuotientView view = views[view_index];
            if (view.batch != batch) continue;
            uint source = view.direct != 0u
                ? row
                : ((row >> view.shift) << 1u) | (row & 1u);
            uint value = flat_columns[view.offset + source];
            numerator_sum = qm_add(numerator_sum, {
                m31_mul(value, view.coeff_a), m31_mul(value, view.coeff_b),
                m31_mul(value, view.coeff_c), m31_mul(value, view.coeff_d),
            });
        }

        uint sample_base = batch * 8u;
        Cm31Value prx = { sample_components[sample_base], sample_components[sample_base + 1u] };
        Cm31Value pry = { sample_components[sample_base + 2u], sample_components[sample_base + 3u] };
        Cm31Value pix = { sample_components[sample_base + 4u], sample_components[sample_base + 5u] };
        Cm31Value piy = { sample_components[sample_base + 6u], sample_components[sample_base + 7u] };
        Cm31Value denominator = cm_sub(
            cm_mul(cm_sub(prx, { domain_x[row], 0u }), piy),
            cm_mul(cm_sub(pry, { domain_y[row], 0u }), pix)
        );
        Cm31Value denominator_inverse = cm_inv(denominator);
        uint linear_base = batch * 8u;
        Qm31Value sum_a = { linear_terms[linear_base], linear_terms[linear_base + 1u],
                            linear_terms[linear_base + 2u], linear_terms[linear_base + 3u] };
        Qm31Value sum_b = { linear_terms[linear_base + 4u], linear_terms[linear_base + 5u],
                            linear_terms[linear_base + 6u], linear_terms[linear_base + 7u] };
        Qm31Value numerator = qm_sub(numerator_sum, qm_add(qm_mul_m31(sum_a, domain_y[row]), sum_b));
        accumulator = qm_add(accumulator, qm_mul_cm(numerator, denominator_inverse));
    }
    output[row] = accumulator.a;
    output[row_count + row] = accumulator.b;
    output[2u * row_count + row] = accumulator.c;
    output[3u * row_count + row] = accumulator.d;
}

kernel void stwo_zig_quotient_numerator_raw(
    device const uint *flat_columns [[buffer(0)]],
    device const RawQuotientView *views [[buffer(1)]],
    constant uint &view_count [[buffer(2)]],
    device Qm31Value *numerators [[buffer(3)]],
    constant uint &batch_count [[buffer(4)]],
    constant uint &row_count [[buffer(5)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    for (uint batch = 0; batch < batch_count; ++batch) {
        Qm31Value sum = numerators[batch * row_count + row];
        for (uint view_index = 0; view_index < view_count; ++view_index) {
            RawQuotientView view = views[view_index];
            if (view.batch != batch) continue;
            uint source = view.direct != 0u
                ? row
                : ((row >> view.shift) << 1u) | (row & 1u);
            uint value = flat_columns[view.offset + source];
            sum = qm_add(sum, {
                m31_mul(value, view.coeff_a), m31_mul(value, view.coeff_b),
                m31_mul(value, view.coeff_c), m31_mul(value, view.coeff_d),
            });
        }
        numerators[batch * row_count + row] = sum;
    }
}

kernel void stwo_zig_quotient_finalize(
    device const Qm31Value *numerators [[buffer(0)]],
    device const uint *sample_components [[buffer(1)]],
    device const uint *linear_terms [[buffer(2)]],
    constant uint &batch_count [[buffer(3)]],
    device const uint *domain_x [[buffer(4)]],
    device const uint *domain_y [[buffer(5)]],
    device uint *output [[buffer(6)]],
    constant uint &row_count [[buffer(7)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    Qm31Value accumulator = { 0u, 0u, 0u, 0u };
    for (uint batch = 0; batch < batch_count; ++batch) {
        uint sample_base = batch * 8u;
        Cm31Value prx = { sample_components[sample_base], sample_components[sample_base + 1u] };
        Cm31Value pry = { sample_components[sample_base + 2u], sample_components[sample_base + 3u] };
        Cm31Value pix = { sample_components[sample_base + 4u], sample_components[sample_base + 5u] };
        Cm31Value piy = { sample_components[sample_base + 6u], sample_components[sample_base + 7u] };
        Cm31Value denominator = cm_sub(
            cm_mul(cm_sub(prx, { domain_x[row], 0u }), piy),
            cm_mul(cm_sub(pry, { domain_y[row], 0u }), pix)
        );
        uint linear_base = batch * 8u;
        Qm31Value sum_a = { linear_terms[linear_base], linear_terms[linear_base + 1u],
                            linear_terms[linear_base + 2u], linear_terms[linear_base + 3u] };
        Qm31Value sum_b = { linear_terms[linear_base + 4u], linear_terms[linear_base + 5u],
                            linear_terms[linear_base + 6u], linear_terms[linear_base + 7u] };
        Qm31Value numerator = qm_sub(
            numerators[batch * row_count + row],
            qm_add(qm_mul_m31(sum_a, domain_y[row]), sum_b)
        );
        accumulator = qm_add(accumulator, qm_mul_cm(numerator, cm_inv(denominator)));
    }
    output[row] = accumulator.a;
    output[row_count + row] = accumulator.b;
    output[2u * row_count + row] = accumulator.c;
    output[3u * row_count + row] = accumulator.d;
}

struct PolynomialEvalTask {
    uint coefficient_offset, coefficient_length, basis_offset, log_size, output_index;
};

struct PolynomialBasisTask {
    uint factor_offset, log_size, basis_offset, basis_length;
};

kernel void stwo_zig_eval_basis(
    device const uint *factors [[buffer(0)]],
    device const PolynomialBasisTask *tasks [[buffer(1)]],
    constant uint &task_count [[buffer(2)]],
    device Qm31Value *basis [[buffer(3)]],
    uint lane [[thread_index_in_threadgroup]],
    uint group_width [[threads_per_threadgroup]],
    uint task_index [[threadgroup_position_in_grid]]
) {
    if (task_index >= task_count) return;
    PolynomialBasisTask task = tasks[task_index];
    for (uint coefficient_index = lane; coefficient_index < task.basis_length; coefficient_index += group_width) {
        Qm31Value value = { 1u, 0u, 0u, 0u };
        uint bits = coefficient_index;
        for (uint bit = 0; bit < task.log_size && bits != 0u; ++bit) {
            if ((bits & 1u) != 0u) {
                uint factor_base = task.factor_offset + bit * 4u;
                Qm31Value factor = { factors[factor_base], factors[factor_base + 1u],
                                     factors[factor_base + 2u], factors[factor_base + 3u] };
                value = qm_mul(value, factor);
            }
            bits >>= 1u;
        }
        basis[task.basis_offset + coefficient_index] = value;
    }
}

kernel void stwo_zig_eval_polynomials(
    device const uint *coefficients [[buffer(0)]],
    device const Qm31Value *basis [[buffer(1)]],
    device const PolynomialEvalTask *tasks [[buffer(2)]],
    constant uint &task_count [[buffer(3)]],
    device uint *output [[buffer(4)]],
    uint lane [[thread_index_in_threadgroup]],
    uint group_width [[threads_per_threadgroup]],
    uint task_index [[threadgroup_position_in_grid]]
) {
    if (task_index >= task_count) return;
    PolynomialEvalTask task = tasks[task_index];
    Qm31Value partial_value = { 0u, 0u, 0u, 0u };
    for (uint coefficient_index = lane; coefficient_index < task.coefficient_length; coefficient_index += group_width) {
        partial_value = qm_add(
            partial_value,
            qm_mul_m31(basis[task.basis_offset + coefficient_index],
                       coefficients[task.coefficient_offset + coefficient_index])
        );
    }
    threadgroup Qm31Value partials[256];
    partials[lane] = partial_value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = group_width >> 1u; stride != 0u; stride >>= 1u) {
        if (lane < stride) partials[lane] = qm_add(partials[lane], partials[lane + stride]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0u) {
        uint output_base = task.output_index * 4u;
        output[output_base] = partials[0].a;
        output[output_base + 1u] = partials[0].b;
        output[output_base + 2u] = partials[0].c;
        output[output_base + 3u] = partials[0].d;
    }
}
