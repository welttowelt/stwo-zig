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
- Retained Metal trees with selective opening readback. Full Merkle layers are
  no longer copied to host memory; decommitment blits only queried child and
  sibling hashes per level.
- Backend-selected trace, composition, and FRI commitment constructors.
- Raw-column FRI quotient evaluation on Metal. The GPU applies QM31
  contribution coefficients and denominator inverses without constructing four
  pre-scaled copies of every source column on CPU.
- Two-stage sampled-polynomial evaluation on Metal. Evaluation bases are built
  once per `(log size, point)` and shared by all columns, followed by cooperative
  dot products. Coefficient slices upload directly into the Metal arena without
  a second Zig flattening copy.
- Opcode trace generation no longer allocates protocol-implicit zero register
  history columns that are discarded before commitment.
- A dedicated `riscv-metal-bench` executable and direct `--input-u32` support
  for the shared Rust guest ELF.

## Exact benchmark

Workload and protocol parameters match the preserved Rust/Zig comparison:

- ELF: `stark-v/guest/guest-bin fib_input`, 58,032 bytes
- input: little-endian `u32(500000)`
- cycles: 2,500,157
- Blake2s, blowup 1, PoW 10, 3 FRI queries
- same M4 Max laptop

Performance runs must use `-Doptimize=ReleaseFast`; Debug proving is roughly
an order of magnitude slower and is not a benchmark. The exact artifact can be
reproduced from `ClementWalter/stark-v` commit
`d478f783055aa0d73a93768a433a3c6c31c91d1c` with:

```sh
cd guest/guest-bin
cargo build --release --bin fib_input
zig build riscv-metal-bench -Doptimize=ReleaseFast
```

Original transaction-engine Metal runs:

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

After selective Merkle opening, omitted implicit-zero trace allocation, and the
two-stage sampled evaluator, three exact runs measured:

| Run | Prove | Prove MHz | Run + prove | Run + prove MHz |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 683.5 ms | 3.658 | 902.1 ms | 2.771 |
| 2 | 699.3 ms | 3.575 | 906.5 ms | 2.758 |
| 3 | 681.2 ms | 3.670 | 890.6 ms | 2.807 |
| Median | **683.5 ms** | **3.658** | **902.1 ms** | **2.771** |

This is 1.14x faster than the first Metal median and 13.23x faster than the
same-program Rust baseline on prove-only wall time.

The resident transform/quotient pass on 2026-07-11 adds:

- fused, parity-tested circle IFFT/RFFT with 2,048-element threadgroup tiles;
- one-command IFFT, coefficient extension, and RFFT over zero-copy contiguous
  backing arenas;
- GPU-blit commitment upload from contiguous column runs;
- direct-run sampled polynomial evaluation without a flattened coefficient
  staging buffer;
- direct-run FRI numerator accumulation without flattening the trace; and
- parallel generation of independent RISC-V memory shards.

The follow-up residency boundary pass also writes quotient results directly in
the native coordinate-major `SecureColumnByCoords` layout, removing the 40 MiB
row-major compatibility transpose. Circle-to-line and variable-step line folds
now dispatch through backend hooks instead of bypassing the backend in
`core/fri.zig`. At that checkpoint the Metal implementation still delegated
those hooks to CPU pending a device-backed secure-column owner.

The resident FRI pass replaces that temporary boundary with Metal-owned mapped
storage on Apple unified memory:

- `SecureColumnByCoords` and `LineEvaluation` can carry an external resident
  owner and release the retained `MTLBuffer` instead of calling the Zig
  allocator;
- quotient output is born in a Metal allocation and remains coordinate-major;
- circle-to-line and variable-step line folds write into new resident buffers;
- retained FRI layers are transposed to coordinate-major form on Metal before
  commitment; and
- decommitment gathers fold subsets directly from mapped coordinate storage,
  removing the previous full-column `[]QM31` proof-assembly copy.

Direct CPU-oracle tests cover circle folding, two-step line folding, and QM31
coordinate conversion. On the available generated 2.5M-cycle workload, three
prove runs measured 2,349.5 ms, 2,094.5 ms, and 2,064.7 ms. This workload has a
different 1,925-column trace and is not comparable to the exact shared-ELF
results above. Its resident FRI commit measured 352-358 ms on the stable runs,
while FRI decommit fell to 1 ms.

Fiat-Shamir challenge drawing and final proof assembly each round to 0 ms in
the stage profile. FRI decommit is 1 ms. They remain CPU control operations:
each FRI layer is transcript-dependent on the preceding 32-byte Merkle root,
and a Metal command-buffer round trip would cost more than the scalar work.
All bulk transcript inputs, layer values, hashes, and queried openings remain
Metal-owned or compactly gathered.

Three current exact runs:

| Run | Prove | Prove MHz | Run + prove | Run + prove MHz |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 401.2 ms | 6.232 | 625.2 ms | 3.999 |
| 2 | 389.1 ms | 6.426 | 610.2 ms | 4.097 |
| 3 | 390.3 ms | 6.406 | 610.8 ms | 4.093 |
| Median | **390.3 ms** | **6.406** | **610.8 ms** | **4.093** |

The current prove-only median is 2.00x faster than the first Metal median,
3.10x faster than the preserved Zig CPU median, and 23.16x faster than the
same-program Rust baseline.

## Kernel and stage evidence

- Synthetic Blake2s tree, 2,106 uniform log-16 columns:
  - 138,018,816 cells, 526.5 MiB input
  - best GPU tree time: 12.309 ms
  - GPU throughput: 11.21 billion committed cells/s
  - one-copy wall time: 67.806 ms, 2.04 billion cells/s
- Raw FRI quotient kernel on the full workload: 9.4-13.9 ms.
- Full FRI quotient/commit stage: 32.2 ms wall, including 23.6 ms of GPU work,
  down from about 478 ms on CPU.
- Main commitment: about 230-245 ms, down from about 303 ms on CPU.
- Sampled-value evaluation is now about 18-24 ms wall and consumes contiguous
  coefficient runs directly, without a flattened upload arena.
- The dominant fused circle IFFT/RFFT group is 57.236 ms on GPU.
- Parallel RISC-V infrastructure trace generation is about 63-68 ms and still
  originates on CPU.

## Correctness gates

- Mixed-log-size Metal Merkle root equals `MerkleProverLifted` CPU root.
- Metal compatibility-tree reconstruction equals the CPU root.
- A complete Metal-engine RISC-V proof is accepted by the CPU verifier.
- The transaction-engine behavioral test observes one initialization, two trace
  commitments, and one final prove call.
- The exact 2.5M-cycle benchmark verifies on every measured run.

## Remaining high-value work

1. Generate opcode and infrastructure columns directly into Metal buffers,
   removing the remaining source-to-coefficient arena transfer.
2. Retain FRI quotient output on device and perform folds there. Merkle layers
   are already resident and opening reads only the compact authentication path.
3. Move Fiat-Shamir state, query generation, and compact proof packing into the
   transaction command stream.
4. Replace runtime source compilation with an embedded AOT metallib. Current
   benchmarks warm the persistent runtime before measured proving.
5. Add the adapted Cairo AIR/witness bridge before claiming SN PIE proving
   numbers.

The existing AIR and LogUp soundness limitations documented in
`riscv-rust-parity.md` still apply. Performance comparisons do not establish
sound equivalence with Rust STWO.
