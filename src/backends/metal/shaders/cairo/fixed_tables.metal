#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

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
