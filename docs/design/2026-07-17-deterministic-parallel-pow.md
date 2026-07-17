# Deterministic Parallel Proof Of Work

Status: accepted

## Problem

The functional native benchmark occasionally emitted a different valid proof from the same input.
The previous parallel grinder stopped at the first worker to publish a valid nonce. Workers searched
different residue classes, so OS scheduling selected the proof-of-work nonce. PCS then mixed that
nonce into the channel before FRI query sampling. Different valid nonces therefore produced
different query positions, decommitments, proof sizes, and canonical proof bytes.

This was a baseline correctness defect, not a session-twiddle regression. Preserved pre-session and
session binaries both reproduced it. A bounded `log10x8` run produced the common 20,959-byte proof
and rarer 20,441- and 24,645-byte proofs; all verified because every selected nonce was valid.

The same code also joined every thread-array slot after silently continuing on a spawn error. Slots
whose spawn failed were uninitialized, and their residue classes were not searched.

## Contract

Parallel grinding returns the globally lowest valid nonce, independent of worker count, scheduling,
or partial thread-spawn failure.

Each worker searches one increasing strided residue class. A shared atomic upper bound starts at
`maxInt(u64)`. A worker atomically lowers it when it reaches the first valid nonce in its residue and
stops when its next candidate cannot beat the bound. Once all workers join, the bound is the minimum
of every residue-class minimum and is therefore the global minimum.

Successful thread handles are stored compactly and only initialized handles are joined. A failed or
intentionally unspawned residue class is completed synchronously under the best bound already found.
Stride overflow terminates that residue safely. Zero-bit proof of work remains nonce zero.

## Correctness Evidence

Commit `9c52a9d` adds worker-count, repetition, nonce-minimality, zero-bit, zero-successful-spawn, and
partial-spawn tests. Full Zig tests, source conformance, API parity, and formatting pass.

For `log10x8` under the functional protocol, worker counts 1 and 16 now both select nonce 971 and
emit the same 23,569-byte proof with SHA-256
`1beb388cda4e2941e5a65c11653d78de3116ae95a686538105312c29ff9f6f0c`. A 21-sample run was byte
identical throughout. A separate 101-sample ReleaseFast sweep was byte identical for every CPU and
Metal row.

The clean CPU/Metal matrix produced these exact canonical proofs:

| Workload | Proof bytes | Canonical proof SHA-256 |
| --- | ---: | --- |
| `log10x8` | 23,569 | `1beb388cda4e2941e5a65c11653d78de3116ae95a686538105312c29ff9f6f0c` |
| `log12x16` | 32,853 | `2e5d5b3847d3231073f9bcf5a6e89da2b2c8f847f52d73b7de5aa2899598e6e8` |
| `log14x32` | 44,225 | `9446656c07382cdc196304883693b51afe9603bfd149a602c8757db4bed4bbec` |

CPU and Metal bytes matched at every row. Pinned Rust Stwo commit
`a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2` accepted all six emitted artifacts.

## Performance Evidence

This is a correctness change, not a free choice of a faster FRI query set. The deterministic nonce
changes downstream query geometry, so the A/B measures the full required semantic change rather
than an isolated grinder speedup. Five warmups and 101 samples gave these median prove times:

| Backend | Workload | Scheduling-dependent (ms) | Deterministic (ms) | Change |
| --- | --- | ---: | ---: | ---: |
| CPU | `log10x8` | 2.063000 | 2.030375 | +1.61% |
| CPU | `log12x16` | 6.046958 | 6.031875 | +0.25% |
| CPU | `log14x32` | 15.421625 | 15.373833 | +0.31% |
| Metal | `log10x8` | 4.400916 | 4.403417 | -0.06% |
| Metal | `log12x16` | 8.037500 | 8.044041 | -0.08% |
| Metal | `log14x32` | 16.610500 | 16.921584 | -1.84% |

All rows remain within the performance program's correctness-change bounds. Determinism removes a
source of proof-size and timing variance from every later profiler and streaming benchmark.
