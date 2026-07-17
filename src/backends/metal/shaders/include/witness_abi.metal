#ifndef STWO_ZIG_WITNESS_ABI_METAL
#define STWO_ZIG_WITNESS_ABI_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif
struct WitnessArgs {
    uint input_offsets;
    uint table_offsets;
    uint table_strides;
    uint output_offsets;
    uint multiplicity_offsets;
    uint lookup_words;
    uint sub_words;
    uint row_count;
    uint pedersen_offsets;
    uint pedersen_rows;
    uint poseidon_keys;
};

#endif
