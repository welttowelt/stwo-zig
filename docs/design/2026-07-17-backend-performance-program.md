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
with no device dispatch. The historical matrix below used the `functional` protocol, one warmup and
five timed post-warmup samples per lane. It satisfied the report contract active at the time, but
the current contract classifies fewer than ten warmups as correctness-only. `metal_hybrid` still
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

### Reusable prover session

Commits `3fb41ae` through `fc21ca9` implement the first architecture priority: a bounded session
owns one canonical maximum-log host twiddle tower, and every per-proof scheme borrows exact suffix
views for PCS and composition transforms. Session construction is reported separately from proof
time with its maximum log, host byte budget, retained bytes, and exactly-one-build invariant.

The reversed-order ReleaseFast A/B used five warmups and 101 samples. CPU prove-time gains were
7.57, 3.31, and 0.36 percent for `log10x8`, `log12x16`, and `log14x32`; Metal gains were 5.66, 3.98,
and 2.78 percent. The geometric-mean improvements were 3.70 percent for CPU and 4.13 percent for
Metal. No backend-specific kernel changed, so the result is evidence that explicit immutable
ownership improves both lanes rather than one benchmark.

The clean formal matrix recorded one tower in every lane, exact CPU/Metal proof parity, and
headline eligibility for all rows. The pinned Rust Stwo verifier accepted all six emitted
artifacts. Detailed ownership, failure, memory, and A/B evidence is in
`docs/design/2026-07-17-prover-session-twiddles.md`.

### Deterministic parallel proof of work

Longer repeated sampling exposed a pre-existing source of canonical-proof variance: the parallel
Blake2s proof-of-work grinder returned the first worker result, so scheduling selected the nonce and
therefore the later FRI query set. Commit `9c52a9d` makes workers converge on the global minimum
valid nonce and safely completes residue classes whose thread failed to spawn.

The post-fix 101-sample CPU and Metal rows were byte-identical, CPU/Metal proof bytes matched, and
all six clean-matrix artifacts passed the pinned Rust verifier. The semantic change stayed within
the performance gates; its worst observed movement was -1.84 percent on Metal `log14x32`. Exact
proofs now use the canonical digests recorded in
`docs/design/2026-07-17-deterministic-parallel-pow.md`.

### Post-session CPU profile

A clean ReleaseFast `log12x16` diagnostic at `a641082` used 21 profiled samples, emitted one exact
32,853-byte proof digest throughout, and passed the pinned Rust verifier. Median profiled prove time
was 6.332 ms. The ranked leaf stages were:

| Stage | Median (ms) | Share of prove |
| --- | ---: | ---: |
| FRI quotient construction and commitment | 3.577 | 56.49% |
| Main-trace Merkle commitment | 1.039 | 16.41% |
| Sampled-value evaluation | 0.443 | 7.00% |
| Main-trace interpolation | 0.304 | 4.80% |
| Composition commitment | 0.258 | 4.07% |
| Proof of work | 0.223 | 3.52% |
| Extended-domain evaluation | 0.224 | 3.54% |

The complete profiled time is within 0.62 percent of the earlier 101-sample quotient-batching
diagnostic, while main-trace interpolation fell from 0.486 to 0.304 ms after session reuse. The
deterministic PoW increment adds only about 0.018 ms in this diagnostic. Quotient plus the main
Merkle commitment now account for 72.9 percent of proof time, so the next CPU architecture target
is a bounded quotient-to-Merkle tile pipeline, not further proof-of-work or twiddle tuning.

### CPU quotient-to-leaf fusion

Commit `7301925` removes the post-compute full-column leaf-hash pass. Each quotient worker emits
bounded output tiles directly to a disjoint first-layer writer; parent layers begin only after every
worker joins. The compatibility path and exact per-layer parity tests remain available, and
allocation failures cannot leak an unappended leaf or parent layer.

