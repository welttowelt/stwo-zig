#ifndef STWO_ZIG_DECOMMIT_METAL
#define STWO_ZIG_DECOMMIT_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

inline uint decommit_sort_unique(device uint *values, uint count) {
    for (uint i = 1u; i < count; ++i) {
        uint value = values[i], j = i;
        while (j != 0u && values[j - 1u] > value) {
            values[j] = values[j - 1u];
            --j;
        }
        values[j] = value;
    }
    uint unique = 0u;
    for (uint i = 0u; i < count; ++i) {
        if (unique == 0u || values[i] != values[unique - 1u]) values[unique++] = values[i];
    }
    return unique;
}

inline uint decommit_map_query_log(uint position, uint source_log, uint target_log) {
    if (source_log < target_log) return ((position >> 1u) << (target_log - source_log + 1u)) | (position & 1u);
    return ((position >> (source_log - target_log + 1u)) << 1u) | (position & 1u);
}

inline ulong decommit_join_word_offset(uint low, uint high) {
    return ulong(low) | (ulong(high) << 32u);
}

inline ulong decommit_wide_word_offset(device uint *arena, ulong base, uint index) {
    ulong entry = base + 2ul * ulong(index);
    return decommit_join_word_offset(arena[entry], arena[entry + 1u]);
}

inline bool decommit_contains_sorted(device uint *arena, ulong base, uint count, uint target) {
    uint lo = 0u, hi = count;
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1u);
        if (arena[base + mid] < target) lo = mid + 1u; else hi = mid;
    }
    return lo < count && arena[base + lo] == target;
}

inline bool decommit_reserve(device uint *arena, ulong assembly, uint capacity, uint count, thread uint &offset) {
    uint cursor = arena[assembly + 7u];
    if (cursor > capacity || count > capacity - cursor) {
        arena[assembly + 7u] = 0u;
        return false;
    }
    offset = cursor;
    arena[assembly + 7u] = cursor + count;
    return true;
}

inline void decommit_copy_hash(device uint *arena, ulong destination, ulong source) {
    for (uint word = 0u; word < 8u; ++word) arena[destination + word] = arena[source + ulong(word)];
}

inline ulong decommit_trace_node_hash(
    device uint *arena, uint level, uint index, uint leaf_log, uint first_retained_log,
    ulong retained_offsets, ulong sparse_indices, ulong sparse_hashes,
    ulong sparse_offsets, ulong sparse_counts, uint sparse_level_count
) {
    if (level <= first_retained_log)
        return decommit_wide_word_offset(arena, retained_offsets, level) + ulong(index) * 8ul;
    uint distance = leaf_log - level;
    if (distance >= sparse_level_count) return 0xfffffffffffffffful;
    uint offset = arena[sparse_offsets + distance], lo = 0u, hi = arena[sparse_counts + distance];
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1u), current = arena[sparse_indices + offset + mid];
        if (current < index) lo = mid + 1u; else hi = mid;
    }
    if (lo >= arena[sparse_counts + distance] || arena[sparse_indices + offset + lo] != index)
        return 0xfffffffffffffffful;
    return sparse_hashes + ulong(offset + lo) * 8ul;
}

#endif
