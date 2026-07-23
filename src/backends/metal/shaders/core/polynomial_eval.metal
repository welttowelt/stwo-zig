#ifndef STWO_ZIG_AMALGAMATED
#include "stwo_zig/base.metal"
#include "stwo_zig/m31.metal"
#include "stwo_zig/extension_fields.metal"
#include "stwo_zig/abi_types.metal"
#endif

kernel void stwo_zig_eval_basis(
    device const uint *factors [[buffer(0)]],
    device const PolynomialBasisTask *tasks [[buffer(1)]],
    constant uint &task_count [[buffer(2)]],
    device Qm31Value *basis [[buffer(3)]],
    uint lane [[thread_index_in_threadgroup]],
    uint2 group_shape [[threads_per_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]]
) {
    uint group_width = group_shape.x;
    uint task_index = group.y;
    if (task_index >= task_count) return;
    PolynomialBasisTask task = tasks[task_index];
    uint block = group.x;
    uint block_start = block * group_width;
    if (block_start >= task.basis_length) return;

    // Keep a generic construction for any future narrower pipeline. Each
    // threadgroup owns one contiguous basis block, exposing independent blocks
    // across the full GPU instead of serializing them behind barriers.
    if (group_width != 256u) {
        uint coefficient_index = block_start + lane;
        if (coefficient_index < task.basis_length) {
            Qm31Value value = { 1u, 0u, 0u, 0u };
            uint bits = coefficient_index;
            for (uint bit = 0; bit < task.log_size && bits != 0u; ++bit) {
                if ((bits & 1u) != 0u) {
                    uint factor_base = task.factor_offset + bit * 4u;
                    Qm31Value factor = { factors[factor_base], factors[factor_base + 1u],
                                         factors[factor_base + 2u], factors[factor_base + 3u] };
                    value = qm_mul(value, factor);
                }
                bits >>= 1u;
            }
            basis[task.basis_offset + coefficient_index] = value;
        }
        return;
    }

    // Split each basis index into a lane-local low byte and a block index. The
    // low product is intentionally recomputed per block: the extra arithmetic
    // buys thousands of independent threadgroups and removes two serialized
    // barriers per 256 coefficients.
    Qm31Value low_value = { 1u, 0u, 0u, 0u };
    uint low_bits = lane;
    for (uint bit = 0; bit < min(task.log_size, 8u) && low_bits != 0u; ++bit) {
        if ((low_bits & 1u) != 0u) {
            uint factor_base = task.factor_offset + bit * 4u;
            Qm31Value factor = { factors[factor_base], factors[factor_base + 1u],
                                 factors[factor_base + 2u], factors[factor_base + 3u] };
            low_value = qm_mul(low_value, factor);
        }
        low_bits >>= 1u;
    }

    threadgroup Qm31Value high_value;
    if (lane == 0u) {
        Qm31Value value = { 1u, 0u, 0u, 0u };
        uint high_bits = block;
        for (uint bit = 8u; bit < task.log_size && high_bits != 0u; ++bit) {
            if ((high_bits & 1u) != 0u) {
                uint factor_base = task.factor_offset + bit * 4u;
                Qm31Value factor = { factors[factor_base], factors[factor_base + 1u],
                                     factors[factor_base + 2u], factors[factor_base + 3u] };
                value = qm_mul(value, factor);
            }
            high_bits >>= 1u;
        }
        high_value = value;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint coefficient_index = (block << 8u) + lane;
    if (coefficient_index < task.basis_length) {
        basis[task.basis_offset + coefficient_index] = block == 0u
            ? low_value
            : qm_mul(low_value, high_value);
    }
}

kernel void stwo_zig_eval_polynomials(
    device const uint *coefficients [[buffer(0)]],
    device const Qm31Value *basis [[buffer(1)]],
    device const PolynomialEvalTask *tasks [[buffer(2)]],
    constant uint &task_count [[buffer(3)]],
    device uint *output [[buffer(4)]],
    uint lane [[thread_index_in_threadgroup]],
    uint group_width [[threads_per_threadgroup]],
    uint task_index [[threadgroup_position_in_grid]]
) {
    if (task_index >= task_count) return;
    PolynomialEvalTask task = tasks[task_index];
    Qm31Value partial_value = { 0u, 0u, 0u, 0u };
    for (uint coefficient_index = lane; coefficient_index < task.coefficient_length; coefficient_index += group_width) {
        partial_value = qm_add(
            partial_value,
            qm_mul_m31(basis[task.basis_offset + coefficient_index],
                       coefficients[task.coefficient_offset + coefficient_index])
        );
    }
    threadgroup Qm31Value partials[256];
    partials[lane] = partial_value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = group_width >> 1u; stride != 0u; stride >>= 1u) {
        if (lane < stride) partials[lane] = qm_add(partials[lane], partials[lane + stride]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0u) {
        uint output_base = task.output_index * 4u;
        output[output_base] = partials[0].a;
        output[output_base + 1u] = partials[0].b;
        output[output_base + 2u] = partials[0].c;
        output[output_base + 3u] = partials[0].d;
    }
}