A reversed-order 101-sample ReleaseFast A/B improved CPU prove time by 8.48 percent on `log10x8`,
8.36 percent on `log12x16`, and 2.56 percent on `log14x32`, for a 6.43 percent geometric-mean gain.
Fused row rates were 0.544729, 0.730087, and 1.091266 MHz. A separate profiled medium A/B reduced
the quotient stage by 10.2 to 19.4 percent across two orderings.

The clean formal matrix retained exact CPU/Metal proof bytes, one session tower per lane, and
headline eligibility. All six artifacts passed pinned Rust Stwo. Complete-column combined
intermediate storage was intentionally retained by this commit and measured separately below.

### CPU bounded quotient inputs

Commit `9a56af9` removes complete-column combined-coordinate construction from the medium and wide
CPU quotient path. Compact borrowed column views and contribution ranges feed 256-row worker-local
SoA numerator planes directly into the accepted quotient-to-leaf pipeline. The shape policy selects
bounded inputs from lifting log 13, retains the compatibility path below that boundary, and never
branches on workload identity.

The exact component fixture reduces retained working state from 172,544 to 18,432 bytes per worker,
an 89.32 percent reduction, while reporting zero complete-column combined bytes and zero
post-compute leaf passes. Against the immutable `653cccd` ReleaseFast baseline, prove time improved
4.58 percent on `log12x16` and 16.16 percent on `log14x32`; the compatibility `log10x8` row moved
1.25 percent slower, inside the 2 percent gate. Candidate row rates were 0.545237, 0.766880, and
1.296758 MHz. A separate medium profile reduced quotient time by 14.43 percent and complete proof
time by 8.32 percent.

Every row retained its exact canonical proof digest. Component tests cover all quotient
coordinates, every Merkle layer/root, deterministic repeated workers, forced compatibility, bounds,
overflow, and allocation cleanup. The medium artifact passed the pinned Rust Stwo oracle. A
numerator-plane pointer-hoisting experiment was rejected after reversed profiled medians regressed;
the next CPU increment starts from a fresh post-change profile.

Commit `684b5dd` then applies the existing four-lane seeded Blake2s leaf primitive to quotient
first-layer writers after a fresh profile placed 93 of 120 captured quotient-stack samples in their
scalar rounds. It preserves generic-hasher fallback, scalar tails, canonical byte packing, and the
existing disjoint writer ownership with no allocation. Profiled quotient time improved 3.64 percent.
Unprofiled `log10x8`, `log12x16`, and `log14x32` prove time improved 3.07, 2.74, and 1.01 percent,
for a 2.28 percent geometric-mean gain and row rates of 0.570328, 0.784875, and 1.317232 MHz. Proof
bytes remained exact and the medium artifact passed the pinned Rust oracle.

### Metal command-epoch core

Commit `b7c2c0f` establishes caller-owned Metal submission across prepared IFFT, LDE, and resident
Merkle operations. A bounded hardware test encodes the complete three-stage commitment into one
command buffer, submits once, waits once, and matches CPU coefficients, extended evaluations, and
Merkle root exactly. The old synchronous operations call the extracted encoders, so there is one
kernel implementation rather than a second resident-only path.

This is structural acceptance, not a full-proof performance claim. The normal Native matrix remains
below the measured resident-Merkle policy threshold, and the production SN streaming graph uses a
different compact-leaf sequence. That graph is the next adoption target; its acceptance requires a
real command-profile reduction plus the unchanged full formal and Rust-oracle gates.

Commit `c0fbb7f` completes that production-graph adoption for the default compact commitment path.
A bounded real-hardware reproduction collapses composition LDE, compact leaf accumulation, one
arena snapshot, and the Merkle parent chain from six command buffers and waits to one, with zero
intermediate waits. All 32 mixed-log extended columns and the final CPU lifted root match exactly;
encoded plans remain alive through completion after their Zig wrappers are released.

The 83.3 percent command/wait reduction is not reported as proof throughput because the Native lane
does not execute this Cairo streaming callsite and no heavy PIE was run. A bounded virtual-SNOS or
equivalent compact-streaming proof is the next timing gate.

