#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/extension_fields.metal"
#endif

constant uint relation_geometry_words = 10u;
constant uint relation_descriptor_words = 16u;
constant uint relation_use_words = 7u;
constant uint relation_block = 256u;

inline uint relation_instance_for_block(
    device const uint *geometry, uint count, uint block, thread uint &local_block
) {
    uint low = 0u, high = count;
    while (low < high) {
        uint middle = low + (high - low) / 2u;
        if (geometry[middle * relation_geometry_words] <= block) low = middle + 1u;
        else high = middle;
    }
    if (low == 0u) return count;
    uint instance = low - 1u;
    device const uint *g = geometry + instance * relation_geometry_words;
    local_block = block - g[0];
    return local_block < g[1] ? instance : count;
}

inline uint relation_scan_row(uint scan_index, uint rows) {
    uint circle_index = (scan_index & 1u) == 0u ? scan_index / 2u : rows - 1u - scan_index / 2u;
    uint bits = 31u - clz(rows);
    return bits == 0u ? 0u : reverse_bits(circle_index) >> (32u - bits);
}

inline uint relation_source_word(
    device const uint *arena, device const uint *source_offsets,
    uint source_base, uint rows, uint row, uint source_offset_rows,
    device const uint *use, uint word
) {
    uint kind = use[0], arg = use[1];
    if (word == 0u) return use[3];
    if (kind == 0u) return arena[source_offsets[source_base] + (arg + word) * rows + row];
    if (kind == 1u) return word == 1u ? row + 1u + arg * rows : arena[source_offsets[source_base + arg * 2u] + row];
    if (kind == 2u || kind == 4u) return arena[source_offsets[source_base + arg + word - 1u] + row];
    if (kind == 3u) return word == 1u ? ((row + source_offset_rows) | 0x40000000u) : arena[source_offsets[source_base + word - 2u] + row];
    if (kind == 5u) return word == 1u ? row + source_offset_rows : arena[source_offsets[source_base + word - 2u] + row];
    uint ah = arg >> 2u, bh = arg & 3u;
    uint a = (ah << 10u) | (row >> 10u);
    uint b = (bh << 10u) | (row & 0x3ffu);
    return word == 1u ? a : (word == 2u ? b : (a ^ b));
}

inline Qm31Value relation_combine(
    device const uint *arena, device const uint *source_offsets,
    uint source_base, uint rows, uint row, uint source_offset_rows,
    device const uint *use, device const Qm31Value *alphas, Qm31Value z
) {
    Qm31Value accumulator = { m31_neg(z.a), m31_neg(z.b), m31_neg(z.c), m31_neg(z.d) };
    for (uint word = 0u; word < use[2]; ++word) {
        accumulator = qm_add(accumulator, qm_mul_m31(alphas[word], relation_source_word(
            arena, source_offsets, source_base, rows, row, source_offset_rows, use, word)));
    }
    return accumulator;
}

inline uint relation_multiplicity(
    device const uint *arena, device const uint *source_offsets,
    uint source_base, uint rows, uint row, uint real_rows, device const uint *use
) {
    uint kind = use[4], arg = use[5], value;
    if (kind == 0u) value = 1u;
    else if (kind == 1u) value = row < real_rows ? 1u : 0u;
    else if (kind == 2u) value = arena[source_offsets[source_base] + arg * rows + row];
    else if (kind == 3u) value = arena[source_offsets[source_base + arg * 2u + 1u] + row];
    else value = arena[source_offsets[source_base + arg] + row];
    return use[6] != 0u ? m31_neg(value) : value;
}

inline void relation_fraction(
    device const uint *arena, device const uint *source_offsets, uint source_base,
    uint rows, uint row, uint real_rows, uint source_offset_rows,
    device const uint *descriptor, device const Qm31Value *alphas, Qm31Value z,
    thread Qm31Value &numerator, thread Qm31Value &denominator
) {
    device const uint *a = descriptor + 1u;
    Qm31Value da = relation_combine(arena, source_offsets, source_base, rows, row, source_offset_rows, a, alphas, z);
    uint ma = relation_multiplicity(arena, source_offsets, source_base, rows, row, real_rows, a);
    if (descriptor[0] == 2u) {
        device const uint *b = a + relation_use_words;
        Qm31Value db = relation_combine(arena, source_offsets, source_base, rows, row, source_offset_rows, b, alphas, z);
        uint mb = relation_multiplicity(arena, source_offsets, source_base, rows, row, real_rows, b);
        numerator = qm_add(qm_mul_m31(da, mb), qm_mul_m31(db, ma));
        denominator = qm_mul(da, db);
    } else {
        numerator = { ma, 0u, 0u, 0u };
        denominator = da;
    }
}

inline Qm31Value relation_denominator(
    device const uint *arena, device const uint *source_offsets, uint source_base,
    uint rows, uint row, uint source_offset_rows, device const uint *descriptor,
    device const Qm31Value *alphas, Qm31Value z
) {
    device const uint *a = descriptor + 1u;
    Qm31Value value = relation_combine(arena, source_offsets, source_base, rows, row, source_offset_rows, a, alphas, z);
    if (descriptor[0] == 2u) value = qm_mul(value, relation_combine(
        arena, source_offsets, source_base, rows, row, source_offset_rows, a + relation_use_words, alphas, z));
    return value;
}

inline void relation_store(
    device uint *arena, device const uint *output_offsets, uint output_base,
    uint column, uint row, Qm31Value value
) {
    uint base = output_base + column * 4u;
    arena[output_offsets[base] + row] = value.a;
    arena[output_offsets[base + 1u] + row] = value.b;
    arena[output_offsets[base + 2u] + row] = value.c;
    arena[output_offsets[base + 3u] + row] = value.d;
}

