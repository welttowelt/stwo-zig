#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/circle.metal"

constant uint circle_fused_wide_tile_log = 12u;
constant uint circle_fused_wide_tile_size = 1u << circle_fused_wide_tile_log;
#endif

kernel void stwo_zig_circle_ifft_fused_tail_wide(
    device const uint *source [[buffer(0)]],
    device uint *destination [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &column_or_destination [[buffer(4)]],
    constant uint &source_mode [[buffer(5)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    if (source_mode == 0u && group.y >= column_or_destination) return;
    threadgroup uint tile[circle_fused_wide_tile_size];
    uint value_len = 1u << log_size;
    uint tile_offset = group.x << circle_fused_wide_tile_log;
    uint source_column_offset = group.y << log_size;
    uint destination_column_offset =
        (source_mode == 0u ? group.y : column_or_destination + group.y) << log_size;
    for (uint item = lane; item < circle_fused_wide_tile_size; item += circle_fused_threads) {
        tile[item] = source[source_column_offset + tile_offset + item];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint pair = lane; pair < circle_fused_wide_tile_size / 2u; pair += circle_fused_threads) {
        uint idx0 = pair << 1u;
        uint idx1 = idx0 + 1u;
        uint lhs = tile[idx0];
        uint rhs = tile[idx1];
        uint global_pair = (tile_offset >> 1u) + pair;
        tile[idx0] = m31_add(lhs, rhs);
        tile[idx1] = m31_mul(m31_sub(lhs, rhs), circle_twiddle(twiddles, global_pair));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint pair_count = value_len >> 1u;
    for (uint layer = 1u; layer < circle_fused_wide_tile_log; ++layer) {
        uint distance = 1u << layer;
        uint stride = distance << 1u;
        uint twiddle_offset = pair_count - (1u << (log_size - layer));
        uint group_base = tile_offset / stride;
        for (uint pair = lane; pair < circle_fused_wide_tile_size / 2u; pair += circle_fused_threads) {
            uint local_group = pair / distance;
            uint inner = pair - local_group * distance;
            uint idx0 = local_group * stride + inner;
            uint idx1 = idx0 + distance;
            uint lhs = tile[idx0];
            uint rhs = tile[idx1];
            uint twiddle = twiddles[twiddle_offset + group_base + local_group];
            tile[idx0] = m31_add(lhs, rhs);
            tile[idx1] = m31_mul(m31_sub(lhs, rhs), twiddle);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    for (uint item = lane; item < circle_fused_wide_tile_size; item += circle_fused_threads) {
        destination[destination_column_offset + tile_offset + item] = tile[item];
    }
}
kernel void stwo_zig_circle_rfft_fused_tail_sparse_wide(
    device uint *arena [[buffer(0)]],
    device const uint *destination_offsets [[buffer(1)]],
    device const uint *twiddles [[buffer(2)]],
    constant uint &log_size [[buffer(3)]],
    constant uint &column_count [[buffer(4)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    if (group.y >= column_count) return;
    threadgroup uint tile[circle_fused_wide_tile_size];
    uint value_len = 1u << log_size;
    uint tile_offset = group.x << circle_fused_wide_tile_log;
    uint column_offset = destination_offsets[group.y];
    for (uint item = lane; item < circle_fused_wide_tile_size; item += circle_fused_threads) {
        tile[item] = arena[column_offset + tile_offset + item];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint pair_count = value_len >> 1u;
    for (uint layer = circle_fused_wide_tile_log - 1u; layer > 0u; --layer) {
        uint distance = 1u << layer;
        uint stride = distance << 1u;
        uint twiddle_offset = pair_count - (1u << (log_size - layer));
        uint group_base = tile_offset / stride;
        for (uint pair = lane; pair < circle_fused_wide_tile_size / 2u; pair += circle_fused_threads) {
            uint local_group = pair / distance;
            uint inner = pair - local_group * distance;
            uint idx0 = local_group * stride + inner;
            uint idx1 = idx0 + distance;
            uint lhs = tile[idx0];
            uint product = m31_mul(tile[idx1], twiddles[twiddle_offset + group_base + local_group]);
            tile[idx0] = m31_add(lhs, product);
            tile[idx1] = m31_sub(lhs, product);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    for (uint pair = lane; pair < circle_fused_wide_tile_size / 2u; pair += circle_fused_threads) {
        uint idx0 = pair << 1u;
        uint idx1 = idx0 + 1u;
        uint lhs = tile[idx0];
        uint global_pair = (tile_offset >> 1u) + pair;
        uint product = m31_mul(tile[idx1], circle_twiddle(twiddles, global_pair));
        tile[idx0] = m31_add(lhs, product);
        tile[idx1] = m31_sub(lhs, product);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint item = lane; item < circle_fused_wide_tile_size; item += circle_fused_threads) {
        arena[column_offset + tile_offset + item] = tile[item];
    }
}
