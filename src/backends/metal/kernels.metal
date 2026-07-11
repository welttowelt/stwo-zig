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

struct Qm31Value { uint a, b, c, d; };
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
    uint output_base = row * 4u;
    output[output_base] = accumulator.a;
    output[output_base + 1u] = accumulator.b;
    output[output_base + 2u] = accumulator.c;
    output[output_base + 3u] = accumulator.d;
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
    uint output_base = row * 4u;
    output[output_base] = accumulator.a;
    output[output_base + 1u] = accumulator.b;
    output[output_base + 2u] = accumulator.c;
    output[output_base + 3u] = accumulator.d;
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
    uint output_base = row * 4u;
    output[output_base] = accumulator.a;
    output[output_base + 1u] = accumulator.b;
    output[output_base + 2u] = accumulator.c;
    output[output_base + 3u] = accumulator.d;
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
