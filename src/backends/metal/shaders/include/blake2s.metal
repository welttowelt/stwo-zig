#ifndef STWO_ZIG_BLAKE2S_METAL
#define STWO_ZIG_BLAKE2S_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

constant uint blake2s_iv[8] = {
    0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
    0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u,
};

constant uchar blake2s_sigma[10][16] = {
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
};

inline uint rotr32(uint value, uint shift) {
    return (value >> shift) | (value << (32u - shift));
}

inline void blake2s_g(
    thread const uint *message,
    uint round,
    uint index,
    thread uint &a,
    thread uint &b,
    thread uint &c,
    thread uint &d
) {
    a = a + b + message[blake2s_sigma[round][2u * index]];
    d = rotr32(d ^ a, 16u);
    c += d;
    b = rotr32(b ^ c, 12u);
    a = a + b + message[blake2s_sigma[round][2u * index + 1u]];
    d = rotr32(d ^ a, 8u);
    c += d;
    b = rotr32(b ^ c, 7u);
}

inline void blake2s_compress(
    thread uint *state,
    thread const uint *message,
    uint total_bytes,
    bool is_last
) {
    uint v[16];
    for (uint i = 0; i < 8u; ++i) {
        v[i] = state[i];
        v[i + 8u] = blake2s_iv[i];
    }
    v[12] ^= total_bytes;
    if (is_last) v[14] ^= 0xFFFFFFFFu;

    for (uint round = 0; round < 10u; ++round) {
        blake2s_g(message, round, 0u, v[0], v[4], v[8], v[12]);
        blake2s_g(message, round, 1u, v[1], v[5], v[9], v[13]);
        blake2s_g(message, round, 2u, v[2], v[6], v[10], v[14]);
        blake2s_g(message, round, 3u, v[3], v[7], v[11], v[15]);
        blake2s_g(message, round, 4u, v[0], v[5], v[10], v[15]);
        blake2s_g(message, round, 5u, v[1], v[6], v[11], v[12]);
        blake2s_g(message, round, 6u, v[2], v[7], v[8], v[13]);
        blake2s_g(message, round, 7u, v[3], v[4], v[9], v[14]);
    }
    for (uint i = 0; i < 8u; ++i) state[i] ^= v[i] ^ v[i + 8u];
}

inline void blake2s_init_hash(thread uint *state) {
    for (uint i = 0u; i < 8u; ++i) state[i] = blake2s_iv[i];
    state[0] ^= 0x01010020u;
}

inline void blake2s_init_seeded(thread uint *state, constant uint *seed) {
    for (uint i = 0u; i < 8u; ++i) state[i] = seed[i];
}

#endif
