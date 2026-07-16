# RISC-V Fib: Metal versus Zig CPU

Status: verified diagnostic benchmark, 2026-07-16

This benchmark demonstrates that the generic `MetalProverEngine` proves a
non-Cairo workload end to end. It executes a generated RV32IM iterative
Fibonacci guest, builds its sharded RISC-V trace, produces a STARK proof, and
accepts that proof with the shared Zig verifier. `fib(N)` executes exactly
`5 * N - 3` VM cycles in this guest.

## Configuration

- Machine: Apple M5 Max MacBook Pro, 18 CPU cores, 64 GB RAM.
- OS: macOS 26.5.2 (25F84).
- Source HEAD: `f45b8ac7ab4082fa85784d663bbe23f733088a72` plus the working-tree changes
  described below.
- Build: Zig 0.15.2, `ReleaseFast`.
- Protocol: Blake2s, blowup factor 2 (`log_blowup_factor=1`), last-layer degree
  bound 0, fold step 1, PoW 10, 3 FRI queries.
- Measurement: three fresh-process proofs per backend and size, strictly
  sequential. The middle pass reverses size order and runs Metal before CPU.
- Acceptance: all 42 measured proofs verified; every paired run reported
  identical VM cycles, trace-cell geometry, and committed-cells-per-cycle.
- Timing: proving begins after guest execution and Metal runtime warmup.
  Run+prove includes guest execution but excludes verification. CLI total adds
  ELF generation and verification, but still excludes runtime warmup. Cold
  end-to-end is the parent-observed fresh-process wall clock and includes
  process startup, runtime warmup, execution, proving, and verification.

The CPU lane is accurately named **Zig CPU ReleaseFast with auto-SIMD hot
paths**. This repository does not contain a distinct full `SimdBackend` type.
The Metal lane is the generic hybrid `MetalProverEngine`: bulk circle
transforms, commitments, quotient work, sampled evaluation, and FRI use Metal;
RISC-V trace generation and remaining compatibility operations still use CPU.

## Results

All values are medians of three verified proofs. MHz is emitted VM cycles per
second. Fib Miter/s is the requested `N` iterations per second divided by one
million; it prevents the architecture-specific cycle count from being mistaken
for Fibonacci throughput.

### Prove only

| Fib N | VM cycles | Zig prove | Zig MHz | Zig Fib Miter/s | Metal prove | Metal MHz | Metal Fib Miter/s | Metal speedup |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 25,000 | 124,997 | 126.1 ms | 0.991 | 0.198 | 160.5 ms | 0.779 | 0.156 | 0.79x |
| 50,000 | 249,997 | 167.9 ms | 1.489 | 0.298 | 125.0 ms | 2.000 | 0.400 | 1.34x |
| 100,000 | 499,997 | 276.0 ms | 1.812 | 0.362 | 132.3 ms | 3.779 | 0.756 | 2.09x |
| 250,000 | 1,249,997 | 577.4 ms | 2.165 | 0.433 | 201.7 ms | 6.197 | 1.239 | 2.86x |
| 500,000 | 2,499,997 | 1,010.9 ms | 2.473 | 0.495 | 314.4 ms | 7.952 | 1.590 | 3.22x |
| 1,000,000 | 4,999,997 | 1,893.6 ms | 2.640 | 0.528 | 500.0 ms | 10.000 | 2.000 | 3.79x |
| 2,000,000 | 9,999,997 | 3,718.8 ms | 2.689 | 0.538 | 910.7 ms | 10.981 | 2.196 | 4.08x |

### Cold end to end

CLI total is shown to expose the post-warmup pipeline cost. E2E throughput uses
the wider fresh-process wall clock, not CLI total.

| Fib N | Zig CLI total | Zig process wall | Zig E2E MHz | Zig Fib Miter/s | Metal CLI total | Metal process wall | Metal E2E MHz | Metal Fib Miter/s | Metal speedup |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 25,000 | 134.2 ms | 144.1 ms | 0.868 | 0.174 | 166.9 ms | 207.4 ms | 0.603 | 0.121 | 0.69x |
| 50,000 | 184.6 ms | 195.9 ms | 1.276 | 0.255 | 137.8 ms | 179.7 ms | 1.391 | 0.278 | 1.09x |
| 100,000 | 307.0 ms | 317.2 ms | 1.576 | 0.315 | 158.0 ms | 199.6 ms | 2.505 | 0.501 | 1.59x |
| 250,000 | 640.2 ms | 650.6 ms | 1.921 | 0.384 | 258.7 ms | 300.6 ms | 4.158 | 0.832 | 2.16x |
| 500,000 | 1,134.4 ms | 1,147.8 ms | 2.178 | 0.436 | 427.1 ms | 472.3 ms | 5.293 | 1.059 | 2.43x |
| 1,000,000 | 2,102.1 ms | 2,118.0 ms | 2.361 | 0.472 | 698.7 ms | 747.4 ms | 6.690 | 1.338 | 2.83x |
| 2,000,000 | 4,146.1 ms | 4,166.5 ms | 2.400 | 0.480 | 1,321.4 ms | 1,368.4 ms | 7.308 | 1.462 | 3.05x |

Metal has a fixed-cost crossover between Fib25k and Fib50k. Beyond that point,
its prove-only advantage grows with the workload and reaches 4.08x at Fib2M.
Execution remains CPU in both lanes, so its roughly 410-425 ms cost at Fib2M
reduces the cold end-to-end Metal advantage to 3.05x. The fresh-process clock
also exposes roughly 40-49 ms of Metal startup and runtime warmup outside the
CLI total, compared with roughly 10-20 ms of CPU process overhead.

## Reproduction

```sh
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build riscv-bench riscv-metal-bench -Doptimize=ReleaseFast -j2

python3 scripts/riscv_fib_backend_compare.py \
  --sizes 25000 50000 100000 250000 500000 1000000 2000000 \
  --repeats 3 --pow-bits 10 --n-queries 3 \
  --output vectors/reports/riscv_fib_metal_vs_cpu_report.json
```

The machine-readable report includes every command, raw CLI output, binary
SHA-256, sample, percentile, and median. The derived schema-v2 report was
regenerated from the original stored outputs without rerunning proofs. Its
SHA-256 is
`eb09cbfdca852a993757d4c0cb5567550f7d56f91ceeb9fc1595053677f755e5`.

## Changes Required For Fib2M

Fib2M creates a 9,999,997-cycle trace with 3,376 opcode columns and 2,820
infrastructure columns. It exceeded fixed planning capacities that were sized
for smaller guests. The benchmark raises the opcode descriptor capacity from
128 to 256 and the infrastructure descriptor capacity from 256 to 512. These
are bounded statement/planner arrays; neither change alters AIR or proof
semantics. Build steps were also corrected to install the freshly compiled
benchmark binaries into `zig-out/bin`.

## Limitations

- The CLI verifies every proof but does not expose proof bytes or a proof
  digest, so this is verifier-acceptance parity rather than byte parity.
- Fresh-process samples measure warm Metal pipelines inside a newly created
  runtime, not persistent multi-proof service throughput.
- The generic Metal engine is hybrid, not the Cairo resident arena/command
  graph and not yet a completely GPU-resident frontend-independent prover.
- The current RISC-V AIR soundness limitations remain those documented in
  `docs/riscv-rust-parity.md`; these numbers are backend performance evidence,
  not a new soundness claim.
