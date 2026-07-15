//! FFI declarations for the stwo-cuda native library (libstwo_cuda.a).
//!
//! These `extern "C"` signatures match the C API surface exposed by the
//! stwo-cuda project (https://github.com/starkware-libs/stwo-cuda).
//! They are only resolved at link time when `-lstwo_cuda` is provided.

// ---------------------------------------------------------------
// QM31 representation (matches the CUDA struct layout)
// ---------------------------------------------------------------

/// CM31 as two packed u32 values (real, imaginary).
pub const CudaCM31 = extern struct {
    a: u32,
    b: u32,
};

/// QM31 as a pair of CM31 values.
pub const CudaQM31 = extern struct {
    a: CudaCM31,
    b: CudaCM31,
};

// ---------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------

pub extern "C" fn cuda_malloc_uint32_t(count: usize) ?[*]u32;
pub extern "C" fn cuda_alloc_zeroes_uint32_t(count: usize) ?[*]u32;
pub extern "C" fn cuda_free_memory(ptr: ?*anyopaque) void;
pub extern "C" fn cuda_get_memory_info(free_mem: *usize, total_mem: *usize) void;

// ---------------------------------------------------------------
// Data transfer (host <-> device)
// ---------------------------------------------------------------

pub extern "C" fn copy_uint32_t_vec_from_host_to_device(host_ptr: [*]const u32, size: u32) ?[*]u32;
pub extern "C" fn copy_uint32_t_vec_from_device_to_host(device_ptr: [*]const u32, host_ptr: [*]u32, size: u32) void;

// ---------------------------------------------------------------
// Field operations
// ---------------------------------------------------------------

pub extern "C" fn batch_inverse_base_field(size: u32, values: [*]const u32, inverses: [*]u32) void;
pub extern "C" fn bit_reverse_base_field(log_size: u32, values: [*]u32) void;
pub extern "C" fn bit_reverse_secure_field(log_size: u32, values: [*][*]u32) void;

// ---------------------------------------------------------------
// Polynomial operations (NTT / evaluation)
// ---------------------------------------------------------------

pub extern "C" fn ntt_n2b_columns(log_size: u32, n_cols: u32, values: [*][*]u32, twiddles: [*]u32, twiddles_size: u32) void;
pub extern "C" fn ntt_b2n_column(log_size: u32, values: [*]u32, twiddles: [*]u32, twiddles_size: u32) void;

/// Evaluate a polynomial (given as coefficients) at a single QM31 point.
pub extern "C" fn eval_at_point(coeffs: [*]const u32, coeffs_size: i32, point_x: CudaQM31, point_y: CudaQM31) CudaQM31;

// ---------------------------------------------------------------
// FRI operations
// ---------------------------------------------------------------

pub extern "C" fn fold_line(gpu_domain: [*]u32, twiddle_offset: u32, n: u32, eval_values: [*][*]u32, alpha: CudaQM31, folded_values: [*][*]u32) void;
pub extern "C" fn fold_circle_into_line(gpu_domain: [*]u32, twiddle_offset: u32, n: u32, eval_values: [*][*]u32, alpha: CudaQM31, folded_values: [*][*]u32) void;
pub extern "C" fn precompute_twiddles(initial_x: u32, initial_y: u32, step_x: u32, step_y: u32, total_size: usize) ?[*]u32;

// ---------------------------------------------------------------
// Hashing / Merkle commitment
// ---------------------------------------------------------------

pub extern "C" fn commit_on_first_layer_in_gpu(size: u32, n_cols: u32, data: [*][*]u32, result: [*]u8) void;
pub extern "C" fn commit_on_layer_in_gpu(size: u32, n_cols: u32, data: [*][*]u32, prev_layer: [*]const u8, result: [*]u8) void;

// ---------------------------------------------------------------
// Accumulation
// ---------------------------------------------------------------

pub extern "C" fn accumulate(size: u32, col1: [*]u32, col2: [*]const u32) void;

// ---------------------------------------------------------------
// Device-to-device copy
// ---------------------------------------------------------------

pub extern "C" fn copy_uint32_t_vec_from_device_to_device(src: [*]const u32, dst: [*]u32, size: u32) void;

// ---------------------------------------------------------------
// Batch evaluation
// ---------------------------------------------------------------

pub extern "C" fn batch_eval_at_points(coeffs_ptrs: [*]const [*]const u32, coeffs_size: i32, num_polys: i32, point_x: CudaQM31, point_y: CudaQM31, results: [*]CudaQM31) void;