inline Qm31Value relation_load(
    device const uint *arena, device const uint *output_offsets, uint output_base,
    uint column, uint row
) {
    uint base = output_base + column * 4u;
    return { arena[output_offsets[base] + row], arena[output_offsets[base + 1u] + row],
             arena[output_offsets[base + 2u] + row], arena[output_offsets[base + 3u] + row] };
}

kernel void stwo_zig_relation_fused(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device const uint *source_offsets [[buffer(2)]], device const uint *descriptors [[buffer(3)]],
    device const uint *output_offsets [[buffer(4)]], device const Qm31Value *alphas [[buffer(5)]],
    device const Qm31Value *z_ptr [[buffer(6)]], constant uint &instance_count [[buffer(7)]],
    uint index [[thread_position_in_grid]]
) {
    uint block = index / relation_block, row_lane = index & (relation_block - 1u), local_block;
    uint instance = relation_instance_for_block(geometry, instance_count, block, local_block);
    if (instance == instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    uint row = local_block * relation_block + row_lane, rows = g[2];
    if (row >= rows) return;
    uint columns = g[3], source_base = g[6], descriptor_base = g[7], output_base = g[8];
    Qm31Value z = z_ptr[0], suffix = { 1u, 0u, 0u, 0u };
    for (uint column = columns; column-- > 0u;) {
        Qm31Value numerator, denominator;
        relation_fraction(arena, source_offsets, source_base, rows, row, g[4], g[5],
            descriptors + descriptor_base + column * relation_descriptor_words, alphas, z, numerator, denominator);
        relation_store(arena, output_offsets, output_base, column, row, qm_mul(numerator, suffix));
        suffix = qm_mul(suffix, denominator);
    }
    Qm31Value running = qm_inv(suffix), accumulated = { 0u, 0u, 0u, 0u };
    for (uint column = 0u; column < columns; ++column) {
        device const uint *descriptor = descriptors + descriptor_base + column * relation_descriptor_words;
        Qm31Value denominator = relation_denominator(arena, source_offsets, source_base, rows, row, g[5], descriptor, alphas, z);
        accumulated = qm_add(accumulated, qm_mul(relation_load(arena, output_offsets, output_base, column, row), running));
        relation_store(arena, output_offsets, output_base, column, row, accumulated);
        running = qm_mul(running, denominator);
    }
}

kernel void stwo_zig_relation_block_scan(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device const uint *output_offsets [[buffer(2)]], device Qm31Value *block_sums [[buffer(3)]],
    constant uint &instance_count [[buffer(4)]], uint lane [[thread_index_in_threadgroup]],
    uint group [[threadgroup_position_in_grid]]
) {
    uint local_block, instance = relation_instance_for_block(geometry, instance_count, group, local_block);
    if (instance == instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    uint scan_index = local_block * relation_block + lane, rows = g[2];
    threadgroup Qm31Value values[256];
    values[lane] = scan_index < rows ? relation_load(arena, output_offsets, g[8], g[3] - 1u, relation_scan_row(scan_index, rows)) : Qm31Value{0u,0u,0u,0u};
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = 1u; offset < relation_block; offset <<= 1u) {
        Qm31Value value = values[lane];
        if (lane >= offset) value = qm_add(value, values[lane - offset]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        values[lane] = value;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (scan_index < rows) relation_store(arena, output_offsets, g[8], g[3] - 1u, relation_scan_row(scan_index, rows), values[lane]);
    uint valid = min(relation_block, rows - local_block * relation_block);
    if (lane + 1u == valid) block_sums[group] = values[lane];
}

kernel void stwo_zig_relation_scan_blocks(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device Qm31Value *block_sums [[buffer(2)]], constant uint &instance_count [[buffer(3)]],
    uint instance [[thread_position_in_grid]]
) {
    if (instance >= instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    Qm31Value sum = { 0u, 0u, 0u, 0u };
    for (uint block = 0u; block < g[1]; ++block) {
        sum = qm_add(sum, block_sums[g[0] + block]);
        block_sums[g[0] + block] = sum;
    }
    uint claimed = g[9];
    arena[claimed] = sum.a; arena[claimed + 1u] = sum.b;
    arena[claimed + 2u] = sum.c; arena[claimed + 3u] = sum.d;
}

kernel void stwo_zig_relation_scan_finalize(
    device uint *arena [[buffer(0)]], device const uint *geometry [[buffer(1)]],
    device const uint *output_offsets [[buffer(2)]], device const Qm31Value *block_sums [[buffer(3)]],
    constant uint &instance_count [[buffer(4)]], uint index [[thread_position_in_grid]]
) {
    uint block = index / relation_block, lane = index & (relation_block - 1u), local_block;
    uint instance = relation_instance_for_block(geometry, instance_count, block, local_block);
    if (instance == instance_count) return;
    device const uint *g = geometry + instance * relation_geometry_words;
    uint scan_index = local_block * relation_block + lane, rows = g[2];
    if (scan_index >= rows) return;
    uint row = relation_scan_row(scan_index, rows);
    Qm31Value value = relation_load(arena, output_offsets, g[8], g[3] - 1u, row);
    if (local_block != 0u) value = qm_add(value, block_sums[block - 1u]);
    uint claimed = g[9];
    Qm31Value total = { arena[claimed], arena[claimed + 1u], arena[claimed + 2u], arena[claimed + 3u] };
    uint shift = m31_inv(rows), prefix_count = m31_reduce((ulong)scan_index + 1u);
    value = qm_sub(value, qm_mul_m31(total, m31_mul(shift, prefix_count)));
    relation_store(arena, output_offsets, g[8], g[3] - 1u, row, value);
}
