//! Column type abstraction for backend-specific field element storage.
//!
//! For CpuBackend:  ColumnType(M31) = []M31  (plain heap slice)
//! For SimdBackend: ColumnType(M31) = []PackedM31 (SIMD-packed lanes)
//! For CudaBackend: ColumnType(M31) = DeviceSlice(M31) (GPU device pointer)

/// Returns the backend-specific column type for field element `F`.
pub fn Column(comptime B: type, comptime F: type) type {
    return B.ColumnType(F);
}

/// Validates that backend `B` declares a `ColumnType` function.
pub fn assertColumnOps(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "ColumnType")) {
            @compileError("Backend must declare `pub fn ColumnType(comptime F: type) type`.");
        }
    }
}
