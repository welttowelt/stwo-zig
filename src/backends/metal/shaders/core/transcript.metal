#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/blake2s.metal"
#endif

inline void transcript_hash_digest_words(
    device uint *arena, uint state_base, uint source_base, uint source_words
) {
    uint hash[8], block[16];
    blake2s_init_hash(hash);
    uint total_words = 8u + source_words;
    uint total_bytes = total_words * 4u;
    uint consumed = 0u;
    while (consumed < total_words) {
        uint count = min(16u, total_words - consumed);
        for (uint i = 0u; i < 16u; ++i) block[i] = 0u;
        for (uint i = 0u; i < count; ++i) {
            uint at = consumed + i;
            block[i] = at < 8u ? arena[state_base + at] : arena[source_base + at - 8u];
        }
        consumed += count;
        blake2s_compress(hash, block, min(consumed * 4u, total_bytes), consumed == total_words);
    }
    for (uint i = 0u; i < 8u; ++i) arena[state_base + i] = hash[i];
    arena[state_base + 8u] = 0u;
}

inline void transcript_draw_words(device uint *arena, uint state_base, uint counter, thread uint *output) {
    uint hash[8], block[16];
    blake2s_init_hash(hash);
    for (uint i = 0u; i < 16u; ++i) block[i] = 0u;
    for (uint i = 0u; i < 8u; ++i) block[i] = arena[state_base + i];
    block[8] = counter;
    blake2s_compress(hash, block, 37u, true);
    for (uint i = 0u; i < 8u; ++i) output[i] = hash[i];
}

inline void transcript_draw_secure_felts(
    device uint *arena, uint state_base, uint destination_base, uint felt_count
) {
    uint produced = 0u, target = felt_count * 4u;
    uint counter = arena[state_base + 8u];
    while (produced < target) {
        uint words[8];
        bool accepted = false;
        for (uint attempt = 0u; attempt < 64u; ++attempt) {
            transcript_draw_words(arena, state_base, counter++, words);
            accepted = true;
            for (uint i = 0u; i < 8u; ++i) accepted = accepted && words[i] < 0xfffffffeu;
            if (accepted) break;
        }
        if (!accepted) {
            arena[state_base + 9u] = 1u;
            arena[state_base + 8u] = counter;
            return;
        }
        for (uint i = 0u; i < 8u && produced < target; ++i) {
            arena[destination_base + produced] = words[i] >= 0x7fffffffu ? words[i] - 0x7fffffffu : words[i];
            ++produced;
        }
    }
    arena[state_base + 8u] = counter;
}

kernel void stwo_zig_transcript_init_resident(
    device uint *arena [[buffer(0)]], constant uint &state_base [[buffer(1)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    for (uint i = 0u; i < 9u; ++i) arena[state_base + i] = 0u;
}

kernel void stwo_zig_transcript_mix_resident(
    device uint *arena [[buffer(0)]], constant uint &state_base [[buffer(1)]],
    constant uint &source_base [[buffer(2)]], constant uint &source_words [[buffer(3)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    transcript_hash_digest_words(arena, state_base, source_base, source_words);
}

kernel void stwo_zig_transcript_draw_secure_resident(
    device uint *arena [[buffer(0)]], constant uint &state_base [[buffer(1)]],
    constant uint &destination_base [[buffer(2)]], constant uint &felt_count [[buffer(3)]],
    uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    transcript_draw_secure_felts(arena, state_base, destination_base, felt_count);
}

kernel void stwo_zig_blake2s_parent_tail_sparse(
    device uint *arena [[buffer(0)]], constant uint *child_offsets [[buffer(1)]],
    constant uint *destination_offsets [[buffer(2)]], constant uint *parent_counts [[buffer(3)]],
    constant uint &level_count [[buffer(4)]], constant uint *node_seed [[buffer(5)]],
    constant uint &prefix_bytes [[buffer(6)]], constant uint *transcript_config [[buffer(7)]],
    threadgroup uint *hashes [[threadgroup(0)]], uint thread_index [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]]
) {
    if (level_count == 0u) return;
    for (uint level = 0u; level < level_count; ++level) {
        uint parent_count = parent_counts[level];
        uint message[16];
        if (thread_index < parent_count) {
            if (level == 0u) {
                // Each threadgroup owns one contiguous bottom subtree.
                uint source = child_offsets[0] +
                    (group * parent_count + thread_index) * 16u;
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
            uint destination = destination_offsets[level] +
                (group * parent_count + thread_index) * 8u;
            for (uint i = 0u; i < 8u; ++i) {
                hashes[thread_index * 8u + i] = state[i];
                arena[destination + i] = state[i];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (transcript_config[2] == 0u || group != 0u ||
        parent_counts[level_count - 1u] != 1u || thread_index != 0u) return;
    uint state_base = transcript_config[0], alpha_base = transcript_config[1];
    uint digest[8], block[16];
    blake2s_init_hash(digest);
    for (uint i = 0u; i < 8u; ++i) {
        block[i] = arena[state_base + i];
        block[i + 8u] = hashes[i];
    }
    blake2s_compress(digest, block, 64u, true);
    for (uint i = 0u; i < 8u; ++i) arena[state_base + i] = digest[i];
    arena[state_base + 8u] = 0u;
    transcript_draw_secure_felts(arena, state_base, alpha_base, 1u);
}

kernel void stwo_zig_transcript_draw_queries_resident(
    device uint *arena [[buffer(0)]], constant uint &state_base [[buffer(1)]],
    constant uint &destination_base [[buffer(2)]], constant uint &log_domain_size [[buffer(3)]],
    constant uint &query_count [[buffer(4)]], uint lane [[thread_position_in_grid]]
) {
    if (lane != 0u) return;
    uint mask = log_domain_size == 0u ? 0u : ((1u << log_domain_size) - 1u);
    uint produced = 0u;
    uint counter = arena[state_base + 8u];
    while (produced < query_count) {
        uint words[8];
        transcript_draw_words(arena, state_base, counter++, words);
        for (uint i = 0u; i < 8u && produced < query_count; ++i)
            arena[destination_base + produced++] = words[i] & mask;
    }
    arena[state_base + 8u] = counter;
}
