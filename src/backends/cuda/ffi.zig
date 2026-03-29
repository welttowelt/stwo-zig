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
// Memory pool management
// ---------------------------------------------------------------

pub extern "C" fn cuda_mem_pool_init() i32;
pub extern "C" fn cuda_mem_pool_destroy() i32;
