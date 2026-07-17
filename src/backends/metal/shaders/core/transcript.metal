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
