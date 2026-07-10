//! Atomic operation shims and native crypto hooks for riscv32im.
//!
//! Since our zkVM is single-threaded, atomic operations are equivalent
//! to their non-atomic counterparts. These provide the __sync_* builtins
//! that LLVM expects for atomic-cas on targets without hardware atomics.

#[no_mangle]
pub unsafe extern "C" fn __sync_fetch_and_add_4(ptr: *mut u32, val: u32) -> u32 {
    let old = ptr.read_volatile();
    ptr.write_volatile(old.wrapping_add(val));
    old
}

#[no_mangle]
pub unsafe extern "C" fn __sync_fetch_and_sub_4(ptr: *mut u32, val: u32) -> u32 {
    let old = ptr.read_volatile();
    ptr.write_volatile(old.wrapping_sub(val));
    old
}

#[no_mangle]
pub unsafe extern "C" fn __sync_val_compare_and_swap_4(
    ptr: *mut u32,
    old: u32,
    new: u32,
) -> u32 {
    let current = ptr.read_volatile();
    if current == old {
        ptr.write_volatile(new);
    }
    current
}

#[no_mangle]
pub unsafe extern "C" fn __sync_val_compare_and_swap_1(
    ptr: *mut u8,
    old: u8,
    new: u8,
) -> u8 {
    let current = ptr.read_volatile();
    if current == old {
        ptr.write_volatile(new);
    }
    current
}

#[no_mangle]
pub unsafe extern "C" fn __sync_fetch_and_add_1(ptr: *mut u8, val: u8) -> u8 {
    let old = ptr.read_volatile();
    ptr.write_volatile(old.wrapping_add(val));
    old
}

#[no_mangle]
pub unsafe extern "C" fn __sync_fetch_and_sub_1(ptr: *mut u8, val: u8) -> u8 {
    let old = ptr.read_volatile();
    ptr.write_volatile(old.wrapping_sub(val));
    old
}

#[no_mangle]
pub unsafe extern "C" fn __sync_fetch_and_add_8(ptr: *mut u64, val: u64) -> u64 {
    let old = ptr.read_volatile();
    ptr.write_volatile(old.wrapping_add(val));
    old
}

#[no_mangle]
pub unsafe extern "C" fn __sync_fetch_and_sub_8(ptr: *mut u64, val: u64) -> u64 {
    let old = ptr.read_volatile();
    ptr.write_volatile(old.wrapping_sub(val));
    old
}

#[no_mangle]
pub unsafe extern "C" fn __sync_val_compare_and_swap_8(
    ptr: *mut u64,
    old: u64,
    new: u64,
) -> u64 {
    let current = ptr.read_volatile();
    if current == old {
        ptr.write_volatile(new);
    }
    current
}

// ---------------------------------------------------------------------------
// Native keccak256 hook for alloy-primitives (native-keccak feature).
// Called by ALL keccak256 operations in alloy/revm, redirecting them
// through our accelerated host syscall.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn native_keccak256(bytes: *const u8, len: usize, output: *mut u8) {
    let input = core::slice::from_raw_parts(bytes, len);
    let out = core::slice::from_raw_parts_mut(output, 32);
    let mut hash = [0u8; 32];
    stwo_guest_sdk::syscall::keccak256(input, &mut hash);
    out.copy_from_slice(&hash);
}
