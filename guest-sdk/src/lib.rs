//! stwo-zig Guest SDK — syscall wrappers for RISC-V zkVM guest programs.
//!
//! Guest programs link this crate to communicate with the host via ECALL.
//! The ABI uses register a7 (x17) for the syscall number and a0-a6 for args.

#![no_std]

extern crate alloc;

pub mod syscall;
pub mod io;
pub mod allocator;
pub mod entry;
pub mod precompiles;

// Re-export key types for convenience.
pub use io::{read_input, commit_output};
pub use syscall::{halt, hint_len, hint_read};