// ---------------------------------------------------------------
// Quotient operations
// ---------------------------------------------------------------

pub extern "C" fn accumulate_quotients(
    log_size: u32,
    n_columns: u32,
    columns: [*]const [*]const u32,
    random_coeff: CudaQM31,
    n_batches: u32,
    batch_sizes: [*]const u32,
    batch_column_indices: [*]const u32,
    batch_point_xs: [*]const CudaQM31,
    batch_point_ys: [*]const CudaQM31,
    batch_line_coeffs_a: [*]const CudaQM31,
    batch_line_coeffs_b: [*]const CudaQM31,
    batch_line_coeffs_c: [*]const CudaQM31,
    result: [*][*]u32,
) void;

// ---------------------------------------------------------------
// Lift-accumulation
// ---------------------------------------------------------------

pub extern "C" fn lift_accumulate_secure_columns(size: u32, log_ratio: u32, col1: [*]u32, col2: [*]const u32) void;

// ---------------------------------------------------------------
// GKR operations
// ---------------------------------------------------------------

pub extern "C" fn gen_eq_evals(y: [*]const CudaQM31, y_len: u32, v: CudaQM31, result: [*]u32) void;
pub extern "C" fn gkr_next_grand_product_layer(n: u32, input: [*]const [*]const u32, output: [*][*]u32) void;
pub extern "C" fn gkr_next_logup_generic_layer(n: u32, num_input: [*]const [*]const u32, den_input: [*]const [*]const u32, num_output: [*][*]u32, den_output: [*][*]u32) void;
pub extern "C" fn gkr_sum_grand_product(n: u32, input: [*]const [*]const u32, eq: [*]const u32, result_at_0: [*]u32, result_at_2: [*]u32) void;
pub extern "C" fn gkr_sum_logup_generic(n: u32, num: [*]const [*]const u32, den: [*]const [*]const u32, eq: [*]const u32, lambda: CudaQM31, result_at_0: [*]u32, result_at_2: [*]u32) void;

// ---------------------------------------------------------------
// Poseidon252 hashing
// ---------------------------------------------------------------

pub extern "C" fn poseidon252_commit_on_first_layer(size: u32, n_cols: u32, data: [*][*]u32, result: [*]u8) void;
pub extern "C" fn poseidon252_commit_on_layer_with_previous(size: u32, n_cols: u32, data: [*][*]u32, prev: [*]const u8, result: [*]u8) void;

// ---------------------------------------------------------------
// Framework plan interpreter
// ---------------------------------------------------------------

pub extern "C" fn execute_framework_eval_plan_v1(request: *anyopaque) u32;

// ---------------------------------------------------------------
// Memory pool management
// ---------------------------------------------------------------

pub extern "C" fn cuda_mem_pool_init() i32;
pub extern "C" fn cuda_mem_pool_destroy() i32;

// ---------------------------------------------------------------
// MLE operations
// ---------------------------------------------------------------

pub extern "C" fn fix_first_variable_base_field(n: u32, input: [*]const u32, assignment: CudaQM31, output: [*]u32) void;
pub extern "C" fn fix_first_variable_secure_field(n: u32, input: [*]const [*]const u32, assignment: CudaQM31, output: [*][*]u32) void;

// ---------------------------------------------------------------
// CUDA runtime device management (from libcudart, for multi-GPU)
// ---------------------------------------------------------------

pub extern "cudart" fn cudaGetDeviceCount(count: *i32) i32;
pub extern "cudart" fn cudaSetDevice(device: i32) i32;
pub extern "cudart" fn cudaGetDevice(device: *i32) i32;
pub extern "cudart" fn cudaMemcpyPeer(dst: *anyopaque, dst_device: i32, src: *const anyopaque, src_device: i32, count: usize) i32;
pub extern "cudart" fn cudaDeviceEnablePeerAccess(peer_device: i32, flags: u32) i32;

// ---------------------------------------------------------------
// Blake2s hash vector memory management
// ---------------------------------------------------------------

pub extern "C" fn cuda_malloc_blake_2s_hash(size: usize) ?[*]u8;
pub extern "C" fn cuda_alloc_zeroes_blake_2s_hash(size: usize) ?[*]u8;
pub extern "C" fn copy_blake_2s_hash_vec_from_host_to_device(host: [*]const u8, size: u32) ?[*]u8;
pub extern "C" fn copy_blake_2s_hash_vec_from_device_to_host(device: [*]const u8, host: [*]u8, size: u32) void;
pub extern "C" fn copy_blake_2s_hash_vec_from_device_to_device(src: [*]const u8, dst: [*]u8, size: u32) void;

