//! Ethereum block execution guest program for stwo-zig zkVM.
//!
//! Reads a `BlockInput` from the host via hints, executes all transactions
//! using revm against a flat witness-backed state database, and commits
//! the execution result.

#![no_std]
#![no_main]

extern crate alloc;

mod atomics;
mod block_input;
mod executor;
mod witness_db;

use block_input::BlockInput;

stwo_guest_sdk::guest_main!(ethereum_main);

fn ethereum_main() {
    // Step 1: Read the block input from the host.
    let input: BlockInput = stwo_guest_sdk::read_input();

    // Step 2: Execute the block using revm with witness-backed state.
    let result = executor::execute_block(&input);

    // Step 3: Commit the execution result as public output.
    stwo_guest_sdk::commit_output(&result);
}