Commit `cc176f5` adds a bounded timing surface around that exact production callsite. A two-group,
32-column, 30,208-byte fixture verifies the CPU lifted root and transcript after every request and
truthfully reports `proof_generated = false`. With two warmups and 11 same-process requests, the
detached `653cccd` graph measured 2.490 ms median request latency and 0.398 ms median GPU duration;
the `c0fbb7f` epoch measured 0.507 and 0.305 ms respectively. That is a 4.92x request-latency and
1.30x GPU-duration improvement with exact roots throughout.

A separate alternating-process experiment was rejected for request latency because each one-sample
process was cold. Cold backend initialization, fixture construction, warm requests, GPU duration,
and eventual full-proof throughput remain distinct evidence classes. The sustained callsite result
validates the command-epoch architecture; it is not a proof-MHz claim.

The first post-epoch encoder profile places seven dependent Merkle parent dispatches at 0.1709 ms,
about 43 percent of measured encoder GPU time. Each level costs roughly 0.023-0.028 ms even as its
grid shrinks from 64 hashes to one. Reusing one compute encoder with buffer barriers was rejected:
it reduced encoder count but regressed profiled parent time from 0.171 to 0.178 ms and command GPU
time from 0.412 to 0.424 ms. Its unprofiled movement was within noise.

The next Metal experiment is therefore a general multi-level Blake2s parent-tail shader that keeps
required retained layers while replacing several dependent small-level dispatches with one bounded
threadgroup reduction. It is accepted only if exact layer/root parity, capacity bounds, fallback,
and targeted GPU counters pass; encoder-count reduction alone is insufficient.

Commit `0b2eb10` accepts that shader. An eligible power-of-two upper chain is reduced in one
threadgroup with at most 256 threads and 8 KiB dynamic memory, while every retained layer is written
to its original arena range. Larger chains preserve a per-level prefix and arbitrary layouts retain
the full fallback. Alternating 22-sample-per-lane A/B reduced request median from 0.571 to 0.524 ms,
GPU median from 0.351 to 0.292 ms, and compute dispatches from 23 to 17. The candidate GPU range did
not overlap baseline. Counter evidence reduced the targeted parent stage from 0.201 to 0.120 ms.
All intermediate layers, CPU root, transcript, plan lifetime, and arena-bound gates passed.

### Native mixed-AIR transaction

Commit `ec288e7` moves XOR onto the shared prepared-input, engine, and reusable-session proving
transaction without changing its transcript or verifier. The compatibility path, a prepared CPU
engine proof, and two sequential session proofs emit the same 7,796-byte canonical proof with
SHA-256 `0b5ca7fb7ceeb110f996dec508b939ac5eb4239526a5f244de21a25e93180504`.
The pinned Rust Stwo oracle accepted that exact Zig artifact.

This is correctness and architecture evidence, not a throughput result. It establishes a narrow,
nonempty-preprocessed-tree workload for the common CPU/Metal suite. Report version 3 and tagged
Wide Fibonacci/XOR execution must land before cross-workload performance comparisons are published.

### Tagged Native report-v3 baseline

Commit `47bc615` lands report schema 3, aggregate matrix protocol 3, exact tagged Wide Fibonacci/XOR
geometry, and mandatory formal verification by the pinned Rust binary SHA-256
`cbe4d3f107b261285381cd590dbf4b2f86e52eed337843081bd142969f1c4dac`. The controller independently
recomputes sampling, headline requirements, request-phase enclosure, rates, pipeline warmth,
artifact binding, and cross-backend proof equality rather than trusting report declarations.

A clean detached ReleaseFast run at `0b2eb10` used one warmup and five functional samples per lane.
Both rows were headline-eligible and Rust-accepted. Wide `log10x8` measured CPU/Metal prove medians
of 3.483625/6.083750 ms and native rates of 0.293947/0.168317 MHz. XOR log10 measured
4.142583/8.024709 ms and 0.247189/0.127606 MHz. Metal therefore delivered 0.573x and 0.516x CPU prove
throughput on these bounded complete proofs. Exact proof digests were `1beb388c...9f6f0c` and
`574b4d69...20831f`. This is the formal baseline for complete-transaction profiling; compact
commitment-stage speedups are not extrapolated over it.