// ---------------------------------------------------------------
// Poseidon252 hash vector memory management
// ---------------------------------------------------------------

pub extern "C" fn cuda_malloc_poseidon252_hash(size: usize) ?[*]u8;
pub extern "C" fn cuda_alloc_zeroes_poseidon252_hash(size: usize) ?[*]u8;
pub extern "C" fn copy_poseidon252_hash_vec_from_host_to_device(host: [*]const u8, size: u32) ?[*]u8;
pub extern "C" fn copy_poseidon252_hash_vec_from_device_to_host(device: [*]const u8, host: [*]u8, size: u32) void;
pub extern "C" fn copy_poseidon252_hash_vec_from_device_to_device(src: [*]const u8, dst: [*]u8, size: u32) void;

// ---------------------------------------------------------------
// Element access
// ---------------------------------------------------------------

pub extern "C" fn cuda_get_uint32_t(device_ptr: [*]const u32, index: usize) u32;
pub extern "C" fn cuda_set_uint32_t(device_ptr: [*]u32, index: usize, value: u32) void;
pub extern "C" fn cuda_increase_at(device_ptr: [*]u32, index: usize, value: u32) void;

// ---------------------------------------------------------------
// Pointer upload
// ---------------------------------------------------------------

pub extern "C" fn copy_device_pointer_vec_from_host_to_device(host_ptrs: [*]*anyopaque, count: usize) void;
pub extern "C" fn cuda_release_uploaded_pointer_vec(device_ptrs: [*]*anyopaque) void;

// ---------------------------------------------------------------
// Remaining GKR operations
// ---------------------------------------------------------------

pub extern "C" fn gkr_next_logup_multiplicities_layer(n: u32, num_input_base: [*]const u32, den_input: [*]const [*]const u32, num_output: [*][*]u32, den_output: [*][*]u32) void;
pub extern "C" fn gkr_next_logup_singles_layer(n: u32, den_input: [*]const [*]const u32, num_output: [*][*]u32, den_output: [*][*]u32) void;
pub extern "C" fn gkr_sum_logup_multiplicities(n: u32, num_base: [*]const u32, den: [*]const [*]const u32, eq: [*]const u32, lambda: CudaQM31, result_at_0: [*]u32, result_at_2: [*]u32) void;
pub extern "C" fn gkr_sum_logup_singles(n: u32, den: [*]const [*]const u32, eq: [*]const u32, lambda: CudaQM31, result_at_0: [*]u32, result_at_2: [*]u32) void;

// ---------------------------------------------------------------
// Quotient operations (partial numerator / combiner)
// ---------------------------------------------------------------

pub extern "C" fn accumulate_partial_quotient_numerators(
    log_size: u32,
    n_columns: u32,
    columns: [*]const [*]const u32,
    n_batches: u32,
    batch_sizes: [*]const u32,
    batch_column_indices: [*]const u32,
    batch_line_coeffs_a: [*]const CudaQM31,
    batch_line_coeffs_b: [*]const CudaQM31,
    batch_line_coeffs_c: [*]const CudaQM31,
    domain_y: [*]const u32,
    result: [*][*]u32,
) void;

pub extern "C" fn combine_quotients_from_numerators(
    log_size: u32,
    n_batches: u32,
    numerator_columns: [*]const [*]const u32,
    denominator_inverses: [*]const [*]const u32,
    random_coeff: CudaQM31,
    result: [*][*]u32,
) void;

// ---------------------------------------------------------------
// Evaluation helpers
// ---------------------------------------------------------------

pub extern "C" fn evaluate_columns(
    log_size: u32,
    n_columns: u32,
    columns: [*]const [*]const u32,
    twiddles: [*]const u32,
    twiddles_size: u32,
    results: [*][*]u32,
) void;

pub extern "C" fn barycentric_weights_from_point_vanishings(
    n: u32,
    point_vanishings: [*]const u32,
    weights: [*]u32,
) void;

pub extern "C" fn sort_values_and_permute_with_bit_reverse_order(
    log_size: u32,
    values: [*]u32,
    sorted: [*]u32,
) void;

// ---------------------------------------------------------------
// Witness generation (Cairo-specific, part of stwo-cuda)
// ---------------------------------------------------------------

pub extern "C" fn generate_wide_fibonacci_trace(request: *const anyopaque) void;
pub extern "C" fn generate_poseidon_traces(request: *const anyopaque) void;
pub extern "C" fn generate_poseidon_interaction_traces(request: *const anyopaque) void;
pub extern "C" fn generate_assert_eq_fp_imm_traces(request: *const anyopaque) void;

