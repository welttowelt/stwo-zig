#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/circle.metal"
#endif

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
    uint lhs = m31_reduce(values[idx0]);
    uint rhs = m31_reduce(values[idx1]);
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
    device uint *coefficients [[buffer(0)]],
    device uint *extended [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    device const uint *source_offsets [[buffer(3)]],
    device const uint *destination_offsets [[buffer(4)]],
    constant uint &base_log_size [[buffer(5)]],
    constant uint &extended_log_size [[buffer(6)]],
    constant uint &column_count [[buffer(7)]],
    constant uint &scale_factor [[buffer(8)]],
    constant uint &fuse_top_two [[buffer(9)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint extended_len = 1u << extended_log_size;
    uint base_len = 1u << base_log_size;
    if (position.y >= column_count) return;
    uint coefficient_base = source_offsets[position.y];
    uint output_base = destination_offsets[position.y];
    if (fuse_top_two != 0u) {
        uint half_len = base_len >> 1u;
        if (position.x >= half_len) return;
        uint lhs = m31_mul(coefficients[coefficient_base + position.x], scale_factor);
        uint rhs = m31_mul(coefficients[coefficient_base + half_len + position.x], scale_factor);
        coefficients[coefficient_base + position.x] = lhs;
        coefficients[coefficient_base + half_len + position.x] = rhs;

        uint pair_count = extended_len >> 1u;
        uint twiddle_offset = pair_count - 4u;
        uint product0 = m31_mul(rhs, twiddles[twiddle_offset]);
        uint product1 = m31_mul(rhs, twiddles[twiddle_offset + 1u]);
        extended[output_base + position.x] = m31_add(lhs, product0);
        extended[output_base + half_len + position.x] = m31_sub(lhs, product0);
        extended[output_base + base_len + position.x] = m31_add(lhs, product1);
        extended[output_base + base_len + half_len + position.x] = m31_sub(lhs, product1);
        return;
    }
    if (position.x >= extended_len) return;
    uint value = position.x < base_len
        ? coefficients[coefficient_base + position.x]
        : 0u;
    extended[output_base + position.x] = value;
}

kernel void stwo_zig_circle_expand_sparse(
    device uint *arena [[buffer(0)]],
    device const ulong *source_offsets [[buffer(1)]],
    device const ulong *destination_offsets [[buffer(2)]],
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

kernel void stwo_zig_circle_copy_sparse(
    device uint *arena [[buffer(0)]], device const ulong *source_offsets [[buffer(1)]],
    device const ulong *destination_offsets [[buffer(2)]], constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]], uint2 position [[thread_position_in_grid]]
) {
    uint length = 1u << log_size;
    if (position.x < length && position.y < column_count)
        arena[destination_offsets[position.y] + position.x] = arena[source_offsets[position.y] + position.x];
}

kernel void stwo_zig_circle_ifft_first_sparse(
    device uint *arena [[buffer(0)]], device const ulong *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]], constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]], uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    ulong idx0 = destination_offsets[position.y] + (position.x << 1u), idx1 = idx0 + 1u;
    // Relation columns may carry lazy M31 representatives above p. Normalize
    // once at the transform boundary; every following butterfly is canonical.
    uint lhs = m31_reduce(arena[idx0]), rhs = m31_reduce(arena[idx1]);
    arena[idx0] = m31_add(lhs, rhs);
    arena[idx1] = m31_mul(m31_sub(lhs, rhs), circle_twiddle(twiddles, position.x));
}

kernel void stwo_zig_circle_ifft_layer_sparse(
    device uint *arena [[buffer(0)]], device const ulong *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]], constant uint &log_size [[buffer(3)]],
    constant uint &layer [[buffer(4)]], constant uint &twiddle_offset [[buffer(5)]],
    constant uint &column_count [[buffer(6)]], uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    uint polynomial_count = 1u << layer;
    uint twiddle_index = position.x >> layer, lane = position.x & (polynomial_count - 1u);
    ulong base = destination_offsets[position.y] + (twiddle_index << (layer + 1u));
    ulong idx0 = base + lane, idx1 = idx0 + polynomial_count;
    uint lhs = arena[idx0], rhs = arena[idx1];
    arena[idx0] = m31_add(lhs, rhs);
    arena[idx1] = m31_mul(m31_sub(lhs, rhs), twiddles[twiddle_offset + twiddle_index]);
}

