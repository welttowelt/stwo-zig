# Metal-resident prover design

Status: historical architectural intent, 2026-07-10

The normative Cairo SN PIE Metal architecture is now
`docs/sn-pie-metal-production-architecture.md`. This document established the
resident-runtime direction, but its idealized ownership, memory, and command
model does not describe the current implementation and is superseded where the
unified specification differs.

## Decision

Build a prover-owned Metal runtime, not a collection of CPU backend methods that
occasionally dispatch GPU kernels. The trace, polynomial representations,
Merkle layers, composition column, FRI layers, transcript state, query positions,
and decommitment scratch remain in Metal buffers from the initial upload until a
compact proof is read back.

The CPU still creates the device, allocates the arena, encodes the known proving
graph, submits command buffers, and serializes the final proof. It does not read
intermediate columns or roots, calculate transcript challenges, fold FRI layers,
or rebuild Merkle data. Calling this completely CPU-free would be inaccurate,
but the proving data path is GPU-resident.

This is materially different from the existing CUDA backend. Its slice-shaped
contract contains placeholder methods and explicit host-bounce paths, and the
RISC-V prover currently selects `CpuBackend` directly. Metal must own the whole
proving transaction above those leaf interfaces.

## Why this architecture

The current M4 Max has 32 GPU cores, 36 GB unified memory, Metal 3,
`maxBufferLength = 21,743,271,936`, and a recommended Metal working set of
28,991,029,248 bytes. The final CPU RISC-V benchmark proves 2.5 million cycles
in a 1.211 second median with about 368 MB of physically committed M31 trace
cells. A tenfold target is therefore about 121 ms or 20.6 MHz on that exact
workload.

That target cannot be reached by accelerating only FFT or FRI. The measured CPU
stages are approximately:

| Stage | Time | Share |
| --- | ---: | ---: |
| Trace and infrastructure generation | 176 ms | 15% |
| Main commitment | 289 ms | 24% |
| Sampled values | 166 ms | 14% |
| FRI and decommitment | 480 ms | 40% |
| Preprocessed commitment and other | 100 ms | 8% |

A local Rust `stwo-metal` checkout confirms the failure mode of a transitional
backend. Its best reported Fibonacci result is 1.71 MHz and about 3x over Rust
SIMD; 40% of its 1.838 second run remains base trace generation and upload.
That is already slower than this repository's CPU result. Its kernels are useful
reference implementations, but its orchestration boundary is not the target.

## Resident transaction

`MetalProverSession` owns one device, command queue, pipeline catalog, immutable
twiddle/preprocessed cache, and reusable heaps. Each proof creates a
`MetalProofTransaction` with this lifecycle:

1. Validate a compact `ProofPlan` on CPU. It contains only dimensions, component
   descriptors, AIR program offsets, PCS parameters, and arena regions.
2. Upload VM events or an adapted Cairo prover input once into a shared staging
   buffer. The first GPU pass expands it directly into private trace regions.
3. Run trace generation, circle interpolation/LDE, leaf hashing, and Merkle
   reduction without a host-visible intermediate.
4. Run the Blake2s channel on GPU. Roots are absorbed and challenges are written
   to a small device control block.
5. Generate interaction columns and composition values from those challenges in
   place, immediately consuming or aliasing dead scratch.
6. Commit composition, run all FRI rounds, generate query positions, and gather
   openings and authentication paths on GPU.
7. Pack the compact proof into one shared readback buffer and signal completion.
8. CPU waits once, validates the result header, and serializes the proof.

The initial implementation should encode a fixed sequence of direct compute
dispatches. Domain sizes are known when the proof plan is built. Indirect
dispatch arguments are appropriate only for GPU-derived work counts such as
compacted active components or query gathers. An indirect command buffer is not
the default: it adds state and synchronization complexity without helping the
fixed protocol graph.

Fiat-Shamir does not require a host round trip. A Metal Blake2s channel kernel
can absorb a device-resident root and derive the next challenge before the next
kernel reads it. Encoder boundaries and explicit barriers preserve this order.
This is the main distinction between a resident prover and CPU-orchestrated
Metal SIMD.

## Runtime boundary

Zig should call a narrow C ABI implemented by Objective-C in
`src/backends/metal/runtime.m`. Objective-C owns Metal objects; Zig owns protocol
types and proof semantics.

The public surface should be transaction-shaped:

