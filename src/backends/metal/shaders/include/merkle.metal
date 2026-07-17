#ifndef STWO_ZIG_MERKLE_METAL
#define STWO_ZIG_MERKLE_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

inline uint lifted_index(uint index, uint log_ratio) {
    if (log_ratio == 0u) return index;
    return ((index >> (log_ratio + 1u)) << 1u) | (index & 1u);
}

inline uint decommit_lifted_index(uint position, uint lifting_log, uint column_log) {
    uint shift = lifting_log - column_log;
    return shift == 0u ? position : ((position >> (shift + 1u)) << 1u) + (position & 1u);
}

#endif
