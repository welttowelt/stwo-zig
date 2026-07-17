#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#endif

// Prepared feeds flatten variable-sized clear ranges into exact linear work.
// Each span is {arena_offset, length, linear_prefix}; binary search maps the
// compact dispatch back to its physical arena range.
kernel void stwo_zig_clear_arena_spans(
    device uint *arena [[buffer(0)]],
    device const uint *spans [[buffer(1)]],
    constant uint &span_count [[buffer(2)]],
    constant uint &total_words [[buffer(3)]],
    uint position [[thread_position_in_grid]]
) {
    if (position >= total_words) return;
    uint low = 0u, high = span_count;
    while (low + 1u < high) {
        uint middle = low + (high - low) / 2u;
        if (spans[middle * 3u + 2u] <= position) low = middle;
        else high = middle;
    }
    uint base = low * 3u;
    uint local = position - spans[base + 2u];
    if (local < spans[base + 1u]) arena[spans[base] + local] = 0u;
}
