//! Smoke test guest program.
//!
//! Reads a u32 hint, doubles it, and commits the result.
//! Used to validate the full guest↔host syscall pipeline.

#![no_std]
#![no_main]

extern crate alloc;

use stwo_guest_sdk::syscall;

stwo_guest_sdk::guest_main!(smoke_main);

fn smoke_main() {
    // Read a hint: expect 4 bytes (a u32 in little-endian).
    let len = syscall::hint_len();
    if len == 0 {
        // No hint provided — just commit a fixed value.
        let result: u32 = 0xDEAD_BEEF;
        syscall::commit(&result.to_le_bytes());
        return;
    }

    let mut buf = [0u8; 4];
    syscall::hint_read(&mut buf);
    let value = u32::from_le_bytes(buf);

    // Double it.
    let result = value.wrapping_mul(2);

    // Commit the result.
    syscall::commit(&result.to_le_bytes());
}