```c
typedef struct StwoMetalRuntime StwoMetalRuntime;
typedef struct StwoMetalPlan StwoMetalPlan;

StwoMetalRuntime *stwo_metal_create(const StwoMetalOptions *options);
int stwo_metal_compile_plan(
    StwoMetalRuntime *, const StwoMetalPlanDesc *, StwoMetalPlan **out);
int stwo_metal_prove(
    StwoMetalRuntime *, const StwoMetalPlan *, const StwoMetalInput *,
    StwoMetalProofView *out);
void stwo_metal_release_proof(StwoMetalRuntime *, StwoMetalProofView);
```

Do not expose one C function per arithmetic primitive. That recreates the
CPU-orchestrated design and permits accidental readbacks. Kernel-level functions
remain private test hooks.

In Zig, use runtime values for component counts, domain sizes, offsets, and
kernel choices. Reserve `comptime` for field layout checks, ABI assertions, and
small fixed-degree arithmetic. Do not instantiate the full prover once per AIR,
log size, hash, and tuning combination. AIR lowering produces a validated data
program plus a small set of compiled kernel families.

## Memory model

Use three resource classes:

| Class | Metal storage | Contents |
| --- | --- | --- |
| Staging/control | shared | input descriptor, transcript control, proof output |
| Persistent cache | private heap | twiddles, domains, canonical preprocessed data |
| Proof arena | private placement heaps | trace, coefficients, LDE, trees, composition, FRI |

The proof arena is planned by liveness, not by source object ownership. Regions
that never overlap alias the same heap range. In particular:

- trace-generation scratch aliases coefficient scratch;
- a column's temporary transform buffer is released after its committed LDE and
  retained coefficients have been produced;
- composition scratch aliases dead interaction-generation scratch;
- FRI layer `i + 2` aliases layer `i` once its commitment and query data are
  retained;
- only queried paths, not every dead tree layer, survive final gathering.

Start with tracked hazards for correctness. Switch proven arena regions to
untracked hazards only with explicit barriers and resource-use tests. Apple's
Metal documentation makes the tradeoff explicit: untracked resources can reduce
runtime overhead, but the application becomes responsible for barriers, fences,
or events.

On unified memory, `shared` does not imply free access. Bulk prover state remains
private so the GPU controls layout and cache behavior. Shared buffers are limited
to the one-time input and compact output/control surfaces. No host pointer is
stored in a device column descriptor.

## Kernel graph

### Trace and interaction generation

Use structure-of-arrays M31 columns and generate columns in their final
bit-reversed order. For RISC-V, upload compact execution rows and state-chain
events, then scatter by opcode component on GPU using count, prefix-sum, and
scatter passes. For Cairo, consume adapted state transitions and builtin segment
descriptors; do not route Cairo PIEs through the RISC-V AIR.

Generate implicit constants as descriptors. Never allocate or commit them.
Fuse cheap column expressions into the first consumer rather than materializing
them. Expensive reusable expressions become arena columns based on measured
reuse, not a global materialize-or-recompute rule.

### Circle transforms and commitments

Batch columns of the same log size. A threadgroup handles a transform tile using
threadgroup memory, with SIMD-group shuffles for short stages. Fuse the final LDE
write with leaf hashing where the access order permits it. Parent hashes are
reduced in the same command stream and only the root is fed to the channel.

Blake2s remains the first correctness target because it preserves proof
compatibility. Poseidon2 is a separate protocol benchmark, not a silent backend
substitution.

### AIR and quotient

Lower the AIR once into a compact evaluation program with typed M31/QM31
registers, column references, masks, and constraint accumulation operations.
The generic Metal interpreter establishes correctness. Frequently executed AIRs
may then be converted into build-time generated MSL kernels with the same ABI.

Partition large AIRs into register-bounded stages. One enormous kernel will
spill and destroy occupancy. Each stage streams contiguous positions, accumulates
QM31 coordinates in registers, and writes only the partial composition value
needed by the next stage. Use function constants for a small tuning surface, not
runtime shader source generation for every proof.

### FRI and decommitment

Keep QM31 as four planar M31 buffers. Fold into alternating arena regions.
Commit each layer immediately, absorb its root in the GPU channel, and derive the
next alpha on device. Generate PoW nonces and query positions on device. Sort and
deduplicate query positions with a small GPU radix/bitonic path, then gather leaf
values and authentication siblings directly into proof-output order.

## Command and synchronization policy

- One serial command queue is the correctness baseline.
- Use long command buffers with multiple compute encoders; do not wait between
  protocol stages.
- Use explicit buffer barriers at producer/consumer boundaries after moving a
  region to untracked hazard mode.
