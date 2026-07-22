#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/extension_fields.metal"
#endif

kernel void stwo_zig_composition_expand_sparse(
    device uint *arena [[buffer(0)]], device const ulong *source_offsets [[buffer(1)]],
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

// Evaluates c_i - a_i^2 - b_i^2 constraints for every domain row and
// immediately folds them by the transcript powers. Columns remain in the
// page-colored commitment arena; adjacent GPU lanes walk adjacent rows.
kernel void stwo_zig_recurrence_composition(
    device const uint *trace [[buffer(0)]],
    device const uint *power_words [[buffer(1)]],
    device uint *output [[buffer(2)]],
    constant uint &row_count [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    constant uint &column_stride [[buffer(5)]],
    constant uint2 &denominator_inverses [[buffer(6)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    uint a = trace[row];
    uint b = trace[column_stride + row];
    Qm31Value row_evaluation = {0u, 0u, 0u, 0u};

    for (uint column = 2u; column < column_count; ++column) {
        uint c = trace[column * column_stride + row];
        uint constraint = m31_sub(c, m31_add(m31_mul(a, a), m31_mul(b, b)));
        uint power_offset = (column_count - 1u - column) * 4u;
        Qm31Value power = {
            power_words[power_offset],
            power_words[power_offset + 1u],
            power_words[power_offset + 2u],
            power_words[power_offset + 3u],
        };
        row_evaluation = qm_add(row_evaluation, qm_mul_m31(power, constraint));
        a = b;
        b = c;
    }

    uint denominator_inverse = denominator_inverses[row >= (row_count >> 1u)];
    row_evaluation = qm_mul_m31(row_evaluation, denominator_inverse);
    output[row] = row_evaluation.a;
    output[row_count + row] = row_evaluation.b;
    output[2u * row_count + row] = row_evaluation.c;
    output[3u * row_count + row] = row_evaluation.d;
}
