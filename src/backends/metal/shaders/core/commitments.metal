#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/blake2s.metal"
#include "stwo_zig/merkle.metal"
#include "stwo_zig/extension_fields.metal"
#endif

inline Qm31Value fri_fused_fold_pair(
    Qm31Value left, Qm31Value right, uint inverse, Qm31Value alpha
) {
    return qm_add(qm_add(left, right), qm_mul(alpha, qm_mul_m31(qm_sub(left, right), inverse)));
}

inline void fri_store_coordinates_and_leaf(
    device uint *coordinates, device uint *leaves, uint value_count, uint index,
    Qm31Value value, constant uint *leaf_seed, uint prefix_bytes
) {
    coordinates[index] = value.a;
    coordinates[value_count + index] = value.b;
    coordinates[2u * value_count + index] = value.c;
    coordinates[3u * value_count + index] = value.d;

    uint state[8], message[16];
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, leaf_seed);
    message[0] = value.a;
    message[1] = value.b;
    message[2] = value.c;
    message[3] = value.d;
    for (uint word = 4u; word < 16u; ++word) message[word] = 0u;
    blake2s_compress(state, message, prefix_bytes + 16u, true);
    for (uint word = 0u; word < 8u; ++word) leaves[index * 8u + word] = state[word];
}

kernel void stwo_zig_qm31_to_coordinates(
    device const Qm31Value *source [[buffer(0)]],
    device uint *coordinates [[buffer(1)]],
    constant uint &value_count [[buffer(2)]],
    device uint *leaves [[buffer(3)]],
    constant uint *leaf_seed [[buffer(4)]],
    constant uint &prefix_bytes [[buffer(5)]],
    constant uint &write_leaf [[buffer(6)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= value_count) return;
    Qm31Value value = source[index];
    if (write_leaf != 0u)
        fri_store_coordinates_and_leaf(
            coordinates, leaves, value_count, index, value, leaf_seed, prefix_bytes
        );
    else {
        coordinates[index] = value.a;
        coordinates[value_count + index] = value.b;
        coordinates[2u * value_count + index] = value.c;
        coordinates[3u * value_count + index] = value.d;
    }
}

kernel void stwo_zig_fri_fold_line(
    device const Qm31Value *source [[buffer(0)]],
    device const uint *inverse_x [[buffer(1)]],
    constant Qm31Value &alpha [[buffer(2)]],
    device Qm31Value *destination [[buffer(3)]],
    constant uint &destination_count [[buffer(4)]],
    device uint *coordinates [[buffer(5)]],
    device uint *leaves [[buffer(6)]],
    constant uint *leaf_seed [[buffer(7)]],
    constant uint &prefix_bytes [[buffer(8)]],
    constant uint &prepare_next [[buffer(9)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= destination_count) return;
    Qm31Value value = fri_fused_fold_pair(
        source[index << 1u], source[(index << 1u) + 1u], inverse_x[index], alpha
    );
    destination[index] = value;
    if (prepare_next != 0u)
        fri_store_coordinates_and_leaf(
            coordinates, leaves, destination_count, index, value, leaf_seed, prefix_bytes
        );
}

kernel void stwo_zig_blake2s_leaves(
    device const uint *flat_columns [[buffer(0)]],
    device const uint *column_offsets [[buffer(1)]],
    device const uint *column_log_sizes [[buffer(2)]],
    device uint *destination [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    constant uint &lifting_log_size [[buffer(5)]],
    constant uint *leaf_seed [[buffer(6)]],
    constant uint &prefix_bytes [[buffer(7)]],
    uint row [[thread_position_in_grid]]
) {
    uint row_count = 1u << lifting_log_size;
    if (row >= row_count) return;

    uint state[8];
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, leaf_seed);

    uint message[16];
    uint in_block = 0u;
    uint total_bytes = prefix_bytes;
    for (uint column = 0; column < column_count; ++column) {
        uint log_size = column_log_sizes[column];
        uint source = lifted_index(row, lifting_log_size - log_size);
        message[in_block++] = flat_columns[column_offsets[column] + source];
        total_bytes += 4u;
        if (in_block == 16u) {
            bool last = column + 1u == column_count;
            blake2s_compress(state, message, total_bytes, last);
            in_block = 0u;
        }
    }
    if (in_block != 0u) {
        for (uint i = in_block; i < 16u; ++i) message[i] = 0u;
        blake2s_compress(state, message, total_bytes, true);
    }
    uint base = row * 8u;
    for (uint i = 0; i < 8u; ++i) destination[base + i] = state[i];
}

kernel void stwo_zig_blake2s_leaf_absorb_resident(
    device uint *arena [[buffer(0)]], constant uint *column_offsets [[buffer(1)]],
    constant uint *column_logs [[buffer(2)]], constant uint &column_count [[buffer(3)]],
    constant uint &state_offset [[buffer(4)]], constant uint &lifting_log [[buffer(5)]],
    constant uint &first_column [[buffer(6)]], constant uint &is_final [[buffer(7)]],
    constant uint &prefix_bytes [[buffer(8)]], constant uint *leaf_seed [[buffer(9)]],
    uint row [[thread_position_in_grid]]
) {
    uint row_count = 1u << lifting_log;
    if (row >= row_count || column_count == 0u || column_count > 16u) return;
    uint state[8], message[16];
    if (first_column == 0u) {
        if (prefix_bytes == 0u) blake2s_init_hash(state);
        else blake2s_init_seeded(state, leaf_seed);
    }
    else for (uint i = 0u; i < 8u; ++i) state[i] = arena[state_offset + row * 8u + i];
    for (uint i = 0u; i < column_count; ++i)
        message[i] = arena[column_offsets[i] + lifted_index(row, lifting_log - column_logs[i])];
    for (uint i = column_count; i < 16u; ++i) message[i] = 0u;
    blake2s_compress(state, message, prefix_bytes + (first_column + column_count) * 4u, is_final != 0u);
    for (uint i = 0u; i < 8u; ++i) arena[state_offset + row * 8u + i] = state[i];
}

kernel void stwo_zig_blake2s_leaf_absorb_compact_resident(
    device uint *arena [[buffer(0)]], constant uint *column_offsets [[buffer(1)]],
    constant uint *column_logs [[buffer(2)]], constant uint &column_count [[buffer(3)]],
    constant uint &source_state_offset [[buffer(4)]], constant uint &source_state_log [[buffer(5)]],
    constant uint &destination_state_offset [[buffer(6)]], constant uint &destination_log [[buffer(7)]],
    constant uint &first_column [[buffer(8)]], constant uint &is_final [[buffer(9)]],
    constant uint &prefix_bytes [[buffer(10)]], constant uint *leaf_seed [[buffer(11)]],
    uint row [[thread_position_in_grid]]
) {
    uint row_count = 1u << destination_log;
    if (row >= row_count || column_count == 0u || column_count > 16u) return;
    uint state[8], message[16];
    if (first_column == 0u) {
        if (prefix_bytes == 0u) blake2s_init_hash(state);
        else blake2s_init_seeded(state, leaf_seed);
    } else {
        uint source_row = lifted_index(row, destination_log - source_state_log);
        for (uint i = 0u; i < 8u; ++i)
            state[i] = arena[source_state_offset + source_row * 8u + i];
    }
    for (uint i = 0u; i < column_count; ++i)
        message[i] = arena[column_offsets[i] + lifted_index(row, destination_log - column_logs[i])];
    for (uint i = column_count; i < 16u; ++i) message[i] = 0u;
    blake2s_compress(state, message, prefix_bytes + (first_column + column_count) * 4u, is_final != 0u);
    for (uint i = 0u; i < 8u; ++i)
        arena[destination_state_offset + row * 8u + i] = state[i];
}

kernel void stwo_zig_blake2s_parents(
    device const uint *children [[buffer(0)]],
    device uint *destination [[buffer(1)]],
    constant uint &parent_count [[buffer(2)]],
    constant uint *node_seed [[buffer(3)]],
    constant uint &prefix_bytes [[buffer(4)]],
    uint parent [[thread_position_in_grid]]
) {
    if (parent >= parent_count) return;
    uint state[8];
    uint message[16];
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, node_seed);
    for (uint i = 0; i < 16u; ++i) message[i] = children[parent * 16u + i];
    blake2s_compress(state, message, prefix_bytes + 64u, true);
    for (uint i = 0; i < 8u; ++i) destination[parent * 8u + i] = state[i];
}

kernel void stwo_zig_blake2s_parents_sparse(
    device uint *arena [[buffer(0)]], constant uint &child_offset [[buffer(1)]],
    constant uint &destination_offset [[buffer(2)]], constant uint &parent_count [[buffer(3)]],
    constant uint *node_seed [[buffer(4)]], constant uint &prefix_bytes [[buffer(5)]],
    uint parent [[thread_position_in_grid]]
) {
    if (parent >= parent_count) return;
    uint state[8], message[16];
    if (prefix_bytes == 0u) blake2s_init_hash(state);
    else blake2s_init_seeded(state, node_seed);
    for (uint i = 0; i < 16u; ++i) message[i] = arena[child_offset + parent * 16u + i];
    blake2s_compress(state, message, prefix_bytes + 64u, true);
    for (uint i = 0; i < 8u; ++i) arena[destination_offset + parent * 8u + i] = state[i];
}

kernel void stwo_zig_blake2s_parent_tail_sparse(
    device uint *arena [[buffer(0)]], constant uint *child_offsets [[buffer(1)]],
    constant uint *destination_offsets [[buffer(2)]], constant uint *parent_counts [[buffer(3)]],
    constant uint &level_count [[buffer(4)]], constant uint *node_seed [[buffer(5)]],
    constant uint &prefix_bytes [[buffer(6)]],
    threadgroup uint *hashes [[threadgroup(0)]], uint thread_index [[thread_index_in_threadgroup]]
) {
    for (uint level = 0u; level < level_count; ++level) {
        uint parent_count = parent_counts[level];
        uint message[16];
        if (thread_index < parent_count) {
            if (level == 0u) {
                uint source = child_offsets[0] + thread_index * 16u;
                for (uint i = 0u; i < 16u; ++i) message[i] = arena[source + i];
            } else {
                uint source = thread_index * 16u;
                for (uint i = 0u; i < 16u; ++i) message[i] = hashes[source + i];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (thread_index < parent_count) {
            uint state[8];
            if (prefix_bytes == 0u) blake2s_init_hash(state);
            else blake2s_init_seeded(state, node_seed);
            blake2s_compress(state, message, prefix_bytes + 64u, true);
            uint destination = destination_offsets[level] + thread_index * 8u;
            for (uint i = 0u; i < 8u; ++i) {
                hashes[thread_index * 8u + i] = state[i];
                arena[destination + i] = state[i];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

kernel void stwo_zig_blake2s_parents_plain_sparse(
    device uint *arena [[buffer(0)]], constant uint &child_offset [[buffer(1)]],
    constant uint &destination_offset [[buffer(2)]], constant uint &parent_count [[buffer(3)]],
    uint parent [[thread_position_in_grid]]
) {
    if (parent >= parent_count) return;
    uint state[8], message[16]; blake2s_init_hash(state);
    for (uint i = 0u; i < 16u; ++i) message[i] = arena[child_offset + parent * 16u + i];
    blake2s_compress(state, message, 64u, true);
    for (uint i = 0u; i < 8u; ++i) arena[destination_offset + parent * 8u + i] = state[i];
}
