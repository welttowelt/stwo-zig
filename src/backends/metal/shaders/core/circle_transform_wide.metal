#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/circle.metal"

constant uint circle_fused_wide_tile_log = 12u;
constant uint circle_fused_wide_tile_size = 1u << circle_fused_wide_tile_log;
#endif

constant uint circle_high_fused_values = 4096u;
constant uint circle_high_fused_threads = 256u;

// Fuses the remaining high circle-transform layers cooperatively. Threads
// share multiple independent low-lane tuples in 16 KiB of threadgroup memory,
// replacing several complete device-arena read/write passes with one.
inline void circle_rfft_high_fused_sparse(
    device uint *arena,
    device const uint *destination_offsets,
    device const uint *twiddles,
    uint log_size,
    uint lowest_stage,
    uint layer_count,
    uint column_count,
    uint inverse_mode,
    uint lane,
    uint2 group_position,
    threadgroup uint *tile
) {
    if (group_position.y >= column_count || layer_count < 2u || layer_count > 12u ||
        lowest_stage + layer_count > log_size) return;

    uint lanes_log = 12u - layer_count;
    if (lowest_stage < lanes_log) return;
    uint lanes_per_group = 1u << lanes_log;
    uint distance = 1u << lowest_stage;
    uint lane_batch_log = lowest_stage - lanes_log;
    uint lane_batches = 1u << lane_batch_log;
    uint outer_groups = 1u << (log_size - lowest_stage - layer_count);
    uint outer_group = group_position.x >> lane_batch_log;
    uint lane_batch = group_position.x & (lane_batches - 1u);
    if (outer_group >= outer_groups) return;

    uint column_offset = destination_offsets[group_position.y];
    uint global_base = column_offset + (outer_group << (lowest_stage + layer_count));
    for (uint item = lane; item < circle_high_fused_values; item += circle_high_fused_threads) {
        // Preserve device layout in threadgroup memory. Both the arena transfer
        // and each butterfly below then use adjacent lane slots as contiguous
        // SIMD memory transactions.
        uint lane_slot = item & (lanes_per_group - 1u);
        uint tuple_item = item >> lanes_log;
        uint global_lane = (lane_batch << lanes_log) + lane_slot;
        tile[item] = arena[global_base + global_lane + tuple_item * distance];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint pairs_log = layer_count - 1u;
    uint pair_count = 1u << (log_size - 1u);
    for (uint step = 0u; step < layer_count; ++step) {
        uint substage = inverse_mode != 0u
            ? lowest_stage + step
            : lowest_stage + layer_count - 1u - step;
        uint half_span_log = inverse_mode != 0u
            ? step
            : layer_count - 1u - step;
        uint half_span = 1u << half_span_log;
        uint block_count = 1u << (pairs_log - half_span_log);
        uint twiddle_offset = pair_count - (1u << (log_size - substage));
        for (uint pair = lane; pair < circle_high_fused_values / 2u; pair += circle_high_fused_threads) {
            uint lane_slot = pair & (lanes_per_group - 1u);
            uint local_pair = pair >> lanes_log;
            uint block = local_pair >> half_span_log;
            uint item = local_pair & (half_span - 1u);
            uint lo_item = block * (half_span << 1u) + item;
            uint lo = (lo_item << lanes_log) + lane_slot;
            uint hi = lo + (half_span << lanes_log);
            uint lhs = tile[lo];
            uint rhs = tile[hi];
            uint twiddle = twiddles[twiddle_offset + outer_group * block_count + block];
            if (inverse_mode != 0u) {
                tile[lo] = m31_add(lhs, rhs);
                tile[hi] = m31_mul(m31_sub(lhs, rhs), twiddle);
            } else {
                uint product = m31_mul(rhs, twiddle);
                tile[lo] = m31_add(lhs, product);
                tile[hi] = m31_sub(lhs, product);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    for (uint item = lane; item < circle_high_fused_values; item += circle_high_fused_threads) {
        uint lane_slot = item & (lanes_per_group - 1u);
        uint tuple_item = item >> lanes_log;
        uint global_lane = (lane_batch << lanes_log) + lane_slot;
        arena[global_base + global_lane + tuple_item * distance] = tile[item];
    }
}

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
