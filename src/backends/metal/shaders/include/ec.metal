#ifndef STWO_ZIG_EC_METAL
#define STWO_ZIG_EC_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/felt252.metal"
#endif
struct EcPointMetal { Felt252Metal x; Felt252Metal y; };

inline Felt252Metal ec_felt_inverse_252(thread const Felt252Metal &value) {
    Felt252Metal result = felt_one_montgomery();
    for (int bit = 251; bit >= 0; --bit) {
        result = felt_mont_square(result);
        if (bit < 192 || bit == 196 || bit == 251) result = felt_mont_mul(result, value);
    }
    return result;
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
    if (lookup == 0xffffffffu) return;
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

struct EcProjectiveMetal { Felt252Metal x; Felt252Metal y; Felt252Metal z; };

inline EcProjectiveMetal ec_projective_from_affine(thread const EcPointMetal &point) {
    EcProjectiveMetal result = { point.x, point.y, felt_one_montgomery() };
    return result;
}

inline EcProjectiveMetal ec_projective_double(thread const EcProjectiveMetal &point) {
    Felt252Metal xx = felt_mont_square(point.x);
    Felt252Metal yy = felt_mont_square(point.y);
    Felt252Metal yyyy = felt_mont_square(yy);
    Felt252Metal zz = felt_mont_square(point.z);
    Felt252Metal x_plus_yy = felt_add_252(point.x, yy);
    Felt252Metal s = felt_sub_252(felt_sub_252(felt_mont_square(x_plus_yy), xx), yyyy);
    s = felt_add_252(s, s);
    Felt252Metal m = felt_add_252(felt_add_252(xx, xx), xx);
    m = felt_add_252(m, felt_mont_square(zz));
    Felt252Metal x = felt_sub_252(felt_mont_square(m), felt_add_252(s, s));
    Felt252Metal eight_yyyy = felt_add_252(yyyy, yyyy);
    eight_yyyy = felt_add_252(eight_yyyy, eight_yyyy);
    eight_yyyy = felt_add_252(eight_yyyy, eight_yyyy);
    Felt252Metal y = felt_sub_252(felt_mont_mul(m, felt_sub_252(s, x)), eight_yyyy);
    Felt252Metal z = felt_mont_mul(felt_add_252(point.y, point.y), point.z);
    EcProjectiveMetal result = { x, y, z };
    return result;
}

inline EcProjectiveMetal ec_projective_add(
    thread const EcProjectiveMetal &left,
    thread const EcProjectiveMetal &right
) {
    Felt252Metal z1z1 = felt_mont_square(left.z);
    Felt252Metal z2z2 = felt_mont_square(right.z);
    Felt252Metal u1 = felt_mont_mul(left.x, z2z2);
    Felt252Metal u2 = felt_mont_mul(right.x, z1z1);
    Felt252Metal s1 = felt_mont_mul(left.y, felt_mont_mul(right.z, z2z2));
    Felt252Metal s2 = felt_mont_mul(right.y, felt_mont_mul(left.z, z1z1));
    if (felt_equal_252(u1, u2) && felt_equal_252(s1, s2)) return ec_projective_double(left);
    Felt252Metal h = felt_sub_252(u2, u1);
    Felt252Metal two_h = felt_add_252(h, h);
    Felt252Metal i = felt_mont_square(two_h);
    Felt252Metal j = felt_mont_mul(h, i);
    Felt252Metal r = felt_add_252(felt_sub_252(s2, s1), felt_sub_252(s2, s1));
    Felt252Metal v = felt_mont_mul(u1, i);
    Felt252Metal x = felt_sub_252(felt_sub_252(felt_mont_square(r), j), felt_add_252(v, v));
    Felt252Metal y = felt_sub_252(
        felt_mont_mul(r, felt_sub_252(v, x)),
        felt_mont_mul(felt_add_252(s1, s1), j)
    );
    Felt252Metal z_sum = felt_add_252(left.z, right.z);
    Felt252Metal z = felt_mont_mul(
        felt_sub_252(felt_sub_252(felt_mont_square(z_sum), z1z1), z2z2),
        h
    );
    EcProjectiveMetal result = { x, y, z };
    return result;
}

inline EcPointMetal ec_projective_to_affine(
    thread const EcProjectiveMetal &point,
    thread const Felt252Metal &z_inverse
) {
    Felt252Metal inverse_squared = felt_mont_square(z_inverse);
    EcPointMetal result;
    result.x = felt_mont_mul(point.x, inverse_squared);
    result.y = felt_mont_mul(point.y, felt_mont_mul(inverse_squared, z_inverse));
    return result;
}

#endif
