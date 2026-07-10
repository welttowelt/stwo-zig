//! Raw ECALL syscall wrappers.
//!
//! Each function triggers an ECALL with the appropriate syscall number
//! in a7 (x17) and arguments in a0-a6 (x10-x16).

use core::arch::asm;

// Syscall numbers (matching stwo-zig host/mod.zig SyscallNr).
pub const SYSCALL_HALT: u32 = 0;
pub const SYSCALL_WRITE: u32 = 2;
pub const SYSCALL_COMMIT: u32 = 16;
pub const SYSCALL_HINT_LEN: u32 = 240;
pub const SYSCALL_HINT_READ: u32 = 241;
pub const SYSCALL_KECCAK256: u32 = 242;
pub const SYSCALL_ECRECOVER: u32 = 243;
pub const SYSCALL_SHA256: u32 = 244;

/// Raw ecall with 3 arguments. Returns the value in a0 after the call.
#[inline(always)]
unsafe fn ecall3(nr: u32, a0: u32, a1: u32, a2: u32) -> u32 {
    let ret: u32;
    asm!(
        "ecall",
        in("x17") nr,       // a7 = syscall number
        inlateout("x10") a0 => ret,  // a0 = arg0 / return
        in("x11") a1,       // a1 = arg1
        in("x12") a2,       // a2 = arg2
        options(nostack),
    );
    ret
}

/// Raw ecall with 0 arguments.
#[inline(always)]
unsafe fn ecall0(nr: u32) -> u32 {
    let ret: u32;
    asm!(
        "ecall",
        in("x17") nr,
        lateout("x10") ret,
        options(nostack),
    );
    ret
}

/// Terminate the program with the given exit code.
pub fn halt(exit_code: u32) -> ! {
    unsafe {
        ecall3(SYSCALL_HALT, exit_code, 0, 0);
    }
    // Safety: the host halts execution; this is unreachable.
    #[allow(clippy::empty_loop)]
    loop {}
}

/// Write `buf` to the host via file descriptor `fd`.
/// fd=1 for stdout/journal, fd=3 for hint request.
/// Returns the number of bytes written.
pub fn write(fd: u32, buf: &[u8]) -> u32 {
    unsafe { ecall3(SYSCALL_WRITE, fd, buf.as_ptr() as u32, buf.len() as u32) }
}

/// Commit `buf` as public output.
pub fn commit(buf: &[u8]) {
    unsafe {
        ecall3(SYSCALL_COMMIT, buf.as_ptr() as u32, buf.len() as u32, 0);
    }
}

/// Get the length (in bytes) of the next available hint.
pub fn hint_len() -> u32 {
    unsafe { ecall0(SYSCALL_HINT_LEN) }
}

/// Read hint bytes into `buf`. Returns the number of bytes actually read.
pub fn hint_read(buf: &mut [u8]) -> u32 {
    unsafe { ecall3(SYSCALL_HINT_READ, buf.as_mut_ptr() as u32, buf.len() as u32, 0) }
}

/// Accelerated keccak256 hash. Computed by the host at native speed.
/// Input: arbitrary-length byte slice. Output: 32-byte hash.
pub fn keccak256(input: &[u8], output: &mut [u8; 32]) {
    unsafe {
        ecall3(
            SYSCALL_KECCAK256,
            input.as_ptr() as u32,
            input.len() as u32,
            output.as_mut_ptr() as u32,
        );
    }
}

/// Accelerated ecrecover. Input is 128 bytes: msg_hash[32] + v[32] + r[32] + s[32].
/// Output is 32 bytes: zero-padded address (12 zeros + 20-byte address).
/// Returns 1 on success, 0 on failure.
pub fn ecrecover(input: &[u8; 128], output: &mut [u8; 32]) -> u32 {
    unsafe {
        ecall3(
            SYSCALL_ECRECOVER,
            input.as_ptr() as u32,
            output.as_mut_ptr() as u32,
            0,
        )
    }
}

/// Accelerated SHA-256 hash. Computed by the host at native speed.
pub fn sha256(input: &[u8], output: &mut [u8; 32]) {
    unsafe {
        ecall3(
            SYSCALL_SHA256,
            input.as_ptr() as u32,
            input.len() as u32,
            output.as_mut_ptr() as u32,
        );
    }
}
