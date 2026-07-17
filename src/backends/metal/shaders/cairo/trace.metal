#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

kernel void stwo_zig_witness_input_gather_resident(
    device uint *arena [[buffer(0)]], constant uint *producer_offsets [[buffer(1)]],
    constant uint *edge_descriptors [[buffer(2)]], constant uint &edge_count [[buffer(3)]],
    constant uint &input_width [[buffer(4)]], constant uint &total_real_rows [[buffer(5)]],
    constant uint &consumer_rows [[buffer(6)]], constant uint *consumer_offsets [[buffer(7)]],
    constant uint &include_enabler [[buffer(8)]], constant uint &include_iota [[buffer(9)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= consumer_rows) return;
    uint source_global_row = row < total_real_rows ? row : (row & 15u);
    for (uint edge = 0u; edge < edge_count; ++edge) {
        constant uint *descriptor = edge_descriptors + edge * 5u;
        uint producer_rows = descriptor[0], edge_rows = producer_rows * descriptor[3], destination_offset = descriptor[4];
        if (source_global_row < destination_offset || source_global_row >= destination_offset + edge_rows) continue;
        uint local_row = source_global_row - destination_offset;
        uint instance = local_row / producer_rows, producer_row = local_row % producer_rows;
        for (uint word = 0u; word < input_width; ++word) {
            uint source_word = descriptor[1] + instance * descriptor[2] + word;
            arena[consumer_offsets[word] + row] = arena[producer_offsets[edge] + source_word * producer_rows + producer_row];
        }
        break;
    }
    uint tail = input_width;
    if (include_enabler != 0u) arena[consumer_offsets[tail++] + row] = uint(row < total_real_rows);
    if (include_iota != 0u) arena[consumer_offsets[tail] + row] = row;
}
kernel void stwo_zig_execution_table_split_resident(
    device uint *arena [[buffer(0)]], constant uint &source_offset [[buffer(1)]],
    constant uint &value_count [[buffer(2)]], constant uint &column_rows [[buffer(3)]],
    constant uint &source_words [[buffer(4)]], constant uint &limb_count [[buffer(5)]],
    constant uint *destination_offsets [[buffer(6)]], uint row [[thread_position_in_grid]]
) {
    if (row >= column_rows) return;
    uint words[8] = {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    if (row < value_count) {
        for (uint word = 0u; word < source_words; ++word)
            words[word] = arena[source_offset + row * source_words + word];
    }
    uint bits_left = 32u, word_index = 0u, word = words[0];
    for (uint limb = 0u; limb < limb_count; ++limb) {
        uint value;
        if (bits_left > 9u) {
            value = word & 0x1ffu;
            word >>= 9u;
            bits_left -= 9u;
        } else {
            value = word;
            word_index += 1u;
            word = word_index < source_words ? words[word_index] : 0u;
            if (bits_left < 9u) {
                value |= (word << bits_left) & 0x1ffu;
                word >>= 9u - bits_left;
            }
            bits_left += 23u;
        }
        arena[destination_offsets[limb] + row] = value;
    }
}

kernel void stwo_zig_memory_address_base_trace_resident(
    device uint *arena [[buffer(0)]], constant uint &raw_address_offset [[buffer(1)]],
    constant uint &address_count [[buffer(2)]], constant uint &multiplicity_offset [[buffer(3)]],
    constant uint &multiplicity_words [[buffer(4)]], constant uint &row_count [[buffer(5)]],
    constant uint *output_offsets [[buffer(6)]], uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    for (uint chunk = 0u; chunk < 16u; ++chunk) {
        uint index = chunk * row_count + row;
        arena[output_offsets[2u * chunk] + row] = index + 1u < address_count
            ? arena[raw_address_offset + index + 1u]
            : 0u;
        arena[output_offsets[2u * chunk + 1u] + row] = index < multiplicity_words
            ? arena[multiplicity_offset + index]
            : 0u;
    }
}

kernel void stwo_zig_memory_value_base_trace_resident(
    device uint *arena [[buffer(0)]], constant uint *source_offsets [[buffer(1)]],
    constant uint &limb_count [[buffer(2)]], constant uint &source_words [[buffer(3)]],
    constant uint &source_row_offset [[buffer(4)]], constant uint &multiplicity_offset [[buffer(5)]],
    constant uint &multiplicity_words [[buffer(6)]], constant uint &row_count [[buffer(7)]],
    constant uint *output_offsets [[buffer(8)]], uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    uint index = source_row_offset + row;
    for (uint limb = 0u; limb < limb_count; ++limb)
        arena[output_offsets[limb] + row] = index < source_words ? arena[source_offsets[limb] + index] : 0u;
    arena[output_offsets[limb_count] + row] = index < multiplicity_words
        ? arena[multiplicity_offset + index]
        : 0u;
}

kernel void stwo_zig_memory_rc99_count_resident(
    device uint *arena [[buffer(0)]], constant uint *limb_offsets [[buffer(1)]],
    constant uint &pair_count [[buffer(2)]], constant uint &row_count [[buffer(3)]],
    constant uint &lut_offset [[buffer(4)]], constant uint &table_size [[buffer(5)]],
    constant uint &count_offset [[buffer(6)]], uint row [[thread_position_in_grid]]
) {
    if (row >= row_count) return;
    device atomic_uint *counts = reinterpret_cast<device atomic_uint *>(arena + count_offset);
    for (uint pair = 0u; pair < pair_count; ++pair) {
        uint lhs = arena[limb_offsets[2u * pair] + row];
        uint rhs = arena[limb_offsets[2u * pair + 1u] + row];
        uint rc_row = arena[lut_offset + (lhs << 9u) + rhs];
        atomic_fetch_add_explicit(&counts[(pair & 7u) * table_size + rc_row], 1u, memory_order_relaxed);
    }
}

kernel void stwo_zig_public_memory_seed_resident(
    device uint *arena [[buffer(0)]], constant uint *address_id_pairs [[buffer(1)]],
    constant uint &entry_count [[buffer(2)]], constant uint &address_count_offset [[buffer(3)]],
    constant uint &address_count_words [[buffer(4)]], constant uint &big_count_offset [[buffer(5)]],
    constant uint &big_count_words [[buffer(6)]], constant uint &small_count_offset [[buffer(7)]],
    constant uint &small_count_words [[buffer(8)]], uint entry [[thread_position_in_grid]]
) {
    if (entry >= entry_count) return;
    uint address = address_id_pairs[2u * entry];
    uint id = address_id_pairs[2u * entry + 1u];
    device atomic_uint *address_counts = reinterpret_cast<device atomic_uint *>(arena + address_count_offset);
    if (address > 0u && address - 1u < address_count_words)
        atomic_fetch_add_explicit(&address_counts[address - 1u], 1u, memory_order_relaxed);
    uint tag = id >> 30u;
    uint index = id & 0x3fffffffu;
    if (tag == 0u && index < small_count_words) {
        device atomic_uint *counts = reinterpret_cast<device atomic_uint *>(arena + small_count_offset);
        atomic_fetch_add_explicit(&counts[index], 1u, memory_order_relaxed);
    } else if (tag == 1u && index < big_count_words) {
        device atomic_uint *counts = reinterpret_cast<device atomic_uint *>(arena + big_count_offset);
        atomic_fetch_add_explicit(&counts[index], 1u, memory_order_relaxed);
    }
}