- Use indirect dispatch arguments only when the GPU computes the grid size.
- Use `MTLSharedEvent` only for the final CPU notification or cross-queue work;
  Apple notes that shared events cost more than device-local events.
- Precompile pipelines and persist them with `MTLBinaryArchive` so benchmark
  timing excludes shader compilation.
- Instrument stage boundaries with Metal counter sample buffers and report GPU
  time separately from CPU wall time.

## 10x performance budget

The 121 ms target is a stretch target, not a forecast. Gate it with this budget
on the current 2.5M-cycle workload:

| Resident stage | Target |
| --- | ---: |
| Trace expansion and interaction generation | 15 ms |
| Transforms and all trace commitments | 35 ms |
| AIR/composition | 25 ms |
| FRI, commitments, queries, decommitment | 35 ms |
| Submission, synchronization, proof packing | 11 ms |

Every milestone reports bytes read/written and committed trace cells per second.
VM cycles per second alone is not comparable across Fibonacci, RISC-V, and SNOS.
If the GPU counters show bandwidth saturation before the budget is met, reduce
passes and materialized columns before attempting arithmetic micro-optimization.

## SN PIE benchmark track

The local corpus has two tiers:

1. `SN_PIE_1..4`: 7.7M to 14.6M Cairo VM steps, with Pedersen, range-check,
   bitwise, EC-op, and Poseidon builtins.
2. Sepolia target series: 12.5M to 60.1M steps, additionally exercising Keccak,
   range-check96, add-mod, and mul-mod.

The current Zig repository has no Cairo PIE bootloader/adapter and cannot
truthfully prove these files with its RISC-V frontend. The bridge milestone is a
versioned adapted-prover-input format emitted by the existing Rust bootloader and
consumed by Zig. Both implementations then receive identical component rows,
builtin segments, AIR layout, and security parameters. Reimplementing the
bootloader in Zig can follow, while VM/adaptation remains a separately reported
stage.

Benchmark rows must include:

- corpus SHA-256 and PIE execution resources;
- VM/adapt/prove/verify times separately;
- PCS parameters, hash, blowup, query count, and PoW bits;
- physical and implicit columns, committed cells, and cells per Cairo cycle;
- GPU-only stage time, wall time, peak Metal allocated size, and peak process RSS;
- proof size and cross-verification result.

The first local full baseline on `SN_PIE_2.zip` did not produce a proof. Rust
SIMD failed after 52.37 seconds with `0 has no inverse`; it reached 17.34 GB max
RSS and a 48.66 GB peak memory footprint. The counts-only path completed in
3.89 seconds (VM 2.819 seconds, adapt 0.466 seconds) and produced 7,833,306
adapted Cairo cycles. This failure is a required regression case for denominator
validation and arena bounds, not a number to omit.

## Delivery sequence

1. Freeze the `ProofPlan`, AIR program, buffer descriptor, and proof-output ABIs.
2. Add the Objective-C runtime, offline `.metal` build, device capability probe,
   and an arena/barrier validation test.
3. Port field operations, transforms, Blake2s, Merkle construction, and the GPU
   channel; prove a small existing vector with one upload and one readback.
4. Move composition, FRI, query generation, and decommitment into one resident
   transaction and cross-verify every proof with the CPU verifier.
5. Add GPU RISC-V trace expansion and measure the 121 ms budget on the preserved
   2.5M-cycle benchmark.
6. Define the adapted Cairo input artifact, ingest `SN_PIE_2`, and fix the
   zero-inverse baseline before scaling through the 60M suite.
7. Tune heap aliasing, batching, fusion, hazard tracking, and pipeline archives
   using Metal counters. Only then introduce AIR-specific generated kernels.

## References

- Apple, [Metal compute command encoder](https://developer.apple.com/documentation/metal/mtlcomputecommandencoder)
- Apple, [Indirect dispatch arguments](https://developer.apple.com/documentation/metal/specifying-drawing-and-dispatch-arguments-indirectly)
- Apple, [Untracked hazard mode](https://developer.apple.com/documentation/metal/mtlhazardtrackingmode/untracked)
- Apple, [Synchronization events](https://developer.apple.com/documentation/metal/about-synchronization-events)
- Apple, [Binary pipeline archives](https://developer.apple.com/documentation/metal/mtlbinaryarchive)
- Apple, [GPU counter sample buffers](https://developer.apple.com/documentation/metal/gpu-counters-and-counter-sample-buffers)
