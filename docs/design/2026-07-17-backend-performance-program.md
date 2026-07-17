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

## Current Evidence

### Committed measurement and correctness path

The architectural baseline is bound to commit `402628c`; the latest accepted CPU optimization is
commit `09ed7ef`. The committed controls are:

- `fa2f8e4` added the verified, backend-neutral Native proof benchmark;
- `a14d1c7` added the fail-closed CPU/Metal matrix controller;
- `68637cf` exported the exact proof from each timed lane;
- `0f98bde` bound each report to its oracle artifact;
- `402628c` removed host-bound conversions between Metal FRI folds;
- `09ed7ef` batched CPU quotient denominator inversions in bounded row tiles.

The controller alternates lane order, hashes its binaries and artifacts, requires ReleaseFast,
records setup and request timing separately, verifies every sample in Zig, and rejects a Metal lane
with no device dispatch. The matrix below used the `functional` protocol, one warmup and five timed
post-warmup samples per lane. All three rows were formally headline-eligible. `metal_hybrid` still
reported CPU Merkle fallbacks, so these numbers are not resident-backend claims.

### Formal post-change baseline

All values are medians. Row MHz is trace rows divided by complete `prove_seconds`; request time also
includes prepared-input adaptation, canonical proof encoding, and verification.

| Workload | Committed cells | CPU prove (ms) | CPU row MHz | CPU request (ms) | Metal prove (ms) | Metal row MHz | Metal request (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `log10x8` | 8,192 | 3.987000 | 0.256835 | 4.227917 | 8.778542 | 0.116648 | 8.996958 |
| `log12x16` | 65,536 | 8.722167 | 0.469608 | 9.109458 | 11.865291 | 0.345209 | 12.217875 |
| `log14x32` | 524,288 | 17.025958 | 0.962295 | 18.104208 | 20.535833 | 0.797825 | 21.599333 |

Every timed sample verified and was byte-identical within its lane. CPU and Metal produced the
same canonical proof bytes for every row:

| Workload | Proof bytes | Canonical proof SHA-256 |
| --- | ---: | --- |
| `log10x8` | 20,959 | `5024501a068416f9ee6a06c694128bc06fb47163ac89fb3d23a81228314a3911` |
| `log12x16` | 34,273 | `f30b6b6cb071bf26b43c29b8c49ac523360a204d04f4fca9f8bd7e50bdadb8d4` |
| `log14x32` | 44,290 | `d46859524df8df0b9ef2b36feacf3c48a3496423533b571b9b3afe3b22d12912` |

The pinned Rust Stwo oracle at `a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2` accepted all six
exact artifacts: CPU and Metal for each of the three rows. This establishes Rust acceptance of the
bytes actually timed, rather than acceptance of a separately regenerated proof.

### Measured profiler evidence

The CPU diagnostic used `log12x16`, the functional protocol, and 101 profiled samples. It is not a
headline result. Median prove time was 7.133 ms, or 0.574199 row MHz. Median root-stage time was
5.261 ms in `core_prove` and 1.862 ms in `main_trace_commit`. Within `core_prove`, the largest
measured stages were quotient construction and commitment at 4.015 ms, sampled-value evaluation at
0.437 ms, composition commitment at 0.242 ms, and proof of work at 0.219 ms. Within main-trace
commitment, Merkle commitment cost 1.116 ms, interpolation 0.506 ms, and extended-domain evaluation
0.238 ms.

The non-idle top self stacks from `/usr/bin/sample`, expressed as sample hits rather than elapsed
time, were Blake2s rounds (232), `M31.powPMinus2` (90), circle evaluate-many (72),
`compressParallel4` (69), `CirclePointIndex.toPoint` (42), combined-contribution planning (29), FFT
evaluation (25), IFFT (24), and CPU Merkle commitment (20). Idle `__ulock_wait2` dominated the
all-thread capture and is deliberately excluded from prover-cost ranking.

The bounded Metal command profile before the FRI conversion change recorded 28 command buffers,
10.332 ms of host wait, and 1.567 ms of GPU execution. The identical diagnostic after the change
recorded 17 command buffers, 9.690 ms of host wait, and 1.476 ms of GPU execution. In the latter,
polynomial evaluation consumed 0.849 ms (57.55 percent of GPU time), eleven line folds consumed
0.259 ms (17.56 percent), and circle LDE consumed 0.163 ms (11.05 percent). These are profiled
diagnostics, not headline latency.

The unprofiled, parity-gated A/B showed conservative prove-time gains of 2.43 percent on the small
row and 11.65 percent on the wide row, with exact proof parity. The measured command reduction and
the gap between GPU execution and host wait support the next architectural experiment. They do not
by themselves prove that command count is the only cause, that the same gain will hold for Cairo or
SN PIEs, or that a fully resident design will reach a particular MHz target.

### CPU quotient row batching

The CPU sample profile identified `M31.powPMinus2` as the second-largest non-idle self stack and
placed quotient construction and commitment at 4.015 ms of a 7.133 ms `log12x16` proof. Commit
`09ed7ef` replaces one CM31 denominator inversion per row with one batch inversion per bounded row
tile. The executor uses at most 1,024 rows and 8 MiB of scratch per worker, enables batching from
8,192 domain rows, and retains the scalar path for small, Metal-raw, and over-budget inputs.

The identical 101-sample profiled diagnostic after the change measured the quotient stage at
3.388 ms and the complete proof at 6.293 ms. That is a 15.62 percent targeted-stage reduction and
an 11.78 percent profiled prove-time reduction. These values diagnose the mechanism; they are not
headline MHz.

A separate unprofiled ReleaseFast A/B used two warmups and 21 samples per workload after a shorter
run exposed a roughly ten-sample process warm-up ramp. Proof bytes were identical in every sample.

| Workload | Before prove (ms) | After prove (ms) | After row MHz | Prove-time gain |
| --- | ---: | ---: | ---: | ---: |
| `log10x8` | 2.429250 | 2.389625 | 0.428519 | 1.66% |
| `log12x16` | 6.397041 | 6.350084 | 0.645031 | 0.74% |
| `log14x32` | 16.139708 | 15.704834 | 1.043246 | 2.77% |

The clean formal matrix on `09ed7ef` then alternated CPU and Metal for all three rows. Every row
was headline-eligible, all samples verified, CPU and Metal emitted the canonical digests above, and
the pinned Rust Stwo verifier accepted all six exact timed artifacts. The formal matrix is the
correctness and non-regression gate here; its five-sample Metal timings are not presented as a
Metal improvement because this commit does not change the Metal execution path.

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

The following is the ranked implementation plan derived from the current audits and measurements.
Items described here are hypotheses and planned contracts until their acceptance gates pass.

### 1. Long-lived prover session and canonical twiddles

Introduce `ProverSession(PcsConfig, max_circle_log, host_byte_budget)`. It owns immutable tables,
bounded scratch storage, telemetry, and one canonical max-log twiddle tower whose suffix views serve
smaller domains. `Engine` and `Scheme` gain `initWithSession`; the existing initializer remains a
local compatibility path. Composition and FRI geometry borrow the same tower. Reads are lock-free,
all shape and byte bounds fail closed, callers join outstanding work before deinitialization, and no
proof may retain a view beyond the session lifetime.

The Metal specialization additionally owns the device, queues, compiled libraries, semantic
pipeline cache, and an immutable device twiddle bank in the session instead of the global runtime.
This is the first shared CPU/Metal change because it removes repeated geometry construction while
establishing explicit ownership for streaming requests.

### 2. Give LDE output directly to Merkle commitment

Replace the host-owned LDE result followed by restaging with a typed resident polynomial handle.
Circle transform, LDE, leaf packing, and lifted Merkle levels consume compatible views of the same
allocation. The commitment interface returns the root plus an owned decommitment handle; it does
not force materialization of every column on the host. An arena plan records lifetimes and permits
aliasing only for disjoint ranges. Transcript roots, requested openings, recovery, and explicit
spill are the only host-transfer edges.

This work must reduce measured host transfer and wait time without changing roots, opened values,
decommitments, canonical proof bytes, or CPU fallback behavior that remains intentionally enabled.

### 3. Batch resident FRI at transcript barriers

`fold_step=1` means a generic `foldLineN` wrapper saves no work. Add an optional backend operation,
`commitFriInnerBatch`, with a CPU fallback. After the CPU mixes the first FRI root, upload channel
state once; one Metal command graph draws alpha, folds, planarizes, performs standard lifted Merkle
commitment, and mixes each root across all inner layers. Wait once at the transcript barrier before
the CPU last layer. This is a high-risk semantic batch, not a mechanical kernel fusion.

The current hypothesis is approximately 17 command buffers to 6 by removing eleven interior waits.
Acceptance requires exact parity for every FRI root, retained layer, channel state, last-layer
evaluation, decommitment, injected command failure, full Zig proof, and pinned-Rust verification.

### 4. Bound shape caches and streaming request slots

Cache immutable work by a complete semantic key: protocol parameters, maximum circle log, field and
layout representation, kernel specialization, and device identity. Compile geometry descriptors
once and group columns/components by log size and operation. Use fixed-capacity request slots with
typed resident arenas and backpressure; cache and arena exhaustion are explicit errors, never an
unbounded allocation path. Queue execution may overlap CPU witness work, transfers, and GPU work
only after the single-request ownership model is correct.

Acceptance includes cold and warm accounting, retained-byte reporting, deterministic shuffled
10- and 100-request queues, bounded peak memory, no cache growth after warmup, failure recovery, and
proof delivery in input order. Sustained throughput and tail latency are reported separately from
single-proof MHz.

### 5. Execute the CPU stage program explicitly

Optimize measured stages rather than treating CPU work as one residual bucket. In order: quotient
construction/commitment and sampled-value inversion; FRI geometry and folding; canonical twiddle
reuse; Blake2s/Merkle `compressParallel4`; circle interpolation/evaluation; then FFT/IFFT layout and
sharding. Evaluate batch inversion before more `powPMinus2`, reuse point and contribution plans,
and keep field data in contiguous SoA or measured AoSoA layouts with stable alignment and one
scalar tail. Persistent workers use coarse deterministic shards; no stage creates ad hoc threads.

Each change needs stage-level before/after evidence and the formal cross-backend matrix. Explicit
SIMD is accepted only when disassembly or counters show the intended vector width and the scalar
tail, aliasing, alignment, and overflow contracts are tested.

### 6. Fuse and overlap only after ownership is stable

Later candidates include interpolation plus extension, leaf packing plus early Merkle levels, and
quotient evaluation plus accumulation. A fusion is accepted only when saved dispatches and bytes
outweigh measured occupancy, register, and threadgroup-memory costs. Double buffering or CPU/GPU
overlap additionally requires a command timeline showing real concurrency and a memory budget that
supports the chosen stream depth.

### Next acceptance sequence

1. Land the session and twiddle-tower contract with construction-count telemetry, unchanged proof
   bytes, the formal three-row matrix, and all six pinned-Rust artifact checks.
2. Land LDE-to-Merkle ownership only after root/opening/decommitment parity tests and a profile show
   fewer transferred bytes or less host wait with no matrix regression.
3. Land resident inner FRI only after its layer-by-layer and failure tests pass, the command profile
   approaches the predicted one-wait graph, and every formal proof remains Rust-accepted.
4. Run deterministic 10- and 100-request mixed queues through bounded slots; publish retained and
   peak bytes, median and tail latency, sustained proofs/s, and sustained workload-native MHz.
5. Take CPU quotient/FRI/Merkle/FFT work one measured increment at a time; require stage improvement,
   formal matrix non-regression, exact Metal parity, and Rust acceptance before the next increment.

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
