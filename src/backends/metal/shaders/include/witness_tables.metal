#ifndef STWO_ZIG_WITNESS_TABLES_METAL
#define STWO_ZIG_WITNESS_TABLES_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/witness_abi.metal"
#endif
inline uint witness_table_limb(device uint *arena, constant WitnessArgs &args, uint encoded_id, uint limb) {
    uint tag = encoded_id >> 30u, value = encoded_id & 0x3fffffffu;
    if (tag == 1u) {
        return value < arena[args.table_strides + 1u]
            ? arena[arena[args.table_offsets + 1u + limb] + value] : 0u;
    }
    return limb < 8u && value < arena[args.table_strides + 2u]
        ? arena[arena[args.table_offsets + 29u + limb] + value] : 0u;
}

#endif
