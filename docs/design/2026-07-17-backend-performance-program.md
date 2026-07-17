# Backend Performance Program

Status: active

## Objective

Drive verified proving throughput upward across the Zig CPU and Metal backends without specializing
the prover for one trace. Native Stwo and Cairo are the primary workloads. RISC-V joins the matrix
only after its AIR and Rust-oracle correctness obligations are complete.

Performance changes are accepted from profiler evidence, not intuition. The pinned Rust Stwo
revision is the final protocol correctness oracle. A fast proof that is not accepted by the Zig
verifier and the applicable Rust oracle is not a benchmark result.

## Backend Names

Use these names in reports:

- `cpu_native`: the Zig CPU backend, including explicit and compiler-emitted SIMD hot paths;
- `metal_hybrid`: the current Metal backend, with every CPU fallback reported explicitly;
- `metal_resident`: reserved for a path whose measured proving stages remain device-resident;
- `rust_simd_oracle`: pinned Rust Stwo SIMD correctness and comparison lane.

Do not call `cpu_native` a distinct Zig SIMD backend until it has a separate capability type and
execution contract. Do not call a hybrid result resident merely because some kernels use Metal.

## Benchmark Matrix

The checked-in driver will use stable workload identifiers and immutable protocol settings.

| Class | Workloads | Purpose |
| --- | --- | --- |
| Native scale | wide Fibonacci row sweep | FFT, commitment, composition, FRI, and memory scaling |
| Native mixed AIR | XOR, state machine, PLONK | Small and medium constraint shapes and fixed setup cost |
| Native compute | Poseidon, Blake | Arithmetic intensity, lookup pressure, and generated evaluation |
| Cairo intermediate | virtual SNOS and SNIP-36 prover backend | Wide multi-component proving without full block cost |
| Cairo block | SN PIE corpus | Production-width traces, proof parity, and block latency |
| Cairo stream | deterministic shuffled SN PIE queues | Warm service throughput, reuse, memory bounds, and proof delivery |

Every optimization report must include at least one small workload, one wide workload, and one deep
or compute-heavy workload. Changes to a shared prover stage require all affected checked-in matrix
rows. SN PIE runs are escalation tests: small bounded fixtures establish correctness before a large
block consumes machine time.

## Evidence Classes

Each result has exactly one evidence class:

1. `verified_unprofiled`: authoritative latency and throughput;
2. `profiled_diagnostic`: profiler enabled, never used as the headline MHz;
3. `compile_only`: kernel, pipeline, or target compilation evidence without execution;
4. `correctness_only`: parity or oracle evidence without a performance claim.

Reports must record the Git commit, dirty state, Zig version, optimization mode, host identity,
protocol configuration, backend name, workload digest, warmup count, sample count, and environment
overrides. Missing provenance invalidates comparisons.

## Timing Contract

The harness reports non-overlapping scopes:

- `input_seconds`: PIE parsing, execution, trace construction, or input adaptation;
- `backend_init_seconds`: device discovery, library loading, pipeline creation, and immutable setup;
- `prove_seconds`: the complete proof transaction after its portable input exists;
- `verify_seconds`: verification of the emitted proof;
- `proof_encode_seconds`: canonical proof serialization when requested;
- `request_seconds`: input through delivered proof for one warm service request;
- `process_seconds`: fresh process launch through verified result;
- `queue_seconds`: first queued request start through final verified proof delivery.

Setup is not hidden. Cold and warm results are separate. Pipeline and immutable-data reuse may
reduce warm request latency, but a report must expose what was reused and the retained byte count.

## Throughput Contract

No single MHz definition is meaningful across every AIR. Reports therefore include:

- workload-native MHz: trace rows, Cairo VM cycles, or another named native unit per second;
- committed cell throughput in Mcell/s;
- constraint evaluations per second when the count is available;
- proof transactions per second for streams;
- total proof and peak resident bytes.

The unit and numerator must appear beside every rate. Cross-workload summaries use time ratios and
geometric means, never an average of unrelated MHz numerators.

## Correctness Gates

Every timed sample must:

1. complete without a Metal command error or CPU worker failure;
2. pass the standard Zig verifier;
3. produce a canonical proof encoding;
4. match `cpu_native` canonical bytes when deterministic backend equivalence is promised;
5. pass the pinned Rust Stwo verifier for oracle-bound fixtures;
6. leave no silently selected fallback that is absent from telemetry.

When exact proof bytes legitimately differ, the design note must name the nondeterministic field,
prove transcript equivalence, and retain cross-verification. Backend arithmetic parity is checked at
component and cumulative-accumulator boundaries before full-proof benchmarking.

## Required Telemetry

The backend-neutral report owns logical work:

- trace rows, columns, committed cells, constraints, queries, and proof bytes;
- stage tree from input generation through proof delivery;
- allocation count, allocated bytes, peak live bytes, and reusable bytes;
- CPU worker count and configured SIMD lane width.

Metal adds physical execution facts:

- runtime, library, and pipeline cache cold/hit counts;
- command buffers, compute encoders, blit encoders, and dispatches;
- CPU encode, commit, and wait duration;
- GPU start-to-end duration and per-kernel duration when counters are enabled;
- requested transfer/fill bytes and bound-buffer capacity;
- host and device Merkle commitments;
- Metal transforms, quotient evaluations, sampled-value evaluations, and FRI folds;
- CPU fallback operation counts, names, and logical work;
- current and peak resident buffer bytes.

