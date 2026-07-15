# RISC-V Rust/Zig parity benchmark

Measured 2026-07-10 on one Apple M4 Max (14 logical CPUs, 36 GiB RAM). Both
implementations execute the exact same 58,032-byte `fib_input` ELF and agree on
the VM cycle count. Both use Blake2s, blowup factor 2, last-layer degree bound
0, and fold step 1.

## Results

| Input | Security | Implementation | Prove | Throughput | Physical trace cells | Cells/cycle | Peak RSS |
|---:|---|---|---:|---:|---:|---:|---:|
| 10,000 | PoW 10, 3 queries | Rust | 1.465 s | 34.2 kHz | 20,107,232 | 400.97 | not recorded |
| 10,000 | PoW 10, 3 queries | Zig | 0.288 s median | 174.1 kHz | 3,973,240 | 79.23 | 157 MB |
| 10,000 | PoW 24, 70 queries | Rust | 1.586 s | 31.6 kHz | 20,107,232 | 400.97 | not recorded |
| 10,000 | PoW 24, 70 queries | Zig | 0.399 s | 125.7 kHz | 3,973,240 | 79.23 | not recorded |
| 500,000 | PoW 10, 3 queries | Rust | 9.041 s | 276.5 kHz | 214,094,368 | 85.63 | 6.94 GB |
| 500,000 | PoW 10, 3 queries | Zig | 1.211 s median | 2.065 MHz | 92,054,392 | 36.82 | 1.53 GB |

The published 567 kHz Rust result uses `fib(5,000,000)`, so it is not a valid
ratio for the smaller runs. On the exact 500k workload, Zig proving is now
7.47x Rust throughput and 7.32x faster than the 8.859 s Zig result that preceded
the large-domain sharding work. Median execution plus proving is 1.453 s, or
1.721 MHz.

The additional gain comes from four-message SIMD Blake2s, removing known-zero
placeholder columns, sharding opcode and memory rows into log-16 components,
and overlapping opcode and infrastructure trace generation. Sharding reduces
the global FRI domain without dropping populated rows. Peak RSS is now about
78% below Rust.

The requested 10x improvement from the preceding Zig result would require
roughly 0.886 s proving time, or 2.82 MHz. The measured CPU result is 1.211 s,
so this pass reaches 7.32x rather than 10x. The remaining 0.325 s requires a
sound narrower AIR or a Metal/GPU backend; smaller CPU shards and eight-lane
vectors both regressed locally.

## Layout findings

Current stark-v commits 1,053 main and 636 interaction columns. Zig's sharded
layout commits 2,106 narrower main columns for this ELF and models 2,772 logical
interaction columns. It omits protocol-known zero lookup, root, multiplicity,
and register-history placeholders rather than committing their padded domains.

At 500k, Zig's omitted interaction columns represent another 167,787,320
logical cells. Including them gives 103.93 logical cells/cycle, versus Rust's
85.63. The completed AIR therefore still needs real cross-shard LogUp placement;
skipping current zero placeholders is a memory optimization, not proof-system
parity.

Both implementations use the same 443-column Poseidon2 trace. There is no
narrower Rust layout to copy. Those columns keep the permutation constraints
quadratic; replacing them with higher-degree inline constraints or multi-row
rounds needs a separate proof-degree benchmark before it can be considered an
improvement.

## Correctness finding

The Zig prover previously advised the OS that live anonymous Merkle layers could
be discarded, then attempted to use them for decommitment. This produced
nondeterministic `RootMismatch` failures under memory pressure. Live trace and
FRI trees are now retained. Merkle decommitment also now sorts arbitrary folded
query positions for witness construction and restores values to protocol order.
A lower-memory design must recompute or persist authentication data rather than
discard it.

The Zig RISC-V AIR still has placeholder constraint quotients and no real LogUp
interaction. Consequently, these measurements are implementation diagnostics,
not evidence that Zig currently produces a Rust-equivalent sound proof.

Machine-readable measurements are in
`vectors/reports/riscv_parity_report.json`.
