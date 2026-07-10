//! Guest program entry point for `#[no_std]` RISC-V binaries.
//!
//! Provides the `_start` symbol and panic handler. Guest programs
//! define `fn main()` which this entry point calls.

use crate::syscall;

/// Panic handler — halts the VM with exit code 1.
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    syscall::halt(1)
}

/// Entry point called by the linker. Sets up the stack (already done
/// by the Zig runner at 0x7FFF_0000) and calls the guest's main().
///
/// Guest programs should use the `guest_main!` macro instead of
/// defining `_start` directly.
#[no_mangle]
pub extern "C" fn _start() -> ! {
    extern "Rust" {
        fn main();
    }
    unsafe { main() };
    syscall::halt(0)
}

/// Macro for defining the guest main function.
///
/// Usage:
/// ```ignore
/// stwo_guest_sdk::guest_main!(my_main);
///
/// fn my_main() {
///     let input: MyInput = stwo_guest_sdk::read_input();
///     // ... process ...
///     stwo_guest_sdk::commit_output(&result);
/// }
/// ```
#[macro_export]
macro_rules! guest_main {
    ($f:ident) => {
        #[no_mangle]
        fn main() {
            $f()
        }
    };
}
