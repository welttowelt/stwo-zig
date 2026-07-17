#ifndef STWO_ZIG_CIRCLE_METAL
#define STWO_ZIG_CIRCLE_METAL

#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#endif

struct CircleM31Value { uint x, y; };

inline uint circle_twiddle(device const uint *twiddles, uint index) {
    uint pair = index >> 2u;
    switch (index & 3u) {
        case 0u: return twiddles[2u * pair + 1u];
        case 1u: return m31_neg(twiddles[2u * pair + 1u]);
        case 2u: return m31_neg(twiddles[2u * pair]);
        default: return twiddles[2u * pair];
    }
}

inline CircleM31Value circle_mul(CircleM31Value lhs, CircleM31Value rhs) {
    return {
        m31_sub(m31_mul(lhs.x, rhs.x), m31_mul(lhs.y, rhs.y)),
        m31_add(m31_mul(lhs.x, rhs.y), m31_mul(lhs.y, rhs.x)),
    };
}

inline CircleM31Value circle_pow(uint exponent) {
    CircleM31Value result = { 1u, 0u };
    CircleM31Value base = { 2u, 1268011823u };
    while (exponent != 0u) {
        if ((exponent & 1u) != 0u) result = circle_mul(result, base);
        base = circle_mul(base, base);
        exponent >>= 1u;
    }
    return result;
}

#endif