### Sustained Native Wide/XOR/Plonk baseline

Commits `1280ed3`, `77ec02a`, and `541d1cc` migrate Plonk to the common transaction, add it to the
closed report-v3 registry, require ten headline warmups, and bind artifacts to the exact statement
returned by the prover. A clean detached ReleaseFast run at `541d1cc` used ten warmups and five
functional samples per lane. All rows were headline-eligible, byte-identical across CPU and Metal,
and accepted by the pinned Rust oracle.

| Workload | CPU prove (ms) | CPU native MHz | CPU request (ms) | Metal prove (ms) | Metal native MHz | Metal request (ms) | Metal/CPU prove |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wide Fibonacci `log10x8` | 1.935792 | 0.528982 | 2.109166 | 5.737333 | 0.178480 | 5.899958 | 0.337x |
| XOR `log10/step2/off3` | 2.705125 | 0.378541 | 2.886166 | 5.090667 | 0.201152 | 5.237125 | 0.531x |
| Plonk `log10` | 2.797875 | 0.365992 | 3.010958 | 7.549375 | 0.135640 | 7.751042 | 0.371x |

The exact proof sizes and SHA-256 values are 23,569 bytes and `1beb388c...9f6f0c` for Wide,
23,505 bytes and `574b4d69...20831f` for XOR, and 26,642 bytes and `72eff960...4b2f4f` for Plonk.
This is now the authoritative bounded complete-proof baseline. It reinforces the profiler result:
small hybrid Metal proofs are dominated by command waits and host/device boundaries rather than GPU
arithmetic, so optimization must reduce proof-wide synchronization and residency transitions.

### Complete Native profile after report v3

A counter-enabled bounded Metal run retained the same exact Wide Fibonacci and XOR artifacts and
passed the pinned Rust oracle. Wide measured 6.769 ms median prove time, 0.874 ms of actual Metal GPU
execution, and 4.233 ms in command waits per proof; XOR measured 7.682, 1.118, and 4.391 ms. Wide
issued 15 Metal dispatches and XOR 17, but both recorded exactly 13 `cpu_small_merkle_commits`, zero
resident commits, and zero streaming commits. FRI quotient construction and commitment remained the
largest stage at roughly 4.1-4.5 ms for Wide and 3.9-4.1 ms for XOR.

This ranks the complete-proof host commitment boundary above kernel work. Metal GPU execution is
only 13-14 percent of request latency, the Wide LDE is already one command and XOR LDE two, and no
Metal leaf kernel can affect a transaction that never enters resident Merkle. Lowering the existing
small-tree policy threshold without measuring allocation, copy, command, and wait cost is rejected.
The next experiment is an explicit resident-small-tree crossover and then, if direct commits lose,
a producer-to-resident-Merkle transaction that removes host materialization.

The post-`684b5dd` CPU profile instead ranked sampled-value circle evaluation above generic trace
leaf packing: `evalManyAtPointsWithFlatFactors` accounted for 358 selected top-of-stack samples,
versus 97 for `buildLeavesBatchedRange`. Three exact-proof evaluator experiments were rejected and
reverted. Four-polynomial packed QM31 evaluation regressed small/medium/wide proofs by 0.30, 0.59,
and 0.89 percent. A fixed-factor QM31 multiplication matrix regressed the targeted wide sampled-value
stage from 1.719 to 1.740 ms. Scalar pair interleaving left medium/wide proof medians inside MAD and
regressed the same stage from 1.735 to 1.740 ms. The current scalar Karatsuba evaluator remains the
accepted ARM64 implementation; future work must change coefficient/point reuse rather than repeat
cross-polynomial gathers or widened multiplication transforms.

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
