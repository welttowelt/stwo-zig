//! Concrete backend implementations for stwo-zig.
//!
//! Each backend is a zero-sized marker type that satisfies the
//! `backend.assertBackend` contract.

pub const cpu_scalar = @import("cpu_scalar/mod.zig");
pub const cuda = @import("cuda/mod.zig");

/// The default backend: scalar CPU operations on plain slices.
pub const CpuBackend = cpu_scalar.CpuBackend;

/// CUDA GPU backend: operations offloaded to NVIDIA GPUs via libstwo_cuda.
pub const CudaBackend = cuda.CudaBackend;
