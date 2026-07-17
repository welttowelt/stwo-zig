# Metal Backend Peer Review: ClementWalter/stwo PR #6

Status: architecture evidence complete; stwo-zig performance rows remain diagnostic until the
raw-Stwo Rust-oracle root mismatch is fixed

## Scope

This review compares the stwo-zig CPU and Metal proving architecture with
[ClementWalter/stwo PR #6](https://github.com/ClementWalter/stwo/pull/6), pinned at
[`07ea1ccca13351028da94e66babf79e7ce91437f`](https://github.com/ClementWalter/stwo/commit/07ea1ccca13351028da94e66babf79e7ce91437f).
The comparison uses pure Stwo wide Fibonacci, not Cairo execution or SN PIEs.

The peer branch is strong systems work. Its primary lesson is not a faster field multiply or a
single fused shader. It organizes the complete proof around unified-memory residency, low memory
pass counts, and few host-visible synchronization boundaries while preserving baseline proof
identity.

## Executive Finding

PR #6 is not a standalone Metal backend. It is an optimized Rust `CpuBackend` that dispatches
eligible operations to Metal and otherwise falls back to CPU/SIMD. The branch also contains a
large CPU/SIMD optimization campaign that predates its Metal work.

Its published `22.2x` wide-Fibonacci headline compares the original scalar CPU baseline with the
combined optimized CPU/SIMD plus Metal branch. At `2^22` rows:

- baseline CPU: 39.35 s;
- optimized CPU/SIMD: 2.70 s, a 14.57x baseline speedup;
- optimized CPU/SIMD plus Metal: 1.77 s;
- direct incremental Metal uplift: 1.53x.

Metal loses to the optimized CPU lane through `2^18` on the published M2 Max campaign and crosses
over at `2^20`. On this M5 Max reproduction it crosses by `2^18`.

The branch's architectural advantages are nevertheless directly relevant. At the identical
`2^18 x 100` workload on this machine it completes the measured execution, proof, and verification
phases in 88.53 ms. The current stwo-zig request takes 253.58 ms. The difference is large enough
that threshold tuning or small kernel fusion cannot close it.

## Evidence Boundary

### Peer implementation

- Head: `07ea1ccca13351028da94e66babf79e7ce91437f`
- Base: `9f7c19a946c38be91faa5bd3dba915448b80ab73`
- Build: Rust release, thin LTO, `parallel,slow-tests[,metal]`
- Host: Apple M5 Max, 18 CPU cores, 40 GPU cores, 64 GiB
- Protocol: Blake2s, PoW 10, blowup 1, three queries, FRI fold step 1
- Workload: 100 columns, 98 recurrence constraints, `c = a^2 + b^2`
- Correctness: unchanged Rust verifier plus a matching 64-bit `DefaultHasher` value over proof
  debug text

### stwo-zig

- Head during measurement: `5843df9`
- Build: Zig `ReleaseFast`
- Host and protocol: identical to the peer run above
- Workload geometry: identical rows, columns, recurrence, and PCS parameters
- Correctness: Zig CPU and Metal produced equal canonical proof bytes and both passed the Zig
  verifier
- Metal evidence: per-proof dispatch/fallback telemetry is present

The stwo-zig rows are not acceptance results. The raw-Stwo oracle pinned at
`a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2` rejects the current artifact at the first Merkle root.
The proof is using the unprefixed lifted Blake protocol required by the newer Cairo pin, while the
raw-Stwo pin requires domain-separated leaf and node hashes. Performance evidence cannot be
promoted until the repository supports both authenticated protocol versions and the raw proof
passes the pinned Rust verifier.

## Published PR #6 Results

The direct Metal value is `optimized CPU / optimized+Metal`, not the PR's baseline speedup column.

| log2 rows | Baseline | Optimized CPU | Optimized + Metal | CPU gain | Direct Metal gain |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 14 | 0.15 s | 0.02 s | 0.14 s | 7.50x | 0.14x |
| 16 | 0.58 s | 0.06 s | 0.18 s | 9.67x | 0.33x |
| 18 | 2.42 s | 0.22 s | 0.28 s | 11.00x | 0.79x |
| 20 | 9.50 s | 0.78 s | 0.58 s | 12.18x | 1.34x |
| 22 | 39.35 s | 2.70 s | 1.77 s | 14.57x | 1.53x |

The source data is the PR's
[`results.csv`](https://github.com/ClementWalter/stwo/blob/07ea1ccca13351028da94e66babf79e7ce91437f/benchmarks/results/2026-06-11-0059/results.csv).
The harness measures a fresh Rust test process at 10 ms resolution. This is useful campaign
evidence but too coarse for small proofs or stage-level decisions.

## Same-Machine Bounded Reproduction

### `2^14 x 100`

The peer branch verifies the same proof hash in both lanes. Its instrumented phase sum is nearly
equal, while the warm official test process favors CPU because Metal setup dominates.

| Implementation | Lane | Measured request/phase time | Trace-row MHz | Result |
| --- | --- | ---: | ---: | --- |
| Peer Rust | optimized CPU | 47.13 ms | 0.348 | verified |
| Peer Rust | Metal hybrid | 47.88 ms | 0.342 | verified, same hash |
| stwo-zig | CPU | 28.41 ms | 0.577 | Zig verified |
| stwo-zig | Metal hybrid | 34.71 ms | 0.472 | Zig verified, same bytes |

These timing boundaries are close but not exact. The peer phase sum includes per-proof twiddle
precompute; stwo-zig constructs its session twiddles before request timing. The row is evidence of
fixed-cost behavior, not a ranking.

### `2^18 x 100`

This is the largest exact shared geometry allowed by the current stwo-zig `2^25` committed-cell
guard. One proof per lane was used to avoid a heavy sweep.

| Implementation | Lane | Proof stage | Full request/phase sum | Direct Metal uplift |
| --- | --- | ---: | ---: | ---: |
| Peer Rust | optimized CPU | 59.55 ms core | 106.91 ms | - |
| Peer Rust | Metal hybrid | 49.68 ms core | 88.53 ms | 1.208x total |
| stwo-zig | CPU | 229.12 ms | 314.76 ms | - |
| stwo-zig | Metal hybrid | 167.71 ms | 253.58 ms | 1.241x request |

The stwo-zig CPU and Metal canonical proof SHA-256 is
`9a3508b867048340edce3f70b0009da0314e3c42341f5a82edead312a10b51ba`.
The peer CPU and Metal regression hash is `47b863fcc71b4c8c`. These hashes use different encodings
and are not comparable with each other.

The peer phase sum delivers 2.961 trace-row MHz and about 296 committed Mcells/s. stwo-zig Metal
delivers 1.563 trace-row MHz within its proof timer and 1.034 trace-row MHz over the complete
request. Different timing boundaries are intentionally kept visible.

## Peer Architecture

PR #6 maximizes large-trace throughput through these decisions:

1. One process-wide Metal device and ordered command queue.
2. Unified-memory, page-aligned, zero-copy buffers where eligible.
3. Tier-2 argument-buffer GPU addresses for wide column sets.
4. A 32 KiB threadgroup-tiled FFT pass with 1,024 threads per group.
5. Coefficient zero-extension fused into the first RFFT pass.
6. Same-stage columns encoded into shared command buffers.
7. Packed Blake2s leaves hashed directly without an intermediate packing materialization.
8. FRI folds encoded with construction of the next layer's packed Merkle tree.
9. GPU constraint accumulation, quotient combination, OOD evaluation, and twiddle generation.
10. Explicit size thresholds with CPU/SIMD fallback.

The central source files are
[`fft.rs`](https://github.com/ClementWalter/stwo/blob/07ea1ccca13351028da94e66babf79e7ce91437f/crates/stwo/src/prover/backend/metal/fft.rs),
[`fri.rs`](https://github.com/ClementWalter/stwo/blob/07ea1ccca13351028da94e66babf79e7ce91437f/crates/stwo/src/prover/backend/metal/fri.rs),
[`blake2s.rs`](https://github.com/ClementWalter/stwo/blob/07ea1ccca13351028da94e66babf79e7ce91437f/crates/stwo/src/prover/backend/metal/blake2s.rs), and
[`constraints.rs`](https://github.com/ClementWalter/stwo/blob/07ea1ccca13351028da94e66babf79e7ce91437f/crates/stwo/src/prover/backend/metal/constraints.rs).

One PR description claim needs qualification. The combined commitment path still waits once after
IFFT and again after the RFFT-plus-Merkle chain. It is substantially batched, but it is not one
uninterrupted command buffer for the complete commitment.

## Current stwo-zig Hot Path

The bounded `ReleaseFast --profiled` log-18 Metal sample reports:

| Stage | CPU | Metal | Observation |
| --- | ---: | ---: | --- |
| Input/trace preparation | 85.3 ms | 85.5 ms | no general Metal benefit |
| Main trace commit | 75.1 ms | 40.5 ms | Metal helps, peer is still faster |
| Main trace Merkle | 37.6 ms | 11.3 ms | resident hashing is valuable |
| Sampled-value evaluation | 38.2 ms | 16.1 ms | Metal helps materially |
| Composition evaluation | 7.1 ms | 6.8 ms | effectively unchanged |
| Composition commit | 10.3 ms | 11.0 ms | launch/residency overhead erases benefit |
| FRI quotient build + commit | 86.0 ms | 84.6 ms | dominant unaccelerated boundary |
| Complete core prove | 146.8 ms | 123.5 ms | 2.49x slower than peer Metal core |

The Metal telemetry is more revealing than the aggregate time:

- 25 Metal dispatches;
- 19 CPU fallbacks;
- 19 host Merkle commits;
- 17 Metal line-FRI folds;
- only two resident Merkle commits.

The present path accelerates each FRI fold but repeatedly returns to host Merkle work. This is the
highest-confidence architectural explanation for the 84.6 ms FRI stage and the first target after
raw-Stwo oracle parity.

## What To Adopt

### 1. Versioned Merkle protocol authority

Before performance work, separate the lifted Blake protocols:

- raw Stwo `a8fcf4bd`: 64-byte `leaf` and `node` domain prefixes;
- Cairo Stwo `9d7e3d6`: plain leaf bytes and plain child concatenation.

The selected protocol must be part of the prover engine type/configuration, Metal pipeline key,
artifact manifest, proof statement, verifier adapter, and benchmark report. CPU and Metal must
select the same protocol without global mutable state.

### 2. Resident FRI fold-tree chains

For each FRI layer, keep four QM31 coordinates resident, fold into the next evaluations, hash the
packed coordinate leaves directly, build parents, and expose only the next transcript root. One
command buffer should own the complete fold-plus-tree dependency chain for a layer. No packed-leaf
buffer or host Merkle tree should be materialized.

Acceptance:

- CPU and Metal layer evaluations, roots, and decommitments agree after every layer;
- host Merkle commits fall from 19 to only genuinely small terminal cases;
- synchronization count is reported and decreases;
- canonical proofs pass the pinned Rust verifier.

### 3. Commitment transaction batching

Make a commitment an explicit transaction:

```text
input columns
  -> batched IFFT
  -> resident coefficient expansion
  -> batched RFFT/LDE
  -> direct packed leaves
  -> parent chain
  -> transcript root
```

The transaction owns allocations, encoders, command buffers, and its one unavoidable transcript
observation. RFFT zero-extension belongs in the first load, not in a separate kernel.

### 4. Width-aware bindless descriptors

Retain the resident arena but introduce immutable per-geometry column descriptor tables containing
GPU addresses, lengths, strides, field kind, and liveness epoch. Build and authenticate them once
per admitted geometry. Do not rebuild buffer bindings per proof or hide a fallback when alignment
or device limits reject the bindless path.

### 5. Generated AIR accumulation without manual shader duplication

PR #6's manual `metal_constraint_body()` hook is effective for wide Fibonacci but is not a general
compiler boundary. stwo-zig should compile authenticated evaluator IR into Metal and scalar/SIMD
implementations from the same typed program. Per-component cumulative accumulator equality against
the Rust oracle remains the fast development loop.

### 6. Threshold policy from measured transactions

Thresholds apply to complete transactions, not individual kernels. The selection model must use
rows, width, field coordinates, buffer residency, expected command buffers, fallback count, and
current pipeline readiness. Every decision and fallback is emitted in proof telemetry.

## What Not To Copy

- A manual AIR-specific MSL string as the general compiler interface.
- Runtime source JIT as the production path.
- Silent GPU fallback with no dispatch evidence.
- Per-module mutexes held while waiting for command-buffer completion.
- A 64-bit debug-text hash as the final proof-identity oracle.
- Thin-LTO or CPU improvements counted as Metal speedup.
- Fresh-process, 10 ms-resolution timing as the only benchmark boundary.
- Fixed 32 KiB/1,024-thread FFT geometry without device-family validation.

## Concrete Delivery Order

1. Restore raw-Stwo pinned Rust parity with explicit prefixed and plain lifted-Blake protocols.
2. Add exact cross-Rust CPU/Metal proof gates to the native proof matrix.
3. Extend telemetry with command-buffer, wait, host-Merkle, and per-transaction fallback counts.
4. Implement direct packed FRI leaves and a fold-plus-tree command chain.
5. Fuse coefficient zero-extension into the resident RFFT first pass.
6. Batch complete commitments to transcript observation boundaries.
7. Move immutable column/GPU-address descriptors into admitted prepared state.
8. Profile log-18 width-100 with Metal System Trace and encoder counters.
9. Run ten verified mixed proofs over logs 14, 16, and 18 in one persistent process.
10. Only then raise the memory guard for a cooled, one-sample log-19 or log-20 crossover check.

The first performance milestone is not a target MHz chosen in isolation. It is elimination of the
19 host Merkle fallbacks while preserving canonical proof bytes and pinned Rust verification. The
peer log-18 result shows that this architecture can support roughly 3 trace-row MHz at this width
on this machine; it does not prove that copying its kernels alone will produce that result.
