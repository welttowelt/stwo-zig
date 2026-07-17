#include <metal_stdlib>
using namespace metal;

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/blake2s.metal"
#include "stwo_zig/merkle.metal"
#include "stwo_zig/decommit.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/extension_fields.metal"
#include "stwo_zig/circle.metal"
#include "stwo_zig/felt252.metal"
#include "stwo_zig/ec.metal"
#include "stwo_zig/witness_abi.metal"
#include "stwo_zig/witness_tables.metal"
#include "stwo_zig/witness_deductions.metal"
#endif

struct QuotientView { uint offset, length, batch, shift, direct; };
struct RawQuotientView {
    uint offset, length, batch, shift, direct;
    uint coeff_a, coeff_b, coeff_c, coeff_d;
};

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

inline CircleM31Value quotient_domain_point(
    uint initial_index,
    uint step_size,
    uint row,
    uint row_count,
    uint log_size
) {
    uint domain_index = reverse_bits(row) >> (32u - log_size);
    uint half_count = row_count >> 1u;
    uint local = domain_index < half_count ? domain_index : domain_index - half_count;
    ulong global = (ulong)initial_index + (ulong)step_size * local;
    uint exponent = (uint)(global & 0x7ffffffful);
    if (domain_index >= half_count) exponent = (0x80000000u - exponent) & 0x7fffffffu;
    return circle_pow(exponent);
}

struct QuotientCoefficientTerm {
    ulong source_offset;
    uint source_words;
    uint c0;
    uint c1;
    uint c2;
    uint c3;
};

struct QuotientCoefficientTask {
    uint term_start;
    uint term_count;
    uint destination0;
    uint destination1;
    uint destination2;
    uint destination3;
    uint row_count;
    uint b0;
    uint b1;
    uint b2;
    uint b3;
};

kernel void stwo_zig_quotient_coefficients_resident(
    device uint *arena [[buffer(0)]],
    device const QuotientCoefficientTerm *terms [[buffer(1)]],
    device const QuotientCoefficientTask *tasks [[buffer(2)]],
    device const uint *row_starts [[buffer(3)]],
    constant uint &task_count [[buffer(4)]],
    constant uint &total_rows [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= total_rows) return;
    uint low = 0u;
    uint high = task_count;
    while (low + 1u < high) {
        uint middle = low + ((high - low) >> 1u);
        if (row_starts[middle] <= gid) low = middle;
        else high = middle;
    }
    QuotientCoefficientTask task = tasks[low];
    uint row = gid - row_starts[low];
    if (row >= task.row_count) return;

    uint accum0 = 0u;
    uint accum1 = 0u;
    uint accum2 = 0u;
    uint accum3 = 0u;
    for (uint i = 0u; i < task.term_count; ++i) {
        QuotientCoefficientTerm term = terms[task.term_start + i];
        if (row >= term.source_words) continue;
        uint value = arena[term.source_offset + (ulong)row];
        accum0 = m31_add(accum0, m31_mul(value, term.c0));
        accum1 = m31_add(accum1, m31_mul(value, term.c1));
        accum2 = m31_add(accum2, m31_mul(value, term.c2));
        accum3 = m31_add(accum3, m31_mul(value, term.c3));
    }
    if (row == 0u) {
        accum0 = m31_sub(accum0, task.b0);
        accum1 = m31_sub(accum1, task.b1);
        accum2 = m31_sub(accum2, task.b2);
        accum3 = m31_sub(accum3, task.b3);
    }
    arena[task.destination0 + row] = accum0;
    arena[task.destination1 + row] = accum1;
    arena[task.destination2 + row] = accum2;
    arena[task.destination3 + row] = accum3;
}

