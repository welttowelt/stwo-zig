//! High-level typed I/O using postcard serialization.
//!
//! Provides `read_input<T>()` and `commit_output<T>()` that handle
//! serialization/deserialization automatically.

extern crate alloc;

use alloc::vec;
use alloc::vec::Vec;
use serde::{de::DeserializeOwned, Serialize};

use crate::syscall;

/// Read the next hint as a deserialized value of type T.
///
/// Protocol:
/// 1. Call HINT_LEN to get the size.
/// 2. Allocate a buffer.
/// 3. Call HINT_READ to fill the buffer.
/// 4. Deserialize from postcard format.
pub fn read_input<T: DeserializeOwned>() -> T {
    let len = syscall::hint_len() as usize;
    let mut buf = vec![0u8; len];
    let bytes_read = syscall::hint_read(&mut buf) as usize;
    buf.truncate(bytes_read);
    postcard::from_bytes(&buf).expect("failed to deserialize input")
}

/// Read raw hint bytes (no deserialization).
pub fn read_raw_hint() -> Vec<u8> {
    let len = syscall::hint_len() as usize;
    let mut buf = vec![0u8; len];
    let bytes_read = syscall::hint_read(&mut buf) as usize;
    buf.truncate(bytes_read);
    buf
}

/// Commit a serializable value as public output.
///
/// Serializes with postcard, then calls COMMIT syscall.
pub fn commit_output<T: Serialize>(val: &T) {
    let bytes = postcard::to_allocvec(val).expect("failed to serialize output");
    syscall::commit(&bytes);
}

/// Commit raw bytes as public output.
pub fn commit_raw(data: &[u8]) {
    syscall::commit(data);
}

/// Write to stdout/journal (fd=1).
pub fn print(msg: &[u8]) {
    syscall::write(1, msg);
}