The harness fails closed when a lane labeled Metal records no Metal work, when profiler events are
dropped, or when telemetry and the requested backend disagree.

## Profiling Loop

### CPU

1. Run verified unprofiled samples and record the stable median and dispersion.
2. Capture time samples with `xctrace` or the available system sampler.
3. Attribute inclusive and self time to a named prover stage and workload class.
4. Measure hardware counters where available: cycles, instructions, cache misses, branch misses,
   and memory bandwidth.
5. Change layout, algorithm, batching, or explicit SIMD only after identifying the limiting
   resource.
6. Re-run correctness, the affected matrix, and the unprofiled baseline.

### Metal

1. Run verified unprofiled samples with command profiling disabled.
2. Capture the public Metal command timeline without encoder counters.
3. Rank GPU duration, CPU wait duration, command count, transfers, and fallbacks.
4. Enable encoder counters only for a bounded reproduction of the leading operation.
5. Use Metal System Trace or GPU capture for occupancy, register pressure, cache behavior, and
   bandwidth when full Xcode tooling is available.
6. Change the command graph, residency, layout, or kernel boundary.
7. Re-run the identical verified unprofiled matrix; profiler speed is diagnostic only.

Large SN PIE profile runs are not the first iteration loop. Reproduce the hot stage with the
smallest geometry that preserves its column width, transform depth, and dispatch shape.

## Architecture Priorities

Optimization proceeds in this order unless evidence changes the ranking.

### 1. Persistent proving context

One context owns the device, queues, compiled libraries, semantic pipeline cache, twiddles,
immutable tables, bounded scratch pools, and telemetry. A proof request supplies typed input and
receives an owned proof; it does not reconstruct runtime infrastructure. Cache keys contain every
code-generation and geometry fact that can change executable behavior.

### 2. Transaction command graph

Encode dependent stages into a small number of command buffers. Replace interior
`waitUntilCompleted` calls with command-buffer ordering, fences, shared events, and completion
handlers. Host reads occur only at transcript or proof boundaries that actually require them.
Command count and CPU blocked time are regression metrics.

### 3. Device residency and lifetime planning

Trace, transformed columns, composition, quotient, FRI layers, and decommit work remain in typed
resident allocations across stages. The arena planner derives lifetimes and aliases only disjoint
ranges. Transfers are explicit edges with measured bytes. Recovery, spill, and recomputation are
capabilities, not frontend policy.

### 4. Geometry batching

Group columns and components by log size, field representation, and operation. One batch performs
many transforms, hashes, or folds. The schedule is built once into typed descriptors; proving does
not repeatedly scan JSON, resolve strings, or rebuild bindings.

### 5. Semantic fusion

Fuse producer and consumer kernels when an intermediate would otherwise be written to and read
from device memory and when the combined kernel retains acceptable occupancy. Candidate boundaries
include interpolation plus extension, leaf packing plus first Merkle levels, quotient evaluation
plus accumulation, and adjacent FRI folds. Each fusion records saved dispatches and bytes alongside
register and threadgroup-memory costs.

### 6. CPU data-oriented execution

Use contiguous structure-of-arrays or measured AoSoA layouts, stable alignment, bounded arenas,
explicit vector-width kernels, and one scalar tail. State aliasing and padding assumptions in types
or assertions. Batch inversions, transforms, hashing, and accumulation across independent columns.
Parallel work uses persistent pools and coarse deterministic shards; do not create threads per
stage or per column.

### 7. Overlap

After residency and batching are correct, overlap independent CPU witness work, transfers, and GPU
stages with bounded queues. Double buffering is justified only by a timeline showing useful
concurrency and a memory budget showing sustainable stream depth.

## Acceptance Gates

A performance commit includes before/after reports from the same host and configuration. It passes
only when:

- all correctness gates pass;
- the targeted stage improves outside profiler noise;
- affected workload median time does not regress by more than 2 percent;
- no checked-in matrix row regresses by more than 5 percent without a documented tradeoff;
- the affected-class geometric-mean time improves;
- peak memory remains within its explicit budget;
- cold setup, warm prove, and queue throughput remain separately visible;
- source conformance, formatting, unit, deep, API-parity, and Rust interoperability gates pass.

Use at least five post-warmup samples for sub-second workloads and three for longer bounded
workloads. Record median, minimum, maximum, and median absolute deviation. Alternate backend order
and cool the host between large lanes. Stop a run when thermal pressure or memory pressure makes
samples non-comparable.

## Delivery Sequence

1. Land a neutral prover-engine contract and make Native wide Fibonacci select `cpu_native` or
   `metal_hybrid` without changing its AIR.
2. Land canonical proof parity, verifier, telemetry, and profiler fail-closed tests.
3. Land a machine-readable full-proof benchmark driver with cold, warm, and queue modes.
4. Establish bounded Native baselines, then make the remaining Native examples engine-generic.
5. Add Cairo intermediate workloads and only then the SN PIE corpus/queue escalation.
6. Capture CPU and Metal profiles, rank shared stage costs, and publish the first optimization
   hypothesis with a roofline or latency-waterfall budget.
7. Implement one architectural change at a time and gate it against the full affected matrix.
8. Add RISC-V only after its AIR and oracle path are complete.

This sequence makes the benchmark suite part of the backend contract. It prevents a fast isolated
kernel, a prepared-input diagnostic, or one favorable block from being reported as general proving
performance.