// ---------------------------------------------------------------
// Lifted commitment
// ---------------------------------------------------------------

pub extern "C" fn commit_on_first_layer_lifted(
    size: u32,
    n_cols: u32,
    data: [*][*]u32,
    seeds: [*]const u8,
    result: [*]u8,
) void;

// ---------------------------------------------------------------
// Compile-time declaration coverage test
// ---------------------------------------------------------------

test "cuda ffi: all declarations compile" {
    // Reference every extern "C" function to ensure they are valid declarations.
    // These are resolved at link-time; this test only checks compile-time validity.
    comptime {
        // Memory management
        _ = cuda_malloc_uint32_t;
        _ = cuda_alloc_zeroes_uint32_t;
        _ = cuda_free_memory;
        _ = cuda_get_memory_info;

        // Data transfer (host <-> device)
        _ = copy_uint32_t_vec_from_host_to_device;
        _ = copy_uint32_t_vec_from_device_to_host;
        _ = copy_uint32_t_vec_from_device_to_device;

        // Field operations
        _ = batch_inverse_base_field;
        _ = bit_reverse_base_field;
        _ = bit_reverse_secure_field;

        // Polynomial operations (NTT / evaluation)
        _ = ntt_n2b_columns;
        _ = ntt_b2n_column;
        _ = eval_at_point;

        // FRI operations
        _ = fold_line;
        _ = fold_circle_into_line;
        _ = precompute_twiddles;

        // Hashing / Merkle commitment
        _ = commit_on_first_layer_in_gpu;
        _ = commit_on_layer_in_gpu;

        // Accumulation
        _ = accumulate;
        _ = lift_accumulate_secure_columns;

        // Batch evaluation
        _ = batch_eval_at_points;

        // Quotient operations
        _ = accumulate_quotients;
        _ = accumulate_partial_quotient_numerators;
        _ = combine_quotients_from_numerators;

        // GKR operations
        _ = gen_eq_evals;
        _ = gkr_next_grand_product_layer;
        _ = gkr_next_logup_generic_layer;
        _ = gkr_next_logup_multiplicities_layer;
        _ = gkr_next_logup_singles_layer;
        _ = gkr_sum_grand_product;
        _ = gkr_sum_logup_generic;
        _ = gkr_sum_logup_multiplicities;
        _ = gkr_sum_logup_singles;

        // Poseidon252 hashing
        _ = poseidon252_commit_on_first_layer;
        _ = poseidon252_commit_on_layer_with_previous;

        // Framework plan interpreter
        _ = execute_framework_eval_plan_v1;

        // Memory pool management
        _ = cuda_mem_pool_init;
        _ = cuda_mem_pool_destroy;

        // MLE operations
        _ = fix_first_variable_base_field;
        _ = fix_first_variable_secure_field;

        // Blake2s hash vector memory management
        _ = cuda_malloc_blake_2s_hash;
        _ = cuda_alloc_zeroes_blake_2s_hash;
        _ = copy_blake_2s_hash_vec_from_host_to_device;
        _ = copy_blake_2s_hash_vec_from_device_to_host;
        _ = copy_blake_2s_hash_vec_from_device_to_device;

        // Poseidon252 hash vector memory management
        _ = cuda_malloc_poseidon252_hash;
        _ = cuda_alloc_zeroes_poseidon252_hash;
        _ = copy_poseidon252_hash_vec_from_host_to_device;
        _ = copy_poseidon252_hash_vec_from_device_to_host;
        _ = copy_poseidon252_hash_vec_from_device_to_device;

        // Element access
        _ = cuda_get_uint32_t;
        _ = cuda_set_uint32_t;
        _ = cuda_increase_at;

        // Pointer upload
        _ = copy_device_pointer_vec_from_host_to_device;
        _ = cuda_release_uploaded_pointer_vec;

        // Evaluation helpers
        _ = evaluate_columns;
        _ = barycentric_weights_from_point_vanishings;
        _ = sort_values_and_permute_with_bit_reverse_order;

        // Witness generation
        _ = generate_wide_fibonacci_trace;
        _ = generate_poseidon_traces;
        _ = generate_poseidon_interaction_traces;
        _ = generate_assert_eq_fp_imm_traces;

        // Lifted commitment
        _ = commit_on_first_layer_lifted;
    }
    // Total: 63 extern "C" declarations + 5 extern "cudart" declarations = 68 symbols.
}
