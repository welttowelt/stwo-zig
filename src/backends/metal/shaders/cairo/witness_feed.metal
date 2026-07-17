#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

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
