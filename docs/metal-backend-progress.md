# Metal backend progress

Measured 2026-07-10 on the local 32-GPU-core Apple M4 Max.

## Implemented

- A transaction-level `proveRiscVWithEngine` substitution point. The frontend
  no longer chooses `CpuBackend` inside commitment or final proving calls.
- `CpuProverEngine` and `MetalProverEngine` implementations with opaque scheme
  ownership.
- A self-contained Objective-C Metal runtime and MSL kernel library compiled by
  the Zig build.
- Prefix-compatible Blake2s leaf hashing and all parent reductions in one Metal
  command buffer.
- Mixed-log-size lifted-column hashing with stable log-size ordering.
- Retained Metal trees and a compatibility layer readback for the current CPU
  decommitter.
- Backend-selected trace, composition, and FRI commitment constructors.
- Raw-column FRI quotient evaluation on Metal. The GPU applies QM31
  contribution coefficients and denominator inverses without constructing four
  pre-scaled copies of every source column on CPU.
- A cooperative 256-thread sampled-polynomial kernel. It is retained and parity
  tested but not enabled because coefficient upload makes it neutral on the
  current nonresident coefficient representation.
- A dedicated `riscv-metal-bench` executable and direct `--input-u32` support
  for the shared Rust guest ELF.

## Exact benchmark

Workload and protocol parameters match the preserved Rust/Zig comparison:

- ELF: `stark-v/guest/guest-bin fib_input`, 58,032 bytes
- input: little-endian `u32(500000)`
- cycles: 2,500,157
- Blake2s, blowup 1, PoW 10, 3 FRI queries
- same M4 Max laptop

Three Metal runs:

| Run | Prove | Prove MHz | Run + prove | Run + prove MHz |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 780.4 ms | 3.204 | 997.3 ms | 2.507 |
| 2 | 764.8 ms | 3.269 | 974.4 ms | 2.566 |
| 3 | 794.0 ms | 3.149 | 1003.7 ms | 2.491 |
| Median | **780.4 ms** | **3.204** | **997.3 ms** | **2.507** |

Controls:

- Zig CPU preserved median: 1,211.0 ms prove, 2.065 MHz.
- Zig CPU post-refactor check: 1,195.8 ms prove, 2.091 MHz.
- Rust shared-ELF baseline: 9,041 ms prove, 0.2765 MHz.

Therefore the current Metal engine is 1.55x faster than the preserved Zig CPU
median and 11.59x faster than the Rust baseline on prove-only wall time. It is
not yet an order of magnitude faster than the Zig CPU implementation.

## Kernel and stage evidence

- Synthetic Blake2s tree, 2,106 uniform log-16 columns:
  - 138,018,816 cells, 526.5 MiB input
  - best GPU tree time: 12.309 ms
  - GPU throughput: 11.21 billion committed cells/s
  - one-copy wall time: 67.806 ms, 2.04 billion cells/s
- Raw FRI quotient kernel on the full workload: 9.4-13.9 ms.
- Full FRI quotient/commit stage: about 109-116 ms, down from about 478 ms on
  CPU.
- Main commitment: about 230-245 ms, down from about 303 ms on CPU.
- Sampled-value evaluation remains about 165-173 ms on CPU.
- Opcode/infrastructure trace generation remains about 164-173 ms on CPU.

## Correctness gates

- Mixed-log-size Metal Merkle root equals `MerkleProverLifted` CPU root.
- Metal compatibility-tree reconstruction equals the CPU root.
- A complete Metal-engine RISC-V proof is accepted by the CPU verifier.
- The transaction-engine behavioral test observes one initialization, two trace
  commitments, and one final prove call.
- The exact 2.5M-cycle benchmark verifies on every measured run.

## Remaining high-value work

1. Keep coefficient polynomials resident from interpolation through sampled
   evaluation; this removes repeated coefficient uploads and enables the
   cooperative sampled-value kernel.
2. Port batched circle IFFT/RFFT into the transaction arena. CPU transforms are
   still most of the main-commit wall time.
3. Generate opcode and infrastructure columns directly into Metal buffers.
4. Retain FRI quotient output and Merkle layers on device, then perform folds,
   query generation, and sibling gathering without compatibility readback.
5. Replace runtime source compilation with an embedded AOT metallib. Current
   benchmarks warm the persistent runtime before measured proving.
6. Add the adapted Cairo input bridge before claiming SN PIE proving numbers.

The existing AIR and LogUp soundness limitations documented in
`riscv-rust-parity.md` still apply. Performance comparisons do not establish
sound equivalence with Rust STWO.