kernel void stwo_zig_quotient_domain_points_resident(
    device uint *arena [[buffer(0)]],
    constant uint &destination_offset [[buffer(1)]],
    constant uint &row_count [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &initial_index [[buffer(4)]],
    constant uint &step_size [[buffer(5)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    CircleM31Value point = quotient_domain_point(initial_index, step_size, row, row_count, log_size);
    arena[destination_offset + row] = point.x;
    arena[destination_offset + row_count + row] = point.y;
}

kernel void stwo_zig_quotient_denominators_resident(
    device uint *arena [[buffer(0)]],
    constant uint &domain_offset [[buffer(1)]],
    constant uint &sample_offset [[buffer(2)]],
    constant uint &scratch_offset [[buffer(3)]],
    constant uint &row_count [[buffer(4)]],
    constant uint &sample_count [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uint total = row_count * sample_count;
    if (gid >= total) return;
    uint row = gid / sample_count;
    uint sample = gid - row * sample_count;
    uint base = sample_offset + sample * 8u;
    Cm31Value prx = { arena[base], arena[base + 1u] };
    Cm31Value pix = { arena[base + 2u], arena[base + 3u] };
    Cm31Value pry = { arena[base + 4u], arena[base + 5u] };
    Cm31Value piy = { arena[base + 6u], arena[base + 7u] };
    uint x = arena[domain_offset + row];
    uint y = arena[domain_offset + row_count + row];
    Cm31Value denominator = cm_sub(
        cm_mul(cm_sub(prx, { x, 0u }), piy),
        cm_mul(cm_sub(pry, { y, 0u }), pix)
    );
    Cm31Value inverse = cm_inv(denominator);
    arena[scratch_offset + gid * 2u] = inverse.a;
    arena[scratch_offset + gid * 2u + 1u] = inverse.b;
}

kernel void stwo_zig_quotient_combine_resident(
    device uint *arena [[buffer(0)]],
    device const uint *partial_offsets [[buffer(1)]],
    device const uint *partial_logs [[buffer(2)]],
    constant uint &sample_offset [[buffer(3)]],
    constant uint &linear_offset [[buffer(4)]],
    constant uint &scratch_offset [[buffer(5)]],
    constant uint &output_offset [[buffer(6)]],
    constant uint &row_count [[buffer(7)]],
    constant uint &log_size [[buffer(8)]],
    constant uint &sample_count [[buffer(9)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    uint y = arena[output_offset + row_count + row];
    Qm31Value quotient = { 0u, 0u, 0u, 0u };
    for (uint sample = 0u; sample < sample_count; ++sample) {
        uint partial_log = partial_logs[sample];
        uint log_ratio = log_size - partial_log;
        uint lifted = (row >> (log_ratio + 1u) << 1u) + (row & 1u);
        Qm31Value partial = {
            arena[partial_offsets[sample] + lifted],
            arena[partial_offsets[sample_count + sample] + lifted],
            arena[partial_offsets[2u * sample_count + sample] + lifted],
            arena[partial_offsets[3u * sample_count + sample] + lifted],
        };
        uint linear = linear_offset + sample * 4u;
        Qm31Value first = { arena[linear], arena[linear + 1u], arena[linear + 2u], arena[linear + 3u] };
        uint inverse = scratch_offset + (row * sample_count + sample) * 2u;
        quotient = qm_add(quotient, qm_mul_cm(
            qm_sub(partial, qm_mul_m31(first, y)),
            { arena[inverse], arena[inverse + 1u] }
        ));
    }
    arena[output_offset + row] = quotient.a;
    arena[output_offset + row_count + row] = quotient.b;
    arena[output_offset + 2u * row_count + row] = quotient.c;
    arena[output_offset + 3u * row_count + row] = quotient.d;
}

inline Qm31Value fri_load_planar(device const uint *arena, uint base, uint stride, uint index) {
    return {
        arena[base + index], arena[base + stride + index],
        arena[base + 2u * stride + index], arena[base + 3u * stride + index],
    };
}

inline uint fri_circle_twiddle(device const uint *twiddles, uint offset, uint index) {
    uint k = index >> 2u;
    uint a = twiddles[offset + 2u * k];
    uint b = twiddles[offset + 2u * k + 1u];
    switch (index & 3u) {
        case 0u: return b;
        case 1u: return m31_neg(b);
        case 2u: return m31_neg(a);
        default: return a;
    }
}

inline Qm31Value fri_fold_pair(Qm31Value left, Qm31Value right, uint inverse, Qm31Value alpha) {
    return qm_add(qm_add(left, right), qm_mul(alpha, qm_mul_m31(qm_sub(left, right), inverse)));
}

kernel void stwo_zig_fri_fold3_resident(
    device uint *arena [[buffer(0)]],
    constant uint &twiddle_base [[buffer(1)]],
    constant uint &twiddle_offset_0 [[buffer(2)]],
    constant uint &twiddle_offset_1 [[buffer(3)]],
    constant uint &twiddle_offset_2 [[buffer(4)]],
    constant uint &input_base [[buffer(5)]],
    constant uint &input_stride [[buffer(6)]],
    constant uint &alpha_base [[buffer(7)]],
    constant uint &output_base [[buffer(8)]],
    constant uint &output_stride [[buffer(9)]],
    constant uint &n [[buffer(10)]],
    constant uint &first_circle [[buffer(11)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= (n >> 3u)) return;
    Qm31Value alpha0 = { arena[alpha_base], arena[alpha_base + 1u], arena[alpha_base + 2u], arena[alpha_base + 3u] };
    Qm31Value alpha1 = qm_mul(alpha0, alpha0);
    Qm31Value alpha2 = qm_mul(alpha1, alpha1);
    Qm31Value stage0[4];
    for (uint k = 0u; k < 4u; ++k) {
        uint out = 4u * index + k;
        uint inverse = first_circle != 0u
            ? fri_circle_twiddle(arena, twiddle_base + twiddle_offset_0, out)
            : arena[twiddle_base + twiddle_offset_0 + out];
        stage0[k] = fri_fold_pair(
            fri_load_planar(arena, input_base, input_stride, 2u * out),
            fri_load_planar(arena, input_base, input_stride, 2u * out + 1u),
            inverse,
            alpha0
        );
    }
    Qm31Value stage1[2];
    for (uint k = 0u; k < 2u; ++k) {
        uint out = 2u * index + k;
        stage1[k] = fri_fold_pair(
            stage0[2u * k], stage0[2u * k + 1u],
            arena[twiddle_base + twiddle_offset_1 + out], alpha1
        );
    }
    Qm31Value result = fri_fold_pair(
        stage1[0], stage1[1], arena[twiddle_base + twiddle_offset_2 + index], alpha2
    );
    arena[output_base + index] = result.a;
    arena[output_base + output_stride + index] = result.b;
    arena[output_base + 2u * output_stride + index] = result.c;
    arena[output_base + 3u * output_stride + index] = result.d;
}

kernel void stwo_zig_fri_fold2_resident(
    device uint *arena [[buffer(0)]],
    constant uint &twiddle_base [[buffer(1)]],
    constant uint &twiddle_offset_0 [[buffer(2)]],
    constant uint &twiddle_offset_1 [[buffer(3)]],
    constant uint &input_base [[buffer(4)]],
    constant uint &input_stride [[buffer(5)]],
    constant uint &alpha_base [[buffer(6)]],
    constant uint &output_base [[buffer(7)]],
    constant uint &output_stride [[buffer(8)]],
    constant uint &n [[buffer(9)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= (n >> 2u)) return;
    Qm31Value alpha0 = { arena[alpha_base], arena[alpha_base + 1u], arena[alpha_base + 2u], arena[alpha_base + 3u] };
    Qm31Value alpha1 = qm_mul(alpha0, alpha0);
    Qm31Value stage0[2];
    for (uint k = 0u; k < 2u; ++k) {
        uint out = 2u * index + k;
        stage0[k] = fri_fold_pair(
            fri_load_planar(arena, input_base, input_stride, 2u * out),
            fri_load_planar(arena, input_base, input_stride, 2u * out + 1u),
            arena[twiddle_base + twiddle_offset_0 + out], alpha0
        );
    }
    Qm31Value result = fri_fold_pair(
        stage0[0], stage0[1], arena[twiddle_base + twiddle_offset_1 + index], alpha1
    );
    arena[output_base + index] = result.a;
    arena[output_base + output_stride + index] = result.b;
    arena[output_base + 2u * output_stride + index] = result.c;
    arena[output_base + 3u * output_stride + index] = result.d;
}

kernel void stwo_zig_fri_packed_leaves_resident(
    device uint *arena [[buffer(0)]],
    constant uint &evaluation_base [[buffer(1)]],
    constant uint &coordinate_stride [[buffer(2)]],
    constant uint &evaluation_size [[buffer(3)]],
    constant uint &log_rows_per_leaf [[buffer(4)]],
    constant uint &destination_base [[buffer(5)]],
    constant uint *leaf_seed [[buffer(6)]],
    constant uint &prefix_bytes [[buffer(7)]],
    uint leaf [[thread_position_in_grid]]
) {
    uint leaf_count = evaluation_size >> log_rows_per_leaf;
    if (leaf >= leaf_count) return;
    uint state[8], message[16];
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, leaf_seed);
    for (uint i = 0u; i < 16u; ++i) message[i] = 0u;
    if (log_rows_per_leaf == 0u) {
        for (uint coordinate = 0u; coordinate < 4u; ++coordinate)
            message[coordinate] = arena[evaluation_base + coordinate * coordinate_stride + leaf];
        blake2s_compress(state, message, prefix_bytes + 16u, true);
    } else {
        for (uint offset = 0u; offset < 4u; ++offset) {
            for (uint coordinate = 0u; coordinate < 4u; ++coordinate) {
                message[coordinate + 4u * offset] =
                    arena[evaluation_base + coordinate * coordinate_stride + 4u * leaf + offset];
            }
        }
        blake2s_compress(state, message, prefix_bytes + 64u, true);
    }
    for (uint i = 0u; i < 8u; ++i) arena[destination_base + leaf * 8u + i] = state[i];
}

kernel void stwo_zig_fri_final_line_resident(
    device uint *arena [[buffer(0)]],
    constant uint &evaluation_base [[buffer(1)]],
    constant uint &coordinate_stride [[buffer(2)]],
    constant uint &inverse_x [[buffer(3)]],
    constant uint &coefficient_base [[buffer(4)]],
    constant uint &degree_error [[buffer(5)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    Qm31Value left = fri_load_planar(arena, evaluation_base, coordinate_stride, 0u);
    Qm31Value right = fri_load_planar(arena, evaluation_base, coordinate_stride, 1u);
    Qm31Value c0 = qm_mul_m31(qm_add(left, right), 1073741824u);
    Qm31Value c1 = qm_mul_m31(qm_mul_m31(qm_sub(left, right), inverse_x), 1073741824u);
    arena[coefficient_base] = c0.a;
    arena[coefficient_base + 1u] = c0.b;
    arena[coefficient_base + 2u] = c0.c;
    arena[coefficient_base + 3u] = c0.d;
    arena[coefficient_base + 4u] = c1.a;
    arena[coefficient_base + 5u] = c1.b;
    arena[coefficient_base + 6u] = c1.c;
    arena[coefficient_base + 7u] = c1.d;
    arena[degree_error] = (c1.a | c1.b | c1.c | c1.d) != 0u ? 1u : 0u;
}

/// Canonicalizes the transcript's raw query positions once. Query counts are
/// protocol constants, so a serial insertion sort is faster than allocating a
/// device radix-sort workspace and keeps the prepared graph pointer-stable.
kernel void stwo_zig_decommit_normalize_queries_resident(
    device uint *arena [[buffer(0)]],
    constant ulong &raw_base [[buffer(1)]],
    constant uint &raw_count [[buffer(2)]],
    constant uint &log_domain_size [[buffer(3)]],
    constant ulong &unique_base [[buffer(4)]],
    constant ulong &unique_count_base [[buffer(5)]],
    constant uint &tree_count [[buffer(6)]],
    constant ulong &assembly_base [[buffer(7)]],
    constant uint &assembly_capacity [[buffer(8)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    uint mask = (1u << log_domain_size) - 1u;
    for (uint i = 0u; i < raw_count; ++i) arena[unique_base + i] = arena[raw_base + i] & mask;
    uint unique_count = decommit_sort_unique(arena + unique_base, raw_count);
    arena[unique_count_base] = unique_count;
    uint raw_offset = 8u + tree_count * 16u;
    uint unique_offset = raw_offset + raw_count;
    uint used = unique_offset + unique_count;
    if (used > assembly_capacity) {
        arena[assembly_base + 7u] = 0u;
        return;
    }
    arena[assembly_base] = 0x44575453u;
    arena[assembly_base + 1u] = 1u;
    arena[assembly_base + 2u] = tree_count;
    arena[assembly_base + 3u] = raw_count;
    arena[assembly_base + 4u] = unique_count;
    arena[assembly_base + 5u] = raw_offset;
    arena[assembly_base + 6u] = unique_offset;
    arena[assembly_base + 7u] = used;
    for (uint i = 0u; i < tree_count * 16u; ++i) arena[assembly_base + 8u + i] = 0u;
    for (uint i = 0u; i < raw_count; ++i) arena[assembly_base + raw_offset + i] = arena[raw_base + i] & mask;
    for (uint i = 0u; i < unique_count; ++i) arena[assembly_base + unique_offset + i] = arena[unique_base + i];
}

kernel void stwo_zig_decommit_prepare_fri_queries_resident(
    device uint *arena [[buffer(0)]],
    constant ulong &unique_base [[buffer(1)]],
    constant ulong &unique_count_base [[buffer(2)]],
    constant uint &max_queries [[buffer(3)]],
    constant uint &cumulative_fold [[buffer(4)]],
    constant uint &fold_step [[buffer(5)]],
    constant uint &packed_log [[buffer(6)]],
    constant ulong &tree_queries_base [[buffer(7)]],
    constant ulong &tree_count_base [[buffer(8)]],
    constant ulong &expanded_base [[buffer(9)]],
    constant ulong &expanded_count_base [[buffer(10)]],
    constant ulong &walk_base [[buffer(11)]],
    constant ulong &walk_count_base [[buffer(12)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    uint count = min(arena[unique_count_base], max_queries);
    for (uint i = 0u; i < count; ++i) arena[tree_queries_base + i] = arena[unique_base + i] >> cumulative_fold;
    uint queries = decommit_sort_unique(arena + tree_queries_base, count);
    arena[tree_count_base] = queries;
    uint out = 0u, previous_coset = 0xffffffffu, coset_size = 1u << fold_step;
    for (uint i = 0u; i < queries; ++i) {
        uint coset = arena[tree_queries_base + i] >> fold_step;
        if (coset == previous_coset) continue;
        previous_coset = coset;
        uint start = coset << fold_step;
        for (uint j = 0u; j < coset_size; ++j) arena[expanded_base + out++] = start + j;
    }
    arena[expanded_count_base] = out;
    for (uint i = 0u; i < out; ++i) arena[walk_base + i] = arena[expanded_base + i] >> packed_log;
    arena[walk_count_base] = decommit_sort_unique(arena + walk_base, out);
}

kernel void stwo_zig_decommit_prepare_trace_queries_resident(
    device uint *arena [[buffer(0)]],
    constant ulong &unique_base [[buffer(1)]],
    constant ulong &unique_count_base [[buffer(2)]],
    constant uint &max_queries [[buffer(3)]],
    constant uint &source_log [[buffer(4)]],
    constant uint &tree_log [[buffer(5)]],
    constant uint &leaf_log [[buffer(6)]],
    constant uint &unretained [[buffer(7)]],
    constant ulong &mapped_base [[buffer(8)]],
    constant ulong &mapped_count_base [[buffer(9)]],
    constant ulong &walk_base [[buffer(10)]],
    constant ulong &walk_count_base [[buffer(11)]],
    constant ulong &leaf_indices_base [[buffer(12)]],
    constant ulong &leaf_count_base [[buffer(13)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    uint count = min(arena[unique_count_base], max_queries);
    for (uint i = 0u; i < count; ++i) {
        arena[mapped_base + i] = decommit_map_query_log(arena[unique_base + i], source_log, tree_log);
        arena[walk_base + i] = arena[mapped_base + i];
    }
    arena[mapped_count_base] = count;
    uint dedup = decommit_sort_unique(arena + walk_base, count);
    arena[walk_count_base] = dedup;
    if (unretained == 0u) { arena[leaf_count_base] = 0u; return; }
    uint span = 1u << unretained, leaves = 0u;
    for (uint i = 0u; i < dedup; ++i) {
        uint base = (arena[walk_base + i] >> unretained) << unretained;
        for (uint j = 0u; j < span; ++j) arena[leaf_indices_base + leaves++] = base + j;
    }
    arena[leaf_count_base] = decommit_sort_unique(arena + leaf_indices_base, leaves);
    (void)leaf_log;
}

kernel void stwo_zig_decommit_gather_trace_values_resident(
    device uint *arena [[buffer(0)]],
    constant ulong &column_offsets_base [[buffer(1)]],
    constant ulong &column_logs_base [[buffer(2)]],
    constant uint &column_count [[buffer(3)]],
    constant uint &lifting_log [[buffer(4)]],
    constant ulong &queries_base [[buffer(5)]],
    constant ulong &query_count_base [[buffer(6)]],
    constant uint &max_queries [[buffer(7)]],
    constant uint &first_column [[buffer(8)]],
    constant uint &stride [[buffer(9)]],
    constant ulong &output_base [[buffer(10)]],
    uint3 grid_position [[thread_position_in_grid]]
) {
    uint query = grid_position.x, column = grid_position.y;
    if (column >= column_count || query >= min(arena[query_count_base], max_queries)) return;
    uint row = decommit_lifted_index(arena[queries_base + query], lifting_log, arena[column_logs_base + column]);
    ulong source = decommit_wide_word_offset(arena, column_offsets_base, column);
    uint value = arena[source + ulong(row)];
    arena[output_base + (first_column + column) * stride + query] = value < 0x7fffffffu ? value : value % 0x7fffffffu;
}

kernel void stwo_zig_decommit_gather_fri_values_resident(
    device uint *arena [[buffer(0)]],
    constant uint *coordinate_bases [[buffer(1)]],
    constant ulong &positions_base [[buffer(2)]],
    constant ulong &count_base [[buffer(3)]],
    constant uint &max_positions [[buffer(4)]],
    constant ulong &values_base [[buffer(5)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= min(arena[count_base], max_positions)) return;
    uint position = arena[positions_base + index];
    for (uint coordinate = 0u; coordinate < 4u; ++coordinate) {
        ulong source = decommit_join_word_offset(
            coordinate_bases[2u * coordinate],
            coordinate_bases[2u * coordinate + 1u]
        );
        uint value = arena[source + ulong(position)];
        arena[values_base + 4u * index + coordinate] = value < 0x7fffffffu ? value : value % 0x7fffffffu;
    }
}

kernel void stwo_zig_decommit_sparse_parent_resident(
    device uint *arena [[buffer(0)]], constant ulong &child_indices [[buffer(1)]],
    constant ulong &child_hashes [[buffer(2)]], constant ulong &child_count_at [[buffer(3)]],
    constant uint &max_child_count [[buffer(4)]], constant ulong &parent_indices [[buffer(5)]],
    constant ulong &parent_hashes [[buffer(6)]], constant ulong &parent_count_at [[buffer(7)]],
    constant uint *node_seed [[buffer(8)]], constant uint &prefix_bytes [[buffer(9)]],
    uint parent [[thread_position_in_grid]]
) {
    uint count = min(arena[child_count_at], max_child_count), parents = count >> 1u;
    if (parent == 0u) arena[parent_count_at] = parents;
    if (parent >= parents) return;
    uint left = 2u * parent;
    arena[parent_indices + parent] = arena[child_indices + left] >> 1u;
    uint state[8], message[16];
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, node_seed);
    for (uint i = 0u; i < 16u; ++i) message[i] = arena[child_hashes + left * 8u + i];
    blake2s_compress(state, message, prefix_bytes + 64u, true);
    for (uint i = 0u; i < 8u; ++i) arena[parent_hashes + parent * 8u + i] = state[i];
}

kernel void stwo_zig_decommit_sparse_leaves_resident(
    device uint *arena [[buffer(0)]], constant ulong &column_offsets [[buffer(1)]],
    constant ulong &column_logs [[buffer(2)]], constant uint &column_count [[buffer(3)]],
    constant uint &lifting_log [[buffer(4)]], constant ulong &leaf_indices [[buffer(5)]],
    constant ulong &leaf_count_at [[buffer(6)]], constant uint &max_leaf_count [[buffer(7)]],
    constant ulong &output_hashes [[buffer(8)]], constant uint *leaf_seed [[buffer(9)]],
    constant uint &prefix_bytes [[buffer(10)]],
    uint sparse_index [[thread_position_in_grid]]
) {
    uint count = min(arena[leaf_count_at], max_leaf_count);
    if (sparse_index >= count) return;
    uint position = arena[leaf_indices + sparse_index];
    uint state[8], message[16], in_block = 0u, total_bytes = prefix_bytes;
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, leaf_seed);
    for (uint column = 0u; column < column_count; ++column) {
        uint log_size = arena[column_logs + column];
        uint row = decommit_lifted_index(position, lifting_log, log_size);
        ulong source = decommit_wide_word_offset(arena, column_offsets, column);
        message[in_block++] = arena[source + ulong(row)];
        total_bytes += 4u;
        if (in_block == 16u) {
            blake2s_compress(state, message, total_bytes, column + 1u == column_count);
            in_block = 0u;
        }
    }
    if (in_block != 0u) {
        for (uint i = in_block; i < 16u; ++i) message[i] = 0u;
        blake2s_compress(state, message, total_bytes, true);
    }
    for (uint i = 0u; i < 8u; ++i) arena[output_hashes + sparse_index * 8u + i] = state[i];
}

/// Streams one block-aligned trace-column group into each sparse leaf hash.
/// Full groups contain 16 columns; only the final group may be shorter. The
/// Blake2s counter is global across groups, so this is byte-for-byte identical
/// to hashing all trace columns in one invocation.
kernel void stwo_zig_decommit_sparse_leaf_group_resident(
    device uint *arena [[buffer(0)]], constant ulong &column_offsets [[buffer(1)]],
    constant ulong &column_logs [[buffer(2)]], constant uint &column_count [[buffer(3)]],
    constant uint &first_column [[buffer(4)]], constant uint &total_columns [[buffer(5)]],
    constant uint &lifting_log [[buffer(6)]], constant ulong &leaf_indices [[buffer(7)]],
    constant ulong &leaf_count_at [[buffer(8)]], constant uint &max_leaf_count [[buffer(9)]],
    constant ulong &output_hashes [[buffer(10)]], constant uint *leaf_seed [[buffer(11)]],
    constant uint &prefix_bytes [[buffer(12)]],
    uint sparse_index [[thread_position_in_grid]]
) {
    uint count = min(arena[leaf_count_at], max_leaf_count);
    if (sparse_index >= count) return;
    uint position = arena[leaf_indices + sparse_index];
    uint state[8], message[16], in_block = 0u;
    if (first_column == 0u) {
        if (prefix_bytes == 0u) blake2s_init_hash(state);
        else blake2s_init_seeded(state, leaf_seed);
    } else {
        for (uint i = 0u; i < 8u; ++i) state[i] = arena[output_hashes + sparse_index * 8u + i];
    }
    uint total_bytes = prefix_bytes + first_column * 4u;
    for (uint column = 0u; column < column_count; ++column) {
        uint log_size = arena[column_logs + column];
        uint row = decommit_lifted_index(position, lifting_log, log_size);
        ulong source = decommit_wide_word_offset(arena, column_offsets, column);
        message[in_block++] = arena[source + ulong(row)];
        total_bytes += 4u;
        if (in_block == 16u) {
            blake2s_compress(state, message, total_bytes, first_column + column + 1u == total_columns);
            in_block = 0u;
        }
    }
    if (in_block != 0u) {
        for (uint i = in_block; i < 16u; ++i) message[i] = 0u;
        blake2s_compress(state, message, total_bytes, true);
    }
    for (uint i = 0u; i < 8u; ++i) arena[output_hashes + sparse_index * 8u + i] = state[i];
}

kernel void stwo_zig_decommit_assemble_trace_resident(
    device uint *arena [[buffer(0)]], constant uint &tree_index [[buffer(1)]],
    constant uint &role [[buffer(2)]], constant uint &leaf_log [[buffer(3)]],
    constant uint &first_retained_log [[buffer(4)]], constant uint &column_count [[buffer(5)]],
    constant ulong &mapped [[buffer(6)]], constant ulong &mapped_count_at [[buffer(7)]],
    constant uint &max_queries [[buffer(8)]], constant ulong &walk [[buffer(9)]],
    constant ulong &scratch [[buffer(10)]], constant ulong &walk_count_at [[buffer(11)]],
    constant ulong &values [[buffer(12)]], constant ulong &retained_offsets [[buffer(13)]],
    constant ulong &sparse_indices [[buffer(14)]], constant ulong &sparse_hashes [[buffer(15)]],
    constant ulong &sparse_offsets [[buffer(16)]], constant ulong &sparse_counts [[buffer(17)]],
    constant uint &sparse_level_count [[buffer(18)]], constant ulong &assembly [[buffer(19)]],
    constant uint &capacity [[buffer(20)]], uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u || arena[assembly + 7u] == 0u) return;
    ulong meta = assembly + 8ul + ulong(tree_index) * 16ul;
    uint tree_start = arena[assembly + 7u], mapped_count = min(arena[mapped_count_at], max_queries), offset = 0u;
    if (!decommit_reserve(arena, assembly, capacity, mapped_count, offset)) return;
    arena[meta + 2u] = offset; arena[meta + 3u] = mapped_count;
    for (uint i = 0u; i < mapped_count; ++i) arena[assembly + offset + i] = arena[mapped + i];

    uint value_words = column_count * mapped_count;
    if (!decommit_reserve(arena, assembly, capacity, value_words, offset)) return;
    arena[meta + 4u] = offset; arena[meta + 5u] = value_words;
    for (uint c = 0u; c < column_count; ++c)
        for (uint q = 0u; q < mapped_count; ++q)
            arena[assembly + offset + c * mapped_count + q] = arena[values + c * max_queries + q];

    uint current_count = min(arena[walk_count_at], max_queries);
    bool current_is_walk = true;
    uint hash_offset = arena[assembly + 7u], hash_count = 0u;
    uint aux_offset = hash_offset + leaf_log * current_count * 8u;
    uint reserve = leaf_log * current_count * 28u;
    if (!decommit_reserve(arena, assembly, capacity, reserve, offset)) return;
    uint aux_count = 0u;
    for (int layer = int(leaf_log) - 1; layer >= 0; --layer) {
        uint previous_level = uint(layer) + 1u, next_count = 0u;
        ulong current = current_is_walk ? walk : scratch, next = current_is_walk ? scratch : walk;
        for (uint i = 0u; i < current_count;) {
            uint first = arena[current + i];
            bool pair = i + 1u < current_count && arena[current + i + 1u] == (first ^ 1u);
            if (!pair) {
                ulong source = decommit_trace_node_hash(arena, previous_level, first ^ 1u, leaf_log,
                    first_retained_log, retained_offsets, sparse_indices, sparse_hashes,
                    sparse_offsets, sparse_counts, sparse_level_count);
                if (source == 0xfffffffffffffffful) { arena[assembly + 7u] = 0u; return; }
                decommit_copy_hash(arena, assembly + hash_offset + hash_count * 8u, source);
                ++hash_count;
            }
            uint parent = first >> 1u;
            arena[next + next_count++] = parent;
            for (uint child = 2u * parent; child <= 2u * parent + 1u; ++child) {
                ulong source = decommit_trace_node_hash(arena, previous_level, child, leaf_log,
                    first_retained_log, retained_offsets, sparse_indices, sparse_hashes,
                    sparse_offsets, sparse_counts, sparse_level_count);
                if (source == 0xfffffffffffffffful) { arena[assembly + 7u] = 0u; return; }
                ulong entry = assembly + ulong(aux_offset + aux_count * 10u);
                arena[entry] = previous_level; arena[entry + 1u] = child;
                decommit_copy_hash(arena, entry + 2u, source);
                ++aux_count;
            }
            i += pair ? 2u : 1u;
        }
        current_is_walk = !current_is_walk;
        current_count = next_count;
    }
    uint compact_aux = hash_offset + hash_count * 8u;
    for (uint i = 0u; i < aux_count * 10u; ++i) arena[assembly + compact_aux + i] = arena[assembly + aux_offset + i];
    arena[assembly + 7u] = compact_aux + aux_count * 10u;
    arena[meta] = 0u; arena[meta + 1u] = role;
    arena[meta + 6u] = 0u; arena[meta + 7u] = 0u;
    arena[meta + 8u] = hash_offset; arena[meta + 9u] = hash_count;
    arena[meta + 10u] = compact_aux; arena[meta + 11u] = aux_count;
    arena[meta + 12u] = 0u; arena[meta + 13u] = 0u;
    arena[meta + 14u] = leaf_log; arena[meta + 15u] = arena[assembly + 7u] - tree_start;
}

kernel void stwo_zig_decommit_assemble_fri_resident(
    device uint *arena [[buffer(0)]],
    constant uint &tree_index [[buffer(1)]], constant uint &leaf_log [[buffer(2)]],
    constant ulong &tree_queries [[buffer(3)]], constant ulong &tree_count_at [[buffer(4)]],
    constant ulong &expanded [[buffer(5)]], constant ulong &expanded_count_at [[buffer(6)]],
    constant ulong &values [[buffer(7)]], constant ulong &walk [[buffer(8)]],
    constant ulong &scratch [[buffer(9)]], constant ulong &walk_count_at [[buffer(10)]],
    constant ulong &retained_offsets [[buffer(11)]], constant ulong &assembly [[buffer(12)]],
    constant uint &capacity [[buffer(13)]], uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u || arena[assembly + 7u] == 0u) return;
    ulong meta = assembly + 8ul + ulong(tree_index) * 16ul;
    uint tree_start = arena[assembly + 7u];
    uint query_count = arena[tree_count_at], expanded_count = arena[expanded_count_at], offset = 0u;
    if (!decommit_reserve(arena, assembly, capacity, query_count, offset)) return;
    arena[meta + 2u] = offset; arena[meta + 3u] = query_count;
    for (uint i = 0u; i < query_count; ++i) arena[assembly + offset + i] = arena[tree_queries + i];

    uint witness_count = 0u;
    for (uint i = 0u; i < expanded_count; ++i)
        witness_count += decommit_contains_sorted(arena, tree_queries, query_count, arena[expanded + i]) ? 0u : 1u;
    if (!decommit_reserve(arena, assembly, capacity, 4u * witness_count, offset)) return;
    arena[meta + 6u] = offset; arena[meta + 7u] = witness_count;
    uint witness = 0u;
    for (uint i = 0u; i < expanded_count; ++i) {
        if (decommit_contains_sorted(arena, tree_queries, query_count, arena[expanded + i])) continue;
        for (uint c = 0u; c < 4u; ++c) arena[assembly + offset + 4u * witness + c] = arena[values + 4u * i + c];
        ++witness;
    }

    uint current_count = arena[walk_count_at];
    bool current_is_walk = true;
    uint hash_offset = arena[assembly + 7u];
    uint aux_offset = hash_offset + leaf_log * current_count * 8u;
    uint reserve = leaf_log * current_count * 28u;
    if (!decommit_reserve(arena, assembly, capacity, reserve, offset)) return;
    uint hash_count = 0u, aux_count = 0u;
    for (int layer = int(leaf_log) - 1; layer >= 0; --layer) {
        uint previous_level = uint(layer) + 1u, next_count = 0u;
        ulong current = current_is_walk ? walk : scratch;
        ulong next = current_is_walk ? scratch : walk;
        for (uint i = 0u; i < current_count;) {
            uint first = arena[current + i];
            bool pair = i + 1u < current_count && arena[current + i + 1u] == (first ^ 1u);
            if (!pair) {
                ulong source = decommit_wide_word_offset(arena, retained_offsets, previous_level) +
                    ulong(first ^ 1u) * 8ul;
                decommit_copy_hash(arena, assembly + hash_offset + hash_count * 8u, source);
                ++hash_count;
            }
            uint parent = first >> 1u;
            arena[next + next_count++] = parent;
            for (uint child = 2u * parent; child <= 2u * parent + 1u; ++child) {
                ulong entry = assembly + ulong(aux_offset + aux_count * 10u);
                arena[entry] = previous_level; arena[entry + 1u] = child;
                ulong source = decommit_wide_word_offset(arena, retained_offsets, previous_level) +
                    ulong(child) * 8ul;
                decommit_copy_hash(arena, entry + 2u, source);
                ++aux_count;
            }
            i += pair ? 2u : 1u;
        }
        current_is_walk = !current_is_walk;
        current_count = next_count;
    }
    uint compact_aux = hash_offset + hash_count * 8u;
    for (uint i = 0u; i < aux_count * 10u; ++i) arena[assembly + compact_aux + i] = arena[assembly + aux_offset + i];
    arena[assembly + 7u] = compact_aux + aux_count * 10u;

    if (!decommit_reserve(arena, assembly, capacity, expanded_count * 5u, offset)) return;
    arena[meta + 12u] = offset; arena[meta + 13u] = expanded_count;
    for (uint i = 0u; i < expanded_count; ++i) {
        arena[assembly + offset + 5u * i] = arena[expanded + i];
        for (uint c = 0u; c < 4u; ++c) arena[assembly + offset + 5u * i + 1u + c] = arena[values + 4u * i + c];
    }
    arena[meta] = 1u; arena[meta + 1u] = tree_index;
    arena[meta + 4u] = 0u; arena[meta + 5u] = 0u;
    arena[meta + 8u] = hash_offset; arena[meta + 9u] = hash_count;
    arena[meta + 10u] = compact_aux; arena[meta + 11u] = aux_count;
    arena[meta + 14u] = leaf_log; arena[meta + 15u] = arena[assembly + 7u] - tree_start;
}