kernel void stwo_zig_circle_rescale_sparse(
    device uint *arena [[buffer(0)]], device const ulong *destination_offsets [[buffer(1)]],
    constant uint &log_size [[buffer(2)]], constant uint &column_count [[buffer(3)]],
    constant uint &factor [[buffer(4)]], uint2 position [[thread_position_in_grid]]
) {
    uint length = 1u << log_size;
    if (position.x < length && position.y < column_count) {
        ulong index = destination_offsets[position.y] + position.x;
        arena[index] = m31_mul(arena[index], factor);
    }
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

// Composes two, three, or four adjacent layers. Bits 29 and 30 select the
// sixteen- and eight-value schedules; bit 31 selects inverse order. Each
// thread owns the complete radix tuple, so intermediates remain in registers
// and never need a device-wide barrier or another full-arena pass.
kernel void stwo_zig_circle_rfft_radix4_sparse(
    device uint *arena [[buffer(0)]],
    device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &layer [[buffer(4)]],
    constant uint &column_count [[buffer(5)]],
    uint2 position [[thread_position_in_grid]]
) {
    bool radix16 = (layer & 0x20000000u) != 0u;
    bool radix8 = (layer & 0x40000000u) != 0u;
    uint radix_log = radix16 ? 4u : (radix8 ? 3u : 2u);
    uint tuple_count = 1u << (log_size - radix_log);
    uint stage = layer & 0x1fffffffu;
    bool inverse = (layer & 0x80000000u) != 0u;
    if (position.x >= tuple_count || position.y >= column_count ||
        (!inverse && stage + 1u < radix_log) ||
        (inverse && stage + radix_log > log_size)) return;

    uint pair_count = 1u << (log_size - 1u);
    if (radix16) {
        uint indices[16];
        uint values[16];
        uint lowest_stage = inverse ? stage : stage - 3u;
        uint distance = 1u << lowest_stage;
        uint group = position.x >> lowest_stage;
        uint lane = position.x & (distance - 1u);
        uint base = destination_offsets[position.y] + (group << (lowest_stage + 4u));
        for (uint item = 0u; item < 16u; ++item) {
            indices[item] = base + lane + item * distance;
            values[item] = arena[indices[item]];
        }

        for (uint step = 0u; step < 4u; ++step) {
            uint substage = inverse ? stage + step : stage - step;
            uint half_span = inverse ? (1u << step) : (8u >> step);
            uint block_count = 8u / half_span;
            uint twiddle_offset = pair_count - (1u << (log_size - substage));
            for (uint block = 0u; block < block_count; ++block) {
                uint twiddle = twiddles[twiddle_offset + group * block_count + block];
                uint block_start = block * (half_span << 1u);
                for (uint item = 0u; item < half_span; ++item) {
                    uint lo = block_start + item, hi = lo + half_span;
                    uint lhs = values[lo], rhs = values[hi];
                    if (inverse) {
                        values[lo] = m31_add(lhs, rhs);
                        values[hi] = m31_mul(m31_sub(lhs, rhs), twiddle);
                    } else {
                        uint product = m31_mul(rhs, twiddle);
                        values[lo] = m31_add(lhs, product);
                        values[hi] = m31_sub(lhs, product);
                    }
                }
            }
        }
        for (uint item = 0u; item < 16u; ++item) arena[indices[item]] = values[item];
        return;
    }

    if (radix8) {
        uint indices[8];
        uint values[8];
        if (inverse) {
            uint distance = 1u << stage;
            uint group = position.x >> stage;
            uint lane = position.x & (distance - 1u);
            uint base = destination_offsets[position.y] + (group << (stage + 3u));
            for (uint item = 0u; item < 8u; ++item) {
                indices[item] = base + lane + item * distance;
                values[item] = arena[indices[item]];
            }

            uint first_offset = pair_count - (1u << (log_size - stage));
            for (uint pair = 0u; pair < 4u; ++pair) {
                uint lo = pair << 1u, hi = lo + 1u;
                uint lhs = values[lo], rhs = values[hi];
                values[lo] = m31_add(lhs, rhs);
                values[hi] = m31_mul(
                    m31_sub(lhs, rhs),
                    twiddles[first_offset + (group << 2u) + pair]
                );
            }

            uint second_offset = pair_count - (1u << (log_size - stage - 1u));
            for (uint block = 0u; block < 2u; ++block) {
                uint start = block << 2u;
                uint twiddle = twiddles[second_offset + (group << 1u) + block];
                for (uint item = 0u; item < 2u; ++item) {
                    uint lo = start + item, hi = lo + 2u;
                    uint lhs = values[lo], rhs = values[hi];
                    values[lo] = m31_add(lhs, rhs);
                    values[hi] = m31_mul(m31_sub(lhs, rhs), twiddle);
                }
            }

            uint third_offset = pair_count - (1u << (log_size - stage - 2u));
            uint third_twiddle = twiddles[third_offset + group];
            for (uint item = 0u; item < 4u; ++item) {
                uint lhs = values[item], rhs = values[item + 4u];
                values[item] = m31_add(lhs, rhs);
                values[item + 4u] = m31_mul(m31_sub(lhs, rhs), third_twiddle);
            }
        } else {
            uint distance = 1u << (stage - 2u);
            uint group = position.x >> (stage - 2u);
            uint lane = position.x & (distance - 1u);
            uint base = destination_offsets[position.y] + (group << (stage + 1u));
            for (uint item = 0u; item < 8u; ++item) {
                indices[item] = base + lane + item * distance;
                values[item] = arena[indices[item]];
            }

            uint first_offset = pair_count - (1u << (log_size - stage));
            uint first_twiddle = twiddles[first_offset + group];
            for (uint item = 0u; item < 4u; ++item) {
                uint lhs = values[item];
                uint rhs = m31_mul(values[item + 4u], first_twiddle);
                values[item] = m31_add(lhs, rhs);
                values[item + 4u] = m31_sub(lhs, rhs);
            }

            uint second_offset = pair_count - (1u << (log_size - stage + 1u));
            for (uint block = 0u; block < 2u; ++block) {
                uint start = block << 2u;
                uint twiddle = twiddles[second_offset + (group << 1u) + block];
                for (uint item = 0u; item < 2u; ++item) {
                    uint lo = start + item, hi = lo + 2u;
                    uint lhs = values[lo], rhs = m31_mul(values[hi], twiddle);
                    values[lo] = m31_add(lhs, rhs);
                    values[hi] = m31_sub(lhs, rhs);
                }
            }

            uint third_offset = pair_count - (1u << (log_size - stage + 2u));
            for (uint pair = 0u; pair < 4u; ++pair) {
                uint lo = pair << 1u, hi = lo + 1u;
                uint twiddle = twiddles[third_offset + (group << 2u) + pair];
                uint lhs = values[lo], rhs = m31_mul(values[hi], twiddle);
                values[lo] = m31_add(lhs, rhs);
                values[hi] = m31_sub(lhs, rhs);
            }
        }
        for (uint item = 0u; item < 8u; ++item) arena[indices[item]] = values[item];
        return;
    }

    if (inverse) {
        // Compose inverse stages L and L+1. The first stage operates on the
        // two adjacent pairs; the second combines their sums and weighted
        // differences, keeping all four intermediates in registers.
        uint half_distance = 1u << stage;
        uint group = position.x >> stage;
        uint lane = position.x & (half_distance - 1u);
        uint base = destination_offsets[position.y] + (group << (stage + 2u));
        uint idx0 = base + lane;
        uint idx1 = idx0 + half_distance;
        uint idx2 = idx1 + half_distance;
        uint idx3 = idx2 + half_distance;
        uint first_offset = pair_count - (1u << (log_size - stage));
        uint second_offset = pair_count - (1u << (log_size - stage - 1u));
        uint first_group = group << 1u;

        uint a = arena[idx0], b = arena[idx1];
        uint c = arena[idx2], d = arena[idx3];
        uint ab_sum = m31_add(a, b);
        uint ab_diff = m31_mul(m31_sub(a, b), twiddles[first_offset + first_group]);
        uint cd_sum = m31_add(c, d);
        uint cd_diff = m31_mul(m31_sub(c, d), twiddles[first_offset + first_group + 1u]);
        uint second_twiddle = twiddles[second_offset + group];
        arena[idx0] = m31_add(ab_sum, cd_sum);
        arena[idx1] = m31_add(ab_diff, cd_diff);
        arena[idx2] = m31_mul(m31_sub(ab_sum, cd_sum), second_twiddle);
        arena[idx3] = m31_mul(m31_sub(ab_diff, cd_diff), second_twiddle);
        return;
    }

    uint half_distance = 1u << (stage - 1u);
    uint group = position.x >> (stage - 1u);
    uint lane = position.x & (half_distance - 1u);
    uint distance = half_distance << 1u;
    uint base = destination_offsets[position.y] + (group << (stage + 1u));
    uint idx0 = base + lane;
    uint idx1 = idx0 + half_distance;
    uint idx2 = idx0 + distance;
    uint idx3 = idx2 + half_distance;

    uint first_twiddle_offset = pair_count - (1u << (log_size - stage));
    uint second_twiddle_offset = pair_count - (1u << (log_size - stage + 1u));
    uint first_twiddle = twiddles[first_twiddle_offset + group];
    uint second_group = group << 1u;

    uint a = arena[idx0];
    uint b = arena[idx1];
    uint c = m31_mul(arena[idx2], first_twiddle);
    uint d = m31_mul(arena[idx3], first_twiddle);
    uint ac_sum = m31_add(a, c);
    uint ac_diff = m31_sub(a, c);
    uint bd_sum = m31_add(b, d);
    uint bd_diff = m31_sub(b, d);
    uint upper = m31_mul(bd_sum, twiddles[second_twiddle_offset + second_group]);
    uint lower = m31_mul(bd_diff, twiddles[second_twiddle_offset + second_group + 1u]);
    arena[idx0] = m31_add(ac_sum, upper);
    arena[idx1] = m31_sub(ac_sum, upper);
    arena[idx2] = m31_add(ac_diff, lower);
    arena[idx3] = m31_sub(ac_diff, lower);
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

kernel void stwo_zig_circle_rfft_layer_sparse_wide(
    device uint *arena [[buffer(0)]],
    device const ulong *destination_offsets [[buffer(1)]],
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
    ulong base = destination_offsets[position.y] + (twiddle_index << (layer + 1u));
    ulong idx0 = base + lane, idx1 = idx0 + polynomial_count;
    uint lhs = arena[idx0];
    uint product = m31_mul(arena[idx1], twiddles[twiddle_offset + twiddle_index]);
    arena[idx0] = m31_add(lhs, product);
    arena[idx1] = m31_sub(lhs, product);
}

kernel void stwo_zig_circle_rfft_last_sparse_wide(
    device uint *arena [[buffer(0)]],
    device const ulong *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint pair_count = 1u << (log_size - 1u);
    if (position.x >= pair_count || position.y >= column_count) return;
    ulong idx0 = destination_offsets[position.y] + (position.x << 1u), idx1 = idx0 + 1u;
    uint lhs = arena[idx0];
    uint product = m31_mul(arena[idx1], circle_twiddle(twiddles, position.x));
    arena[idx0] = m31_add(lhs, product);
    arena[idx1] = m31_sub(lhs, product);
}

constant uint circle_fused_tile_log = 11u;
constant uint circle_fused_tile_size = 1u << circle_fused_tile_log;
constant uint circle_fused_threads = 256u;

kernel void stwo_zig_circle_ifft_fused_tail(
    device const uint *source [[buffer(0)]],
    device uint *destination [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &column_or_destination [[buffer(4)]],
    constant uint &source_mode [[buffer(5)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    if (source_mode == 0u && group.y >= column_or_destination) return;
    threadgroup uint tile[circle_fused_tile_size];
    uint value_len = 1u << log_size;
    uint tile_offset = group.x << circle_fused_tile_log;
    uint source_column_offset = group.y << log_size;
    uint destination_column_offset =
        (source_mode == 0u ? group.y : column_or_destination + group.y) << log_size;
    for (uint item = lane; item < circle_fused_tile_size; item += circle_fused_threads) {
        tile[item] = source[source_column_offset + tile_offset + item];
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
        destination[destination_column_offset + tile_offset + item] = tile[item];
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

kernel void stwo_zig_circle_rfft_fused_tail_sparse(
    device uint *arena [[buffer(0)]],
    device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    if (group.y >= column_count) return;
    threadgroup uint tile[circle_fused_tile_size];
    uint value_len = 1u << log_size;
    uint tile_offset = group.x << circle_fused_tile_log;
    uint column_offset = destination_offsets[group.y];
    for (uint item = lane; item < circle_fused_tile_size; item += circle_fused_threads) {
        tile[item] = arena[column_offset + tile_offset + item];
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
        arena[column_offset + tile_offset + item] = tile[item];
    }
}
