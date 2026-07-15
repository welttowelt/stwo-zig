//! Accelerated cryptographic precompiles via host syscalls.
//!
//! These functions replace software implementations of expensive
//! crypto operations with single-syscall host calls, reducing
//! millions of VM cycles to a handful of instructions per call.

use crate::syscall;

/// Accelerated keccak256. Returns the 32-byte hash.
///
/// This function has the same signature as `sha3::Keccak256::digest()`
/// and can be used as a drop-in replacement.
pub fn keccak256(input: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    syscall::keccak256(input, &mut output);
    output
}

/// Accelerated SHA-256. Returns the 32-byte hash.
pub fn sha256(input: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    syscall::sha256(input, &mut output);
    output
}

/// Accelerated secp256k1 ecrecover.
/// Input: msg_hash (32 bytes), v (32 bytes, big-endian u256), r (32 bytes), s (32 bytes).
/// Returns the recovered 20-byte address, or None on failure.
pub fn ecrecover(msg_hash: &[u8; 32], v: &[u8; 32], r: &[u8; 32], s: &[u8; 32]) -> Option<[u8; 20]> {
    let mut input = [0u8; 128];
    input[0..32].copy_from_slice(msg_hash);
    input[32..64].copy_from_slice(v);
    input[64..96].copy_from_slice(r);
    input[96..128].copy_from_slice(s);

    let mut output = [0u8; 32];
    let success = syscall::ecrecover(&input, &mut output);
    if success == 1 {
        let mut addr = [0u8; 20];
        addr.copy_from_slice(&output[12..32]);
        Some(addr)
    } else {
        None
    }
}
