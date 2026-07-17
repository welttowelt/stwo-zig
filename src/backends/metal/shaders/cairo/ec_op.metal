#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/felt252.metal"
#include "stwo_zig/ec.metal"
#endif

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
kernel void stwo_zig_ec_op_lookup(
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
    EcPointMetal accumulator_affine, q_affine;
    uint base = arena[segment_offset] + 7u * row;
    uint address_offset = execution_offsets[0];

    uint id = arena[address_offset + base];
    Felt252Metal standard = ec_load_memory(arena, execution_offsets, id, limbs);
    ec_store_address_lookup(arena, lookup, rows, row, 0, base, id);
    ec_store_big_lookup(arena, lookup, rows, row, 3, id, limbs);
    accumulator_affine.x = felt_to_montgomery(standard);

    id = arena[address_offset + base + 1u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    ec_store_address_lookup(arena, lookup, rows, row, 33, base + 1u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 36, id, limbs);
    accumulator_affine.y = felt_to_montgomery(standard);

    id = arena[address_offset + base + 2u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    ec_store_address_lookup(arena, lookup, rows, row, 66, base + 2u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 69, id, limbs);
    q_affine.x = felt_to_montgomery(standard);

    id = arena[address_offset + base + 3u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    ec_store_address_lookup(arena, lookup, rows, row, 99, base + 3u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 102, id, limbs);
    q_affine.y = felt_to_montgomery(standard);

    id = arena[address_offset + base + 4u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    ec_store_address_lookup(arena, lookup, rows, row, 132, base + 4u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 135, id, limbs);
    for (uint word = 0; word < 9u; ++word) m[word] = limbs[3u * word] | (limbs[3u * word + 1u] << 9u) | (limbs[3u * word + 2u] << 18u);
    m[9] = limbs[27];
    uint ms_is_max = limbs[27] == 256u, ms_mid_max = ms_is_max && limbs[21] == 136u;
    uint rc0 = limbs[27] - ms_is_max, rc1 = ms_is_max * (120u + limbs[21] - ms_mid_max);
    ec_store_lookup(arena, lookup, rows, row, 165, 1420243005u); ec_store_lookup(arena, lookup, rows, row, 166, rc0);
    ec_store_lookup(arena, lookup, rows, row, 167, 1420243005u); ec_store_lookup(arena, lookup, rows, row, 168, rc1);
    uint counter = 26u;
    ec_store_partial_lookup(arena, lookup, rows, row, 169, row, 0, m, q_affine, accumulator_affine, counter);

    EcProjectiveMetal accumulator = ec_projective_from_affine(accumulator_affine);
    EcProjectiveMetal q = ec_projective_from_affine(q_affine);
    for (uint round = 0; round < 252u; ++round) {
        if ((m[0] & 1u) != 0u) accumulator = ec_projective_add(accumulator, q);
        q = ec_projective_double(q);
        if (counter == 0u) {
            for (uint word = 0; word + 1u < 10u; ++word) m[word] = m[word + 1u];
            m[9] = 0u; counter = 26u;
        } else { m[0] >>= 1u; --counter; }
    }

    Felt252Metal product = felt_mont_mul(q.z, accumulator.z);
    prefix_products[local_row] = product;
    suffix_products[local_row] = product;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint group_start = group * group_size, group_rows = min(group_size, rows - group_start);
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
        total_inverse = ec_felt_inverse_252(total);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    Felt252Metal inverse = total_inverse;
    Felt252Metal inverse_product = felt_mont_mul(felt_mont_mul(inverse, preceding), following);
    q_affine = ec_projective_to_affine(q, felt_mont_mul(accumulator.z, inverse_product));
    accumulator_affine = ec_projective_to_affine(accumulator, felt_mont_mul(q.z, inverse_product));

    ec_store_partial_lookup(arena, lookup, rows, row, 295, row, 252u, m, q_affine, accumulator_affine, counter);
    uint result_x_id = arena[address_offset + base + 5u];
    ec_store_address_lookup(arena, lookup, rows, row, 421, base + 5u, result_x_id);
    standard = felt_from_montgomery(accumulator_affine.x); felt_to_m31_words(standard, limbs);
    ec_store_big_lookup(arena, lookup, rows, row, 424, result_x_id, limbs);
    uint result_y_id = arena[address_offset + base + 6u];
    ec_store_address_lookup(arena, lookup, rows, row, 454, base + 6u, result_y_id);
    standard = felt_from_montgomery(accumulator_affine.y); felt_to_m31_words(standard, limbs);
    ec_store_big_lookup(arena, lookup, rows, row, 457, result_y_id, limbs);
    ec_store_lookup(arena, lookup, rows, row, 487, 1u);
    (void)trace_offsets; (void)partial_offsets; (void)multiplicity_offsets;
}

kernel void stwo_zig_ec_op_witness(
    device uint *arena [[buffer(0)]], device const uint *execution_offsets [[buffer(1)]],
    device const uint *trace_offsets [[buffer(2)]], device const uint *partial_offsets [[buffer(3)]],
    device const uint *multiplicity_offsets [[buffer(4)]], constant uint *params [[buffer(5)]],
    uint row [[thread_position_in_grid]], uint local_row [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]], uint group_size [[threads_per_threadgroup]]
) {
    uint lookup = params[4] != 0u ? params[0] : 0xffffffffu;
    bool write_base = params[5] != 0u;
    uint segment_offset = params[1], rows = params[3];
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
    if (write_base) {
        arena[trace_offsets[0] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 1, row, limbs);
        ec_count_memory(arena, multiplicity_offsets, base, id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 0, base, id);
    ec_store_big_lookup(arena, lookup, rows, row, 3, id, limbs); accumulator.x = felt_to_montgomery(standard);

    id = arena[address_offset + base + 1u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    if (write_base) {
        arena[trace_offsets[29] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 30, row, limbs);
        ec_count_memory(arena, multiplicity_offsets, base + 1u, id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 33, base + 1u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 36, id, limbs); accumulator.y = felt_to_montgomery(standard);

    id = arena[address_offset + base + 2u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    if (write_base) {
        arena[trace_offsets[58] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 59, row, limbs);
        ec_count_memory(arena, multiplicity_offsets, base + 2u, id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 66, base + 2u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 69, id, limbs); q.x = felt_to_montgomery(standard);

    id = arena[address_offset + base + 3u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    if (write_base) {
        arena[trace_offsets[87] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 88, row, limbs);
        ec_count_memory(arena, multiplicity_offsets, base + 3u, id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 99, base + 3u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 102, id, limbs); q.y = felt_to_montgomery(standard);

    id = arena[address_offset + base + 4u]; standard = ec_load_memory(arena, execution_offsets, id, limbs);
    if (write_base) {
        arena[trace_offsets[116] + row] = id; ec_store_trace_limbs(arena, trace_offsets, 117, row, limbs);
        ec_count_memory(arena, multiplicity_offsets, base + 4u, id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 132, base + 4u, id);
    ec_store_big_lookup(arena, lookup, rows, row, 135, id, limbs);
    for (uint word = 0; word < 9u; ++word) m[word] = limbs[3u * word] | (limbs[3u * word + 1u] << 9u) | (limbs[3u * word + 2u] << 18u);
    m[9] = limbs[27];
    uint ms_is_max = limbs[27] == 256u, ms_mid_max = ms_is_max && limbs[21] == 136u;
    uint rc0 = limbs[27] - ms_is_max, rc1 = ms_is_max * (120u + limbs[21] - ms_mid_max);
    if (write_base) {
        arena[trace_offsets[145] + row] = ms_is_max; arena[trace_offsets[146] + row] = ms_mid_max; arena[trace_offsets[147] + row] = rc1;
        atomic_fetch_add_explicit((device atomic_uint *)&arena[multiplicity_offsets[3] + rc0], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit((device atomic_uint *)&arena[multiplicity_offsets[3] + rc1], 1u, memory_order_relaxed);
    }
    ec_store_lookup(arena, lookup, rows, row, 165, 1420243005u); ec_store_lookup(arena, lookup, rows, row, 166, rc0);
    ec_store_lookup(arena, lookup, rows, row, 167, 1420243005u); ec_store_lookup(arena, lookup, rows, row, 168, rc1);
    uint counter = 26u;
    ec_store_partial_lookup(arena, lookup, rows, row, 169, row, 0, m, q, accumulator, counter);

    uint group_start = group * group_size, group_rows = min(group_size, rows - group_start);
    for (uint round = 0; round < 252u; ++round) {
        if (write_base) ec_store_partial(arena, partial_offsets, round * rows + row, row, round, m, q, accumulator, counter, 1u);
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
    }

    if (write_base) {
        for (uint word = 0; word < 10u; ++word) arena[trace_offsets[148u + word] + row] = m[word];
        Felt252Metal finals[4] = { q.x, q.y, accumulator.x, accumulator.y };
        const uint trace_starts[4] = { 158u, 186u, 214u, 242u };
        for (uint value_index = 0; value_index < 4u; ++value_index) {
            standard = felt_from_montgomery(finals[value_index]); felt_to_m31_words(standard, limbs);
            ec_store_trace_limbs(arena, trace_offsets, trace_starts[value_index], row, limbs);
        }
        arena[trace_offsets[270] + row] = counter;
    }
    ec_store_partial_lookup(arena, lookup, rows, row, 295, row, 252u, m, q, accumulator, counter);
    uint result_x_id = arena[address_offset + base + 5u];
    if (write_base) {
        arena[trace_offsets[271] + row] = result_x_id;
        ec_count_memory(arena, multiplicity_offsets, base + 5u, result_x_id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 421, base + 5u, result_x_id);
    standard = felt_from_montgomery(accumulator.x); felt_to_m31_words(standard, limbs); ec_store_big_lookup(arena, lookup, rows, row, 424, result_x_id, limbs);
    uint result_y_id = arena[address_offset + base + 6u];
    if (write_base) {
        arena[trace_offsets[272] + row] = result_y_id;
        ec_count_memory(arena, multiplicity_offsets, base + 6u, result_y_id);
    }
    ec_store_address_lookup(arena, lookup, rows, row, 454, base + 6u, result_y_id);
    standard = felt_from_montgomery(accumulator.y); felt_to_m31_words(standard, limbs); ec_store_big_lookup(arena, lookup, rows, row, 457, result_y_id, limbs);
    ec_store_lookup(arena, lookup, rows, row, 487, 1u);
}

kernel void stwo_zig_ec_op_base_finalize(
    device uint *arena [[buffer(0)]],
    device const uint *partial_offsets [[buffer(1)]],
    constant uint *params [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint rows = params[3];
    uint pad = position.x, column = position.y;
    uint padding_rows = 4u * rows;
    if (pad >= padding_rows || column >= 126u) return;
    uint destination = 252u * rows + pad;
    arena[partial_offsets[column] + destination] = column < 125u
        ? arena[partial_offsets[column] + (pad & 15u)]
        : 0u;
    if (column == 125u) {
        for (uint index = pad; index < 256u * rows; index += padding_rows) {
            arena[partial_offsets[126] + index] = index;
        }
    }
}
