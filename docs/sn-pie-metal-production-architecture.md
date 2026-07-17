# SN PIE Metal Production Prover Architecture

Status: normative implementation plan and current-state ledger, 2026-07-16

This document is the authoritative architecture and delivery plan for the
Stwo Zig/Metal Cairo prover. It consolidates the verified SN PIE results, the
current implementation audit, the earlier resident-prover and streaming
designs, the Metal profiling findings, and the work required to turn the
current parity harness into a production block-proving service.

Where this document conflicts with the following documents, this document
takes precedence for Cairo SN PIE Metal work:

- `docs/metal-resident-prover-design.md` is the original architectural intent.
- `docs/sn-pie-streaming.md` contains detailed session and self-contained-proof
  extraction notes that remain valid unless superseded here.
- `docs/sn-pie-persistent-session.md` documents the current JSONL MVP.
- `docs/metal-profiling.md` documents the current profiling tools.
- `docs/gpu-backend-design.md` describes a different CUDA/RISC-V workload and
  is not a memory or protocol design for Cairo SN PIEs.
- `docs/history/metal-handover-2026-07-15.md` is the chronological evidence and implementation
  ledger, not the target architecture.

The existence of this plan does not imply that the current implementation is
already self-contained, production-ready, or capable of the target throughput.
Each claim is gated explicitly below.

This document uses three implementation states:

- `active`: exercised by the current end-to-end proof path.
- `available`: implemented and tested in isolation, but not yet wired into the
  end-to-end path or production acceptance gate.
- `planned`: required by this architecture and not yet implemented.

An item is not called complete merely because an API, test double, or diagnostic
path exists. Milestone exit gates, not source presence, determine completion.

## Contents

1. [Executive Decision](#1-executive-decision)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [Terminology and Measurement Contract](#3-terminology-and-measurement-contract)
4. [Verified Baseline and Evidence](#4-verified-baseline-and-evidence)
5. [Current Implementation Audit](#5-current-implementation-audit)
6. [Protocol Dependency Graph](#6-protocol-dependency-graph)
7. [Target Service Architecture](#7-target-service-architecture)
8. [Self-Contained Ingress and Statement Derivation](#8-self-contained-ingress-and-statement-derivation)
9. [Resource and Buffer Architecture](#9-resource-and-buffer-architecture)
10. [Compiled Proof Command Graph](#10-compiled-proof-command-graph)
11. [Transform Engine Architecture](#11-transform-engine-architecture)
12. [Phase Dataflow](#12-phase-dataflow)
13. [Evaluation Retention Planner](#13-evaluation-retention-planner)
14. [Streaming Queue Architecture](#14-streaming-queue-architecture)
15. [Debug and Parity Architecture](#15-debug-and-parity-architecture)
16. [Profiling and Observability](#16-profiling-and-observability)
17. [Performance Budget](#17-performance-budget)
18. [Delivery Plan](#18-delivery-plan)
19. [Acceptance Matrix](#19-acceptance-matrix)
20. [Engineering Rules](#20-engineering-rules)
21. [Immediate Implementation Backlog](#21-immediate-implementation-backlog)
22. [References](#22-references)

## 1. Executive Decision

The production system will be a prover-owned, persistent Metal service with
this external contract:

```text
raw Starknet PIE -> execute and adapt -> derive statement -> Metal prove
                  -> cryptographically verify -> publish compact proof
```

It will not be a collection of CPU prover methods that occasionally invoke a
GPU kernel. It will not accept Rust proof internals as production inputs. It
will not recreate a multi-gigabyte arena, parse semantic artifacts, compile
pipelines, or restore immutable preprocessed state for each block.

The core performance architecture is:

1. A content-addressed, compiled proof graph for each compatible geometry.
2. Separate resource classes for immutable data, durable coefficients,
   lifetime-aliased scratch, and shared input/output control.
3. Producer-consumer transform pipelines that avoid full-domain intermediate
   materialization where protocol ordering permits it.
4. Dependency-minimal composition evaluation rather than a component-wide LDE
   tile.
5. Retained or query-pruned openings rather than regenerating every full LDE.
6. One serial GPU proof workspace, with CPU adaptation and proof verification
   overlapped around it for sustained block throughput.

Local shader fusion remains useful, but it is subordinate to these ownership,
dataflow, materialization, and synchronization changes.

### 1.1 Architecture decision record

The profiler results do not support an architecture based on successively
fusing isolated kernels inside the current one-shot process. That approach can
remove encoder overhead and redundant intermediate writes, but it leaves the
dominant structural costs intact: per-request resource construction, a
33-41 GiB monolithic Shared arena, full-domain transform materialization,
component-wide composition scratch, full trace-LDE regeneration for roughly 70
queries, and synchronous phase boundaries. It also does not create the reset,
admission, failure-isolation, or ordered-publication semantics needed by a block
prover.

The required end state is therefore a service architecture, not a larger fused
shader:

1. `BlockExecutor` owns raw PIE execution/adaptation and emits an authenticated
   `ProverInput` plus statement.
2. `ArtifactCache` resolves content-addressed AIR, shader, protocol, and
   immutable-preprocessed artifacts without target-proof input.
3. `PreparedGeometry` compiles liveness, resources, dependencies, and command
   encoding once per compatible geometry.
4. `MetalProverService` owns one Runtime and one exclusively leased, resettable
   proof resource set across a queue.
5. `CommandGraph` encodes producer-consumer transforms, commitments,
   composition, FRI, and openings asynchronously with explicit hazards.
6. `ResourcePool` separates immutable device state, durable coefficients,
   lifetime-aliased Private scratch, and small Shared ingress/egress buffers.
7. `VerificationLane` verifies the independent statement and compact proof in
   Zig, and in the pinned canonical Rust verifier used by the SIMD prover when
   the acceptance policy requires it, before ordered atomic publication. The
   Rust verifier itself is not claimed to use SIMD acceleration.
8. `QueueCoordinator` overlaps CPU adaptation of block `n+1`, the single GPU
   proof of block `n`, and CPU verification/publication of block `n-1` without
   allocating a second wide proof workspace.

Kernel fusion is admitted only inside this ownership model and only when it
improves verified full-proof wall time without breaking accumulator, root,
opening, memory, or queue-reset gates. Sections 7-14 define the concrete types,
lifetimes, graph nodes, resource classes, and streaming state machine.

### 1.2 Current checkpoint and critical path

As of 2026-07-16, direct Metal proof generation and resident verification work
for all four prepared SN PIEs. Reference-free protocol execution, meaning no
transcript or quotient reference and fresh local PoW, is verified for SN2 and
SN3. The latest measured repeated-SN2 run passed through the strict protocol-v3 JSONL
control plane with a complete canonical protocol object, canonical manifest,
exact eleven-object map, stable executable identity, content-addressed object
reuse, private artifact-view reuse, and exact-key resident-arena and immutable
preprocessed-state reuse. The canonical full-proof physical arena plan is also
retained on an exact prepared-state and logical-layout hit, and the base AOT
witness recipe now remains with that resident state. The current warm SN2
request therefore avoids the measured 4.7-second CPU placement rebuild. Fixed
tables, multiplicity feeds, and both base and interaction AOT witness recipes
also remain with the resident state. The latest verified warm request finishes
its session block in 15.104474959 seconds, or 0.528147918 MHz derived block
service throughput, while its prove-only interval is 14.658944417 seconds or
0.544199962 MHz. The current repeated-SN2 run is
`verified_diagnostic`, not incomplete evidence. It remains production-false
because its adapted input, schedule, composition bundle, and other semantic
artifacts have proof-derived or unattested source chains and the queue consumes
a preadapted input. Protocol and manifest completeness are no longer the
blocking reason.

That throughput evidence predates the current protocol-v4 canonical Rust gate.
Protocol v4 is implemented and offline-tested, but no live v4 Metal proof or
v4 queue throughput number has been recorded.

Host plan ownership is split into a transactional capacity-four cache
independent of the capacity-one resident Metal state. The first integration of
that split invalidated the cold request's shallow plan view by nulling its owner
at cache transfer; the request failed closed with `MissingBinding` and emitted
no proof or MHz. The explicit ownership-transfer token is restored: the cache
owns deinitialization after transfer while the active request retains a
read-only view. Focused A/B/A, LRU, poison, exact-key, noncanonical, and
post-transfer binding tests pass, both ReleaseFast service targets build, and a
controlled cold/warm live-Metal pair now verifies exact proof parity. The cache
still retains only the compact physical `arena.Plan`, not the complete
parsed/bound/recipe-owned `PreparedGeometry` required below.

The shortest correctness path is now:

```text
bounded live protocol-v4 SN2 with mandatory canonical Rust verification
  -> reference-free SN1 and SN4 through the same gate
  -> canonical Rust verification of the full SN1-SN4 corpus
  -> raw PIE-derived schedule/composition/statement source chain
  -> session-owned PreparedGeometry, arena, immutable state, and recipe graph
  -> randomized 10-block reset/cache gate
```

The shortest performance path in parallel is:

```text
stable graph profiling
  -> remove the remaining measured 0.401-second warm pre-prove interval by
     caching proof/liveness metadata, bindings, and remaining prepared recipes
  -> extend the compiled command graph beyond the current composition epoch
  -> multi-buffer resource ownership and packed coefficient banks
  -> radix-4 composition A/B and bounded multi-part AIR fusion
  -> dependency-simulated bounded composition/commitment materialization
  -> retained-or-pruned openings
  -> 100-block sustained tuning
```

The measured 0.5-0.7 MHz range is a working correctness baseline. Five MHz is
an aggressive research target, not a current forecast: Section 17 derives the
2.866-second SN4 wall budget and shows why command reduction, dataflow, scratch,
and opening architecture must all change before local arithmetic tuning could
make that target credible.

## 2. Goals and Non-Goals

### 2.1 Goals

- Accept a raw SN PIE at the service boundary and own execution, adaptation,
  proving, verification, and proof publication.
- Produce proofs accepted by the resident Zig verifier and the canonical Rust
  verifier used by the SIMD prover for the same statement and protocol
  parameters.
- Prove all four local SN PIEs without transcript, quotient, proof, or nonce
  fixtures in production mode.
- Keep debug parity available at component, tree, transcript, quotient, FRI,
  opening, and assembled-proof boundaries.
- Reuse the Metal device, queues, libraries, PSOs, prepared geometry, immutable
  preprocessed state, and proof workspace across a mixed block queue.
- Report verified prove-only MHz, cold end-to-end latency, persistent service
  MHz, and sustained queue MHz as separate metrics.
- Reduce full-domain memory traffic and synchronous command boundaries before
  relying on instruction-level shader tuning.
- Establish a measured path toward 1 MHz, then use non-double-counted waterfall
  and roofline evidence to determine whether 1.3, 2, or 5 MHz is feasible on one
  M5 Max.

### 2.2 Non-goals

- SNIP-36 is not part of the direct SN PIE proving path. It remains a separate
  workload and future benchmark using the same service architecture.
- Fibonacci or the 2.5 million-cycle RISC-V fixture is not a substitute for an
  SN PIE performance result.
- Poseidon is not a silent optimization for the current Blake2s proof protocol.
- A second 35-41 GB proof arena is not used to overlap two GPU proofs.
- Indirect command buffers, multiple queues, untracked hazards, Private storage,
  or placement heaps are not assumed faster without an A/B measurement.
- Byte-identical production proofs are not required when valid PoW nonces are
  self-generated. Semantic and cryptographic verification is required.

## 3. Terminology and Measurement Contract

### 3.1 Terms

- `PIE`: the raw Starknet Program Input and Execution artifact.
- `ProverInput`: the versioned adapted Cairo input consumed by the Zig prover.
- `statement`: all public data, claims, component geometry, and PCS parameters
  that the transcript and verifier bind.
- `parity fixture`: a Rust-derived transcript, quotient, nonce, accumulator, or
  proof artifact used only to diagnose semantic differences.
- `geometry`: padded and real row counts, component order, trace layout, PCS
  parameters, and buffer capacities that determine a reusable proof graph.
- `proof transaction`: mutable state for one block from reset through compact
  proof readback.
- `proof session`: process-owned Runtime, caches, immutable state, and reusable
  proof resources spanning many transactions.

### 3.2 Required metrics

The source-of-record proving rate is:

```text
adapted Cairo cycles / recorded-witness-start-to-verified-proof seconds / 1e6
```

Every report must keep these scopes distinct:

| Metric | Start | End |
| --- | --- | --- |
| Execution/adaptation | Raw PIE accepted | Validated `ProverInput` ready |
| Preparation | Artifact/geometry lookup | Prepared transaction ready |
| Prove-only | Recorded witness begins | Compact proof verifies |
| Block service | Request accepted | Verified proof atomically published |
| Sustained queue | Session lifecycle begins | Clean session shutdown after all proofs |

GPU stage time, CPU encode time, command wait time, verifier time, I/O time,
memory footprint, and preparation time are reported separately. A profiled run
is diagnostic and never replaces an unprofiled verified MHz result.

### 3.3 Throughput claim classes

Every MHz number belongs to exactly one evidence class:

- `verified_incomplete_evidence`: the proof, cycles, timing scope, and arithmetic
  verify, but one or more required identity, manifest, or protocol fields are
  absent. The observation can guide implementation but cannot pass a benchmark
  regression, release, or production gate.
- `verified_diagnostic`: every requirement below is complete, but a disclosed
  parity fixture, proof-derived artifact, prepared input, or profiled execution
  prevents production classification.
- `production_self_contained`: every requirement below is complete and no
  forbidden dependency is used.

A `verified_diagnostic` or `production_self_contained` throughput number is
valid only when all of these are true:

- The input, adapted cycle count, proof, runner/backend, and artifact manifest
  are identified by full digest.
- The proof timing scope is exactly declared.
- The proof is non-empty and cryptographically verified.
- The PCS, hash, blowup, query count, PoW bits, and FRI schedule are recorded.
- Every parity fixture and proof-derived artifact consumed is disclosed.
- The run did not silently fall back to CPU or another backend.
- Queue throughput is reported only if every queued proof verifies and the
  session closes cleanly.

A production self-contained throughput claim has all those properties and also
requires:

```text
self_contained=true
parity_fixture_used=false
proof_derived_artifact_used=false
provenance_complete=true
protocol_complete=true
```

Prepared-corpus and diagnostic MHz remain useful for optimization, but they are
never labelled production, self-contained, or raw-PIE throughput. Historical
measurements that predate the complete schema-v3 manifest remain explicitly
`legacy diagnostic`; incomplete current reports use
`verified_incomplete_evidence`. Neither can pass a current regression or release
gate. Profiled MHz is always diagnostic regardless of its provenance class.

## 4. Verified Baseline and Evidence

### 4.1 Historical direct SN PIE results

These are verified Metal proofs. The historical SN1-SN4 baseline used parity
fixtures and pre-generated semantic artifacts as described in Section 5. The
new M1 runs omit both transcript and quotient references; they remain
production-false because their adapted inputs, schedules, and semantic
artifacts do not yet have authenticated raw-PIE derivation chains.

| PIE | Adapted cycles | Prove wall | Prove-only MHz | Evidence status |
| --- | ---: | ---: | ---: | --- |
| SN1 | 14,915,645 | 27.948063 s | 0.533692 | Legacy diagnostic, first verified run |
| SN2 | 7,977,397 | 13.783483 s | 0.578765 | Legacy diagnostic, three-run median |
| SN3 | 14,345,552 | 19.239948 s | 0.745613 | Legacy diagnostic, verified run |
| SN4 | 14,328,780 | 19.518779 s | 0.734102 | Legacy diagnostic, second warm request |

The following controlled reference-free proofs are historical pre-v3 evidence;
their missing protocol/manifest fields describe those run artifacts, not the
current session implementation:

| Path | PIE | Adapted cycles | Prove wall | Prove-only MHz | Parity fixtures | Evidence status |
| --- | --- | ---: | ---: | ---: | --- | --- |
| One-shot | SN2 | 7,977,397 | 14.437598 s | 0.552543 | None | Historical incomplete evidence: proof-derived artifacts; canonical protocol object absent |
| Persistent JSONL, first request | SN2 | 7,977,397 | 14.813359 s | 0.538527 | None | Historical incomplete evidence: manifest digest and canonical protocol object absent |
| One-shot | SN3 | 14,345,552 | 21.440811 s | 0.669077 | None | Historical incomplete evidence: proof-derived artifacts; canonical protocol object absent |

The one-shot SN2 proof self-serialized the statement, ground fresh interaction
and query PoW, executed quotient and FRI without reference-parity gates, completed
decommitment, assembled an 8,410,304-byte proof, and passed resident
cryptographic verification. Its query nonce was `193196956`; its proof SHA-256
was `6252f4bbe5a3d81cfc5bd6afc85a72b0d4990d52b8c00b11f9ef3854710f6981`.
The benchmark correctly reported:

```text
self_contained=false
parity_fixture_used=false
proof_derived_artifact_used=true
```

This is M1 protocol-execution evidence, not M2 self-containment evidence. It
must not be merged with the three-run SN2 median because the nonce source and
benchmark population differ. The machine remained within the one-proof safety
policy: 6.188 GB maximum RSS, 30.602 GB peak footprint, zero swaps, and no
concurrent wide proof.

The reference-free SN3 proof self-derived its statement, ground interaction
nonce `3372382` and query nonce `167227385`, and verified an 8,410,288-byte
proof with SHA-256
`7ca4d5225a443da80b15f0c26c7849d84e79155fc2b6567fd1936e80177e16c1`.
Its schema-v3 artifact manifest digest is
`03a9434b2f7a84eddc6c273d57f4abb068ee6bfa63a1816fce66a8d8c6af16ea`.
The 30.693 GiB logical plan reached 37.186 GB peak footprint and 6.838 GB
maximum RSS without a concurrent proof or new swap activity. Evidence is in
`/private/tmp/sn3-m1-reference-free-20260716.{json,proof,stderr}`.

The persistent SN2 request is the first reference-free proof to traverse the
queue client, JSONL request/result protocol, in-process daemon, exclusive
temporary publication, independent client digest validation, and clean session
shutdown. It produced an 8,410,304-byte proof with SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`.
The committed queue-report and block-report SHA-256 values are respectively
`555ade9aaaae433ff04c8b6b17d1f2da4d64e0d2503c5cd7627dc90e3fd56931`
and `f98918ead6268609cff3d74f1fae79001314c80e19045647f08807bbb104a3fa`.
The daemon transaction rate was 0.369495 MHz over 21.590001 seconds; its timer
starts inside `proveRequest`, after frame parsing and initial validation, so it
is narrower than the Section 3.2 block-service scope. Its overhead over
prove-only was 6.776642 seconds. The queue-observed block latency was 22.176329
seconds, or 0.359726 MHz, with 7.362970 seconds outside prove-only. The full
cold one-block session was 22.305313 seconds, or 0.357646 MHz, with 7.491954
seconds outside prove-only. These are cold control-plane observations, not
sustained warm results. Runtime reuse was true; resident-arena and
preprocessed-state reuse remained false. The request recorded 337
binary-archive hits, zero binary-archive misses, zero direct compiles, and
71.048 ms pipeline preparation. Evidence is in
`/private/tmp/sn2-reference-free-session-20260716/queue-report.json`.

The proof and these arithmetic observations are valid, but that historical
committed persistent report has `artifact_manifest_digest=null`,
`provenance_complete=false`, no embedded artifact manifest, no authenticated
session/backend binary digest, and no canonical protocol object. Under Section
3.3, its 0.538527/0.369495/0.359726/0.357646 MHz values are therefore
`verified_incomplete_evidence`, not current benchmark or release numbers. The
report's older `throughput_evidence_class=verified_diagnostic` label is
superseded by this normative classification and by the queue gate implemented
after the run.

PoW time is now isolated from transcript readback, Metal absorption, and
challenge draws. For persistent SN2, 24-bit interaction grinding took
10.519 ms and 26-bit query grinding took 897.182 ms. For reference-free SN3,
the corresponding times were 14.714 ms and 794.055 ms. Both phases report
`mode=self_ground`, expected bit count, and exactly one invocation. Query PoW
is therefore measurable current wall cost, not a zero-cost assumption; a
persistent CPU worker pool and bounded GPU PoW remain optimization work.
These values are monotonic wall time around threaded `channel.grind`, including
prefix setup, worker-count lookup, thread creation/join, scheduling, and search.
They are not aggregate CPU time, attempt counts, or pure hash throughput.

The current prepared inputs have these SHA-256 identities:

| PIE | Adapted-input SHA-256 | Current evidence location |
| --- | --- | --- |
| SN1 | `f56794faf3bc3a383c355dca8242bfb92c16e093249da4157770b44c4de227d1` | `/tmp/SN_PIE_1.dynamic-querylog.{stdout,stderr,verified.proof}` |
| SN2 | `fe78e1549f66c2c175d075fad5e0c1ea174df29f9331684e654ef9e9c8821704` | `/private/tmp/sn2-v3-view-cache-m4-20260716/queue-report.json` |
| SN3 | `21d61530468b83f7f07892320b7d6bd12256a27c4a157d08fb27d16d52aa81e1` | `/private/tmp/sn3-m1-reference-free-20260716.{json,proof,stderr}` |
| SN4 | `644d2a0da374c55672662498f4f3bd25b71d077ee2837440aee1b583b87042ac` | `/tmp/sn4-persistent-v2-20260716-e/block-0001-sn4.benchmark.json` |

The corresponding historical proof digests are SN1
`b4ccdd5f0f2da082bdcad118084f33e6387decabc8f1283d0d29c80e5743fcde`,
SN3 `71a950db696a949c42b1b1012e391e4f9325c7d1ad615e9fbff3bf65005d6773`,
and warm SN4
`e427e59b0d6460ee37e3bb632ef1ae8c7fd0faa99b4c2fd6d1a6aebc7e49a966`.
The legacy SN1-SN4 reports do not contain the complete runner and transitive
artifact identity required by Section 3.3; that omission is why they remain
legacy diagnostic results. The following schema-v3 manifest and runner digests
identify the one-shot evidence at
`/private/tmp/sn2-m1-reference-free-20260716.json`, not the later persistent
report. That one-shot manifest has digest
`d5cb20311b0af5830e1d9fbdc967686bd95c01cd11502ff8f159d8457c2df10b`;
the measured runner executable has SHA-256
`f7c4faf50ea583eb09afc0b9ba6a14fa82d8f79f7bcde2756a66cc182b5ae300`.

The current protocol is lifted Blake2s Merkle/PCS with channel salt 0,
`log_blowup_factor=1`, 70 queries, 24-bit interaction PoW, 26-bit query PoW,
fold step 3, and final FRI degree log 0. Every new report must serialize these
values rather than relying on this paragraph.

#### Current prepared-state repeated-SN2 service evidence

The current authoritative repeated-geometry measurement is
`/private/tmp/sn2-host-geometry-twiddle-clear-mvp-20260716`. It used seed 3 and indices
`[1,1]` in one cleanly closed persistent session. Both 7,977,397-cycle blocks
verified and produced the same 8,410,304-byte proof with SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`.
The adapted-input SHA-256 was
`fe78e1549f66c2c175d075fad5e0c1ea174df29f9331684e654ef9e9c8821704`,
the canonical manifest digest was
`70157c9dd4d85c7b19534700d8482adc252fe6e2159b9d606dff7ea33eb0b5aa`,
and the in-process daemon/runner SHA-256 was
`ce41201067a0f4d824d358a752f753b715a3a84b2cf56d115bcca18d092b8281`.

| Metric | Cold build/capture | Exact warm hit |
| --- | ---: | ---: |
| Prove wall | 14.922018083 s | 14.658944417 s |
| Prove-only MHz | 0.534605772 | 0.544199962 |
| Session block | 23.438800500 s | 15.104474959 s |
| Derived block service MHz | 0.340350053 | 0.528147918 |
| Host-geometry cache hit | false | true |
| Arena-plan cache hit | false | true |
| Fixed-table recipe cache hit | false | true |
| Multiplicity-feed recipe cache hit | false | true |
| Base AOT recipe cache hit | false | true |
| Interaction AOT recipe cache hit | false | true |
| Three compact-recipe cache hits | all false | all true |
| Arena/preprocessed-state hit | false | true |

The exact warm runner attribution is:

| Runner phase | Exact warm hit |
| --- | ---: |
| Schedule read and hash | 0.000000000 s |
| Schedule JSON parse | 0.000000000 s |
| Bundle validation | 0.044161375 s |
| Statement and proof plan | 0.011188667 s |
| Schedule/liveness analysis | 0.051126917 s |
| Cached plan and request bindings | 0.026940083 s |
| Resident reset/snapshot restore | 0.102509334 s |
| Adapted-input materialization | 0.134389501 s |
| Immutable host restore | 0.000001333 s |
| Broad recipe/prelude interval | 0.030699958 s |
| Observed pre-prove total | 0.401039750 s |
| Post-prove before report | 0.001180375 s |

The exact recipe report prevents the broad recipe/prelude interval from being
mistaken for Metal compilation. Warm pre-prove recipe acquisition and
construction totals 0.029109251 seconds: cached fixed tables, feeds, both AOT
recipes, and all three compact recipes are each below nine microseconds; base
EC preparation takes 0.002341125 seconds; and recorded plus native base
interpolation preparation takes 0.026758083 seconds. Recipe acquisition inside
the recorded proof totals 0.064574168 seconds, led by relation components at
0.030615125 seconds, composition at 0.017527541 seconds, and native interaction
interpolation at 0.013627834 seconds. Actual warm pipeline preparation was only
0.000215530 seconds.

This checkpoint also moves the parsed schedule and five semantic bundles into
a transactional capacity-four host-geometry cache, moves the three compact
recipes into resident ownership, and restores a prepared 128 MiB base inverse
twiddle bank from the immutable-start snapshot. The snapshot grows from
4,371,044,576 to 4,505,262,304 bytes. The previous per-request twiddle path
allocated about 256 MiB of host arrays, generated and batch-inverted the tower,
copied 128 MiB into the arena, and then freed both arrays. The fixed-multiplicity
clear retains its semantic lifetime boundary but now encodes 21 exact blit
fills covering 141.03 MiB instead of launching a rectangular 352,321,536-thread
compute grid with 89.51 percent wasted threads.

The two-block queue took 39.516278583 seconds for 0.403752443 MHz sustained
throughput and 0.413944944 MHz aggregate persistent-session service throughput.
Aggregate prove-only throughput was 0.539360205 MHz. Cold work dominates this
two-block sustained number; the exact warm service rate is the metric improved
by setup reuse. This patch does not change GPU proof dataflow, so
prove-only movement relative to earlier pairs is run variance rather than a
kernel-speed claim.

The queue, cold-report, and warm-report SHA-256 values are respectively
`fd70ac5e25c67b39b88175a5e6f595f6c047279d3e86be735d7182e35109f09d`,
`9f6dc0bfa97bbeeaa72d9ff32d49afd2783aa3c87d3b8765f56153d6fde36a13`,
and
`7c510cd71f954c3fb8e3594fb550c9b57ce1301efc40f875b6b029e393ea1994`.
This remains `production=false`: the queue consumed a preadapted SN2 input and
proof-derived diagnostic artifacts. The raw PIE execution/adaptation cost is
therefore not included in this pair.

#### Pre-base-AOT prepared arena-plan evidence

The immediately preceding repeated-geometry measurement is the prepared
arena-plan cache run at `/private/tmp/sn2-plan-cache-mvp-r3-20260716`. It used
seed 3 and indices `[1,1]` in one cleanly closed persistent session. Both
7,977,397-cycle blocks verified and produced the same 8,410,304-byte proof with
SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`.
The adapted input SHA-256 was
`fe78e1549f66c2c175d075fad5e0c1ea174df29f9331684e654ef9e9c8821704`,
the canonical manifest digest was
`5b76a10bf8ad0985bbd8a573dfc5ed9381dffdcd97eb7a8e2ee45b7c8df04846`,
and the in-process daemon/runner SHA-256 was
`8d98cd0932faa793e05143f168f2646c96d5718ac84d52172455cbeaf63e8680`.

| Metric | Cold build/capture | Exact warm hit |
| --- | ---: | ---: |
| Prove wall | 14.656967834 s | 14.580292125 s |
| Prove-only MHz | 0.544273351 | 0.547135608 |
| Runner call | 21.563051000 s | 15.487498958 s |
| Session block | 23.116491500 s | 15.491882500 s |
| Derived block service MHz | 0.345095492 | 0.514940453 |
| Arena-plan cache hit | false | true |
| Arena/preprocessed-state hit | false | true |

The exact runner attribution is:

| Runner phase | Cold build/capture | Exact warm hit |
| --- | ---: | ---: |
| Schedule read and hash | 0.001750667 s | 0.001896167 s |
| Schedule JSON parse | 0.007888083 s | 0.008397792 s |
| Bundle read and validation | 0.050064833 s | 0.058315625 s |
| Statement and proof plan | 0.012784583 s | 0.011373458 s |
| Schedule/liveness analysis | 0.052472500 s | 0.051720707 s |
| Arena plan and bindings | 4.334022791 s | 0.026395750 s |
| Resident acquire/reset/restore | 0.000963000 s | 0.096129334 s |
| Adapted-input materialization | 0.536763334 s | 0.127518125 s |
| Immutable host restore | 1.382802499 s | 0.000000917 s |
| Prepared-recipe construction | 0.482911916 s | 0.484692417 s |
| Instrumented pre-prove total | 6.862424206 s | 0.866440292 s |
| Observed pre-prove total | 6.862491000 s | 0.866460959 s |
| Unattributed pre-prove | 0.000066794 s | 0.000020667 s |
| Post-prove before report | 0.002197167 s | 0.001713834 s |

The queue wall was 39.305967000 seconds for 0.405912771 MHz sustained
throughput. Aggregate prove-only throughput was 0.545700726 MHz and aggregate
persistent-session service throughput was 0.413246981 MHz. The evidence-file
SHA-256 values are:

| Evidence | SHA-256 |
| --- | --- |
| Queue report | `c06e45417cdd4c95189af190a46ee59cde0581df194c51ec04ad0e1a68f0438c` |
| Cold report | `aeb3d546ba830675f345ed2b47b1f23f460bc35bb85e40985734bafd9b50b161` |
| Warm report | `657677f36bab84b7221aaa362abd73b820a1641150b7f7e5e473f2298667d0ad` |
| Either proof | `5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052` |

The controlled comparison is `/private/tmp/sn2-phase-timing-20260716`, which
used the same seed, indices, 7,977,397-cycle input, and proof bytes before plan
reuse. Its warm request spent 5.735506458 seconds before proving, including
4.678984792 seconds in arena plan and bindings; its queue wall was
45.238798709 seconds, sustained rate 0.352679436 MHz, service rate
0.359041229 MHz, and aggregate prove-only rate 0.533539968 MHz. The plan-cache
run reduced warm pre-prove setup by 4.869045499 seconds or 84.89 percent,
reduced arena planning by 4.652589042 seconds or 99.44 percent, reduced warm
session latency from 20.580395500 to 15.491882500 seconds, and reduced queue
wall by 5.932831709 seconds or 13.11 percent. Sustained and service throughput
rose 15.09 and 15.10 percent respectively. The observed 2.28 percent aggregate
prove-only increase is run variance, not a claimed GPU improvement, because
the cache change removes CPU work outside the prove timer.

The plan contains 17,552 logical buffers and 17,552 bindings/physical slots,
uses 26,083,213,312 arena bytes, and reports physical `plan_hash`
`5032272524900653770`. A separate FNV-1a-64 logical-plan hash binds buffer ID,
size, alignment, placement priority, every live range, and optional spill and
recompute costs before a cached physical plan can be borrowed. The logical hash
is part of internal identity but its numeric value is not yet serialized in the
report; the report independently exposes the physical plan hash and arena
size. A plan-only CPU sample in `/private/tmp/sn2-plan-sample.txt` and
`/private/tmp/sn2-plan-sampled.json` measured 4.97 seconds wall and 4.352
seconds in the arena phase. Of 2,590 sampled main-thread stacks, 2,485 were in `runOne`,
with the dominant stacks in `arena_plan.build`; conflict-range collection and
the repeated unstable sort at `arena_plan.zig:188-216` were hot. The cost was
therefore the CPU lifetime-placement algorithm over 17,552 bindings, not Metal
API binding or shader compilation.

Ownership remains fail-closed. Only canonical, unprojected, all-stage
full-proof execution can admit or hit this plan. On a miss the caller owns the
new `arena.Plan` until `PreparedStateCache.begin` verifies prepared-state key,
logical hash, physical plan hash, and arena size and atomically transfers
ownership. A transfer flag prevents the caller defer from freeing it. On a hit
the request borrows the cache-owned plan and cannot transfer it. Key switch,
eviction, poison, and cache destruction deinitialize the plan exactly once
with the arena and immutable snapshot. The session validates the verified CLI
report and canonical protocol and hashes the complete proof before commit, and
keeps the borrow guard armed through exclusive proof/report publication. Any
error in the later report or publication path poisons and destroys the state.

The failed attempts at `/private/tmp/sn2-plan-cache-mvp-20260716` and
`/private/tmp/sn2-plan-cache-mvp-r2-20260716` are not performance evidence.
They failed before proof with `ColumnTooLarge` and `MissingBinding`,
respectively, emitted no verified proof or MHz, stopped their queues, and
closed their sessions. They demonstrate only that pre-proof cache integration
errors fail closed.

The exact remaining warm pre-prove interval is 0.866460959 seconds:
0.484692417 seconds of recipe creation, 0.127518125 seconds of adapted-input
materialization, 0.096129334 seconds of arena reset/snapshot restore,
0.058315625 seconds of bundle parsing, 0.051720707 seconds of liveness work,
and smaller phases. This is still not a complete `PreparedGeometry`: parsed
semantic bundles, proof/liveness metadata, recipes, and the command graph are
not session-owned. The reports are `verified_diagnostic`,
`self_contained=false`, and `proof_derived_artifact_used=true`; current
proof-derived schedules and semantic artifacts do not satisfy the production
raw-PIE source-chain contract.

#### Pre-plan-cache prepared-state evidence

The preceding prepared-state measurement is
`/private/tmp/sn2-prepared-state-mvp-20260716`. It used seed 3 and indices
`[1,1]` with daemon SHA-256
`22dee57d5d344bafe03f79c2941d59f136217e115d2f525b043b3b5e2d8d29c2`.
Both blocks verified and produced the same 8,410,304-byte proof as the earlier
M4a run, with SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`.
The canonical manifest digest was
`8ec0bc4aba652219025d52bec1068a2df5988568b7a60ccd181393df1e97e4b4`.

| Request | Prove wall | Prove-only MHz | Runner wall | Session block | Resident/preprocessed reuse |
| --- | ---: | ---: | ---: | ---: | --- |
| Admission/capture | 14.818506958 s | 0.538340 | 21.892734875 s | 23.447322334 s | false |
| Warm reuse | 14.649125166 s | 0.544565 | 20.364324333 s | 20.368798167 s | true |

The warm runner-minus-prove interval is 5.715199167 seconds, down
1.234950666 seconds or 17.77 percent from the preceding 6.950149833-second
measurement. Warm session-block latency fell 1.315088208 seconds or 6.06
percent. The two-block queue took 44.580843916 seconds for 0.357885 MHz
sustained throughput; aggregate prove-only throughput was 0.541435 MHz and
aggregate persistent-session service throughput was 0.364131 MHz. Relative to
the immediately preceding controlled pair, sustained throughput rose 3.24
percent and service throughput rose 3.67 percent. Prove-only moved only 0.55
percent, which is within run variance and is expected because the reused setup
is outside the prove timer.

The cache owns the exact 26,083,213,312-byte arena and a compact
4,371,044,576-byte snapshot containing merged physical ranges for
preprocessed coefficients, evaluations, and tree-0 retained Merkle layers. A
warm hit zeroed the arena and restored that snapshot in one Metal blit command
in 79.145750 ms. The admission run captured it in 16.783833 ms. Selective
coefficient admission reconstructed 1,930,207,040 bytes from authenticated
evaluations and loaded/canonicalized 242,195,072 bytes that were not provably
reconstructible. Warm object admission was 0.276 ms and warm pipeline
preparation was 0.240 ms with three library and 345 pipeline hits and no
compile/archive work.

Reuse is transactional. The capacity-one cache key binds all geometry,
semantic-program, immutable-preprocessed, tree-root, budget, executable, and
protocol identities while excluding adapted block input and diagnostic
references. A miss remains pending until the session validates the runner
report, hashes the verified proof, and commits outputs. Any error poisons and
destroys the cached resources. A hit independently recomputes plan hash and
arena size, exclusively borrows the arena, zeros all mutable state, and
restores only the authenticated snapshot. The first result truthfully reports
reuse false; the second reports reuse true. The queue report from this run was
created before the aggregate `reuse_verified` predicate was corrected from
all-blocks to any verified warm hit, so the per-block result/report fields are
the authoritative reuse evidence for this pair.

At this checkpoint this was an M3/M4 prepared-state MVP, not the final
`PreparedGeometry` cache. Schedule and bundle parsing, liveness/arena-plan
construction, proof bindings, recipe objects, input materialization, and
runner-local post-proof work still occurred per block and accounted for the
then-remaining 5.715 seconds outside the prove timer. The current plan-cache
run above supersedes that residual.

#### Pre-cache schema-v3 M4a evidence

The immediately preceding service measurement was the repeated-SN2 queue at
`/private/tmp/sn2-v3-view-cache-m4-20260716`. It used seed 3 and indices
`[1,1]` in one persistent session. Both blocks produced the same independently
verified 8,410,304-byte proof with SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`.
Both reports contain the complete canonical protocol above, a complete
canonical manifest with digest
`5a4af01a57ec708cb1e2528d38c36ced63130a3e66b9f318fba43237e16541b6`,
and exact object identity, byte length, and diagnostic path for all eleven
required artifacts. No parity fixture was present.

| Request | Adapted cycles | Prove wall | Prove-only MHz | Session block wall | Composition GPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| First | 7,977,397 | 15.156568042 s | 0.526333 | 23.740111375 s | 2.412137 s |
| Repeated | 7,977,397 | 14.729267667 s | 0.541602 | 21.683886375 s | 2.392148 s |

The two-block queue wall was 46.023894292 seconds. Aggregate prove-only
throughput was 0.533858 MHz, sustained queue throughput was 0.346663 MHz, and
persistent-session service throughput was 0.351242 MHz. Runtime reuse was
verified. Resident-arena and preprocessed-state reuse remained false. The
queue is `verified_diagnostic`: `protocol_complete`, `provenance_complete`, and
`statement_self_derived` are true, but `self_contained=false` and
`proof_derived_artifact_used=true`. Production acceptance therefore remains
false for the source-chain and preadapted-input reasons described in Section
1.2, not because protocol or manifest data are missing.

Schema-v3 object reuse is service-owned and content-addressed. A request may
submit either an absolute-path admission object or an authenticated
`(object_id, bytes, diagnostic_path)` reference. The client learns a reusable
reference only after it has validated the proof, report, complete manifest, and
reported object map. The artifact store snapshots arbitrary admitted paths and
permits a zero-read hit only for an exact object ID, exact byte length, and its
own store identity. A session-owned `ViewCache` additionally retains private
request-adjacency views keyed by the exact identities of preprocessed
evaluations, retained tree-0 Merkle data, composition bundle, composition
metallib, and program kind. Those views use private `0700`, no-follow
adjacency and are not a caller-controlled alias.

On the repeated request, artifact admission took 0.293 ms, pre-runner work
took 0.141 ms, post-runner report work took 3.422 ms, and pipeline preparation
took 0.268 ms with three library-cache hits and 345 pipeline-cache hits. There
were no archive lookups, direct compiles, populations, or serializations. The
runner call still took 21.679417500 seconds against a 14.729267667-second prove
timer, leaving exactly 6.950149833 seconds inside the runner but outside the
prove scope. The session-block minus prove difference was 6.954618708 seconds.
This localizes the remaining service gap after object/view admission; it does
not identify one setup operation because the runner does not yet expose
subphase timers for this interval.

The same run includes the scoped M4a composition command-graph change:
`CompositionRecipe.execute` calls `Runtime.compositionPrepared`, which encodes
the production composition front and finalization into one command buffer and
wait. Diagnostic readback retains its boundaries. The repeated proof remains
byte-identical, but composition time is essentially unchanged from the prior
2.396720-second result at 2.392148 seconds. This is command-ownership and parity
evidence, not a material GPU-time speedup, and the rest of the proof still has
thousands of wrapper-local helper calls and waits.

For comparison, the preceding object-store-only run at
`/private/tmp/sn2-v3-object-reuse-final-20260716` measured 53.673390 seconds
queue wall, 0.297257 sustained MHz, and 0.303681 service MHz. The view-cache
run removed about 7.65 seconds from that two-block queue observation, but the
first block also varied materially. Treat that delta as service-path evidence,
not an isolated kernel-speed claim, until an interleaved A/B/A run controls
temperature and run order.

The two-request SN4 session achieved:

- `0.721588 MHz` aggregate verified prove-only throughput.
- `0.531560 MHz` persistent-session service throughput.
- Runtime, library, and PSO reuse were true.
- Resident arena and preprocessed device-state reuse were false.
- The second request had 3 generated-library hits, 345 pipeline hits, zero
  misses, zero direct compiles, and 0.269 ms pipeline preparation.

The authoritative SN4 evidence is currently:

```text
/private/tmp/sn4-persistent-v2-20260716-e/queue-report.json
/private/tmp/sn4-persistent-v2-20260716-e/block-0001-sn4.benchmark.json
```

### 4.2 SN4 stage baseline

The second warm SN4 request reports these non-overlapping stage totals:

| Stage | GPU time |
| --- | ---: |
| Composition | 3,580.994 ms |
| Witness graph | 2,639.357 ms |
| Commitment total | 2,332.919 ms |
| Commitment LDE | 2,006.646 ms |
| Commitment leaf absorption | 290.291 ms |
| Commitment parent hashing | 35.983 ms |
| Decommit trace LDE | 2,250.303 ms |
| Interaction witness | 1,446.773 ms |
| Base interpolation | 924.382 ms |
| Interaction interpolation | 650.106 ms |
| Relation evaluation | 446.449 ms |
| Quotient | 130.540 ms |
| Decommit assembly/gather | 60.403 ms |
| Multiplicity feed | 24.847 ms |
| FRI | 18.102 ms |
| Transcript | 13.168 ms |

The non-overlapping GPU total is approximately 14.520 seconds. The difference
between that total and the 19.519-second prove wall is 4.999 seconds.

That difference is called `residual` or `unaccounted`, not `host overhead`.
The current telemetry cannot distinguish CPU fixture work, verifier work, GPU
queue gaps, command scheduling, page faults, residency changes, I/O, and other
uninstrumented work well enough to assign the entire residual to the host.

### 4.3 Current memory facts

SN4 uses one Shared `MTLBuffer` of 35,560,865,792 bytes, or 33.119 GiB. Its
logical peak is 35,548,011,020 bytes. The device `maxBufferLength` is
41,747,087,360 bytes, or 38.880 GiB.

The long-lived coefficient volume is:

| Coefficient class | Bytes | GiB |
| --- | ---: | ---: |
| Preprocessed | 2,172,402,112 | 2.023 |
| Base | 10,929,543,232 | 10.179 |
| Interaction | 7,736,140,032 | 7.205 |
| Composition | 536,870,912 | 0.500 |
| Total | 21,374,956,288 | 19.907 |

Block-varying base, interaction, and composition coefficients alone occupy
17.884 GiB. These coefficients are required by later composition, OODS, and
opening stages unless the prover deliberately chooses recomputation or spill.
They form a real residency floor, independent of arena packaging.

Additional current materializations include:

- An 11,945,377,792-byte, 11.125 GiB `CompositionLdeTile` sized for the widest
  component: 89 source columns at log 25.
- A 1 GiB multi-log composition accumulator slab.
- A 2 GiB `DecommitTraceLdeTile` used to regenerate full-domain evaluations.
- Full base and interaction trace logical volumes that alias coefficients or
  scratch by schedule lifetime but still drive phase footprint and traffic.

### 4.4 Shader compilation evidence

The earlier specialized witness compile was a compiler-expansion defect, not
Metal proving time. Generated witness source created excessive compiler IR from
SSA-style temporaries and aggressively inlined Felt252 deduction helpers;
`MTLCompilerService` remained busy for more than 7.5 minutes. Reusing temporary
registers and marking those helpers `[[clang::noinline]]` restored a usable
cached iteration loop. This mitigation does not make per-request source
compilation a production architecture.

The composition path demonstrates the intended AOT model. For SN2, 271 unique
generated AIR kernels produce a 7.4 MiB metallib in 14.69 seconds: 13.19 seconds
of Metal compilation and 1.50 seconds of linking. Compiling 279 kernels
independently at runtime took 148.89 seconds. Populating the machine-specific
55 MiB binary archive takes 25.92 seconds once; resolving all 279 pipelines then
takes 13.90 ms, or about 80 ms including the process. These are build/prewarm
metrics and remain outside warm proof MHz.

The current protocol makes that program an explicit `composition_program`
object, and stable archive identity is keyed by the metallib content digest and
length. In the current repeated-SN2 run, the cold request resolved 337/337
archive entries with zero direct compiles and 107.448 ms total pipeline
preparation. The repeated request had three library hits, 345 pipeline hits,
zero archive work or direct compilation, and 0.268 ms preparation. A complete
read-only production shader manifest for the remaining generated families is
still open.

### 4.5 Reproduce the current reference-free SN2 gate

Build with the repository's pinned Zig toolchain and Xcode wrapper:

```sh
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-arena-plan -Doptimize=ReleaseFast
```

With the prepared corpus artifacts listed in Section 4.1 present, use fresh
outputs and omit both parity references:

```sh
python3 scripts/sn_pie_metal_benchmark.py \
  --input /private/tmp/SN_PIE_2.generic.stwzcpi \
  --mode full-proof \
  --runner zig-out/bin/metal-arena-plan \
  --schedule /private/tmp/sn2-arena.json \
  --budget-gib 29 --timeout 300 \
  --preprocessed-evaluations \
    /private/tmp/stwo-zig-sn2-preprocessed-evaluations.spill \
  --preprocessed-coefficients \
    /private/tmp/stwo-cairo-canonical-preprocessed.stwzppc \
  --tree0-root-hex \
    a98e22423bf5d235981f0b36d939ae56ef3be2751c58b032b2831e6e24ba0364 \
  --proof-output /private/tmp/sn2-reference-free.proof \
  --stderr-output /private/tmp/sn2-reference-free.stderr \
  --output /private/tmp/sn2-reference-free.json
```

Acceptance requires exit zero, `status=completed`, `proof_verified=true`,
`statement_self_derived=true`, `quotient_executed=true`, `fri_executed=true`,
`fri_final_degree_valid=true`, and `decommit_executed=true`. It also requires
`parity_fixture_used=false`, while the current prepared corpus must still report
`self_contained=false` and `proof_derived_artifact_used=true`. The command is a
single controlled 29 GiB proof. Do not run another wide proof or an encoder-
counter capture concurrently.

### 4.6 Reproduce the reference-free persistent gate

The checked-in example manifest intentionally omits transcript and quotient
reference paths for SN1-SN4. Build both entry points, then send one SN2 request
through the persistent queue:

```sh
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-arena-plan metal-arena-session -Doptimize=ReleaseFast
cargo build --release --locked \
  --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml \
  --bin stwo-cairo-verifier-adapter

rm -rf /private/tmp/sn2-reference-free-session-20260716
STWO_ZIG_METAL_REPLAY_RETAINED_LOOKUPS=1 \
python3 scripts/sn_pie_metal_queue.py \
  --manifest scripts/sn_pie_metal_queue.example.json \
  --length 1 --seed 1 \
  --output-dir /private/tmp/sn2-reference-free-session-20260716
```

Seed 1 selects index 1, SN2. This command is deliberately not `--production`:
the preadapted input and proof-derived semantic artifacts are valid diagnostic
inputs but must fail the production provenance gate. Acceptance for this slice
requires a verified non-empty proof, clean `closed` frame, exact adapted-input
and proof digests, mandatory `rust_verifier.verified=true`, exact verifier
binary/lock/source pins, result/report evidence equality, a protocol digest
bound to `cli_report.proof_layout`, `parity_fixture_used=false`, complete self-ground PoW
telemetry, and `metal_runtime_reused=true`. It also requires
`self_contained=false`, `proof_derived_artifact_used=true`,
`provenance_complete=true`, and `protocol_complete=true`. Production acceptance
still fails because the prepared input and semantic source chains are
proof-derived or unattested. The prior live measurement did not include the v4
Rust service gate; run this as one bounded proof before any 10/100 queue.

The daemon uses an adjacent generated `.metal` source when one exists, which is
required for retargeted SN3 artifacts, and otherwise loads the matching AOT
`.metallib`, which is the checked-in SN2 path. This selection is made before
proving and never compiles source merely because a metallib is present.

### 4.7 Verification status for this checkpoint

The lightweight regression gate after the persistent proof is:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
# Ran 195 tests ... OK

PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-prover-session-test -Doptimize=ReleaseFast

PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-arena-plan metal-arena-session -Doptimize=ReleaseFast
```

The Python total includes adapter identity, manifest/provenance, benchmark,
PoW telemetry, queue fail-closed behavior, optional references, JSONL ordering,
publication, canonical Rust evidence mutation, cache telemetry, 10/100
acceptance test doubles, and streaming test doubles. It does not replace a real
v4 proof or 10/100-block acceptance queue. The unfiltered Zig import closure ran
471/479 and retained eight unrelated known general-suite failures; the focused
v4 session surface above is green. No Metal proof was run for the v4 gate.

## 5. Current Implementation Audit

### 5.1 Raw PIE boundary is not yet owned by Zig

The queue adapter currently invokes a Rust `gpu_bench --backend simd
--adapt-only` command. The service can accept a raw PIE path, but execution and
adaptation are still an external Rust implementation detail.

The archive cache identity for extracted PIE directories previously used names,
sizes, and modification times rather than full member content digests. The
current `scripts/sn_pie_adapter.py` now hashes canonical member paths, streamed
byte counts, and member contents, and emits deterministic archive bytes. Tests
cover a same-size mutation with restored modification time. This closes the raw
directory identity defect, but the complete production identity must still bind
the adapter binary/version, bootloader configuration, archive, and resulting
`ProverInput`.

The short-term production service may own a versioned Rust adapter subprocess,
provided the request boundary, digests, configuration, resource limits, and
failure semantics are explicit. The long-term goal is a Zig execution/adapter
path behind the same `BlockExecutor` contract.

### 5.2 Statement and geometry are partly fixture-derived

Current schedule retargeting and composition retargeting consume data derived
from target Rust proof JSON. This means the checked-in or generated manifests
can prove the prepared four-fixture corpus, but they do not yet demonstrate a
generic raw-PIE-to-proof path.

Production geometry must be derived from:

- The validated `ProverInput` and its exact real row extents.
- The canonical Cairo AIR/component registry and semantic artifact versions.
- PCS and FRI parameters.
- Public segment starts, public memory, and component claims derived from the
  current statement.

Generated Metal kernels must be keyed by statement-independent AIR semantics.
Statement constants belong in a per-proof control or parameter table, not in a
new source compilation for every block.

### 5.3 Transcript and quotient fixtures are now optional diagnostics

The Zig JSONL daemon parser permits transcript and quotient reference paths to
be absent and injects diagnostic environment variables only when both paired
references are present. The Python `SessionArtifacts` client, queue manifest,
subprocess builder, and persistent executor implement the same optional paired
rule. The checked-in example manifest omits the pair for all four PIEs. The
one-shot runner and JSONL path self-serialize the canonical statement, locally
derive the transcript, execute quotient unconditionally after OODS, gate FRI on
execution and final degree, and gate decommitment on real FRI completion. With
no query fixture they self-grind the query nonce and positions.

The 2026-07-16 SN2 run in Section 4 proves this path is executable and valid:
both reference paths were absent, `parity_fixture_used=false`, the proof
verified, and the proof bytes were emitted. A paired-reference diagnostic run
immediately before it also verified at 0.575045 MHz, showing that the same path
can still validate the statement roots, quotient inputs, FRI checkpoints, and
forced nonces without allowing those references to populate production state.

These controls established exact parity and were appropriate for bringing up
the Metal implementation. They are not valid production inputs.

The connected M1 primitives are:

- `statement_bootstrap.zig` derives statement ordinals 1, 2, and 10-16 from the
  adapted input and composition schedule and populates `TranscriptRecipe`.
- `arena_binding.zig` can compare those ordinals and tree roots 1 and 2 against
  a reference without mutating the resident transcript state.
- `CairoProofPlan` can be derived from the schedule and adapted input.
- Interaction PoW can be ground locally.
- Query PoW and positions can be generated locally.
- OODS and quotient inputs can be materialized locally.
- Quotient fixture validation is assertion-only and does not gate execution.
- FRI execution and final-degree validity, rather than fixture comparison, gate
  decommitment.

The remaining M1 gates are corpus coverage and independent cross-verification:
SN1 and SN4 must pass reference-free, then all four proofs must be checked by
the canonical Rust verifier used by the SIMD prover. M2 must still remove
proof-derived schedules and semantic artifacts before the service may report
`self_contained=true`.

### 5.4 Persistent mode uses protocol v4 and report schema v3

The implemented transport is strict JSONL protocol v4. The daemon emits one
`ready` frame, accepts one in-flight `prove` request at a time with monotonically
increasing `sequence` and unique `request_id`, returns one matching result, and
accepts `shutdown` only at the next sequence. A successful shutdown emits
`closed` with the exact completed-request count. Transcript and quotient
references form an optional pair in Zig and Python; omitting both is the
reference-free default.

Protocol v4 uses exact-key frames. Every artifact is exactly one of:

```text
{"path": <absolute path>}
{"object_id": <lowercase SHA-256>, "bytes": <positive u64>,
 "diagnostic_path": <absolute path>}
```

The required `composition_program` artifact makes the selected generated Metal
source or metallib explicit. Every prior protocol version, legacy bare-path values, missing
artifacts, mixed path/object shapes, unknown keys, invalid byte lengths, and
unpaired tree companions are rejected. The top-level contract is:

```text
ready:
  protocol, version=4, type="ready", session_id,
  daemon_executable_sha256, runner_executable_sha256,
  runner_linkage="in_process", rust_verifier, capabilities

prove request:
  protocol, version=4, type="prove", sequence, request_id,
  artifacts={adapted_input, schedule, witness_programs,
             multiplicity_feeds, relation_templates, fixed_tables,
             composition, composition_program, preprocessed_evaluations,
             preprocessed_tree0_merkle, preprocessed_coefficients,
             transcript_reference?, quotient_reference?},
  outputs={proof, report}, budget_gib, expected_tree0_root_hex

verified result:
  protocol, version=4, type="result", status="verified", sequence,
  request_id, proof_verified, outputs_committed, adapted_cycles,
  adapted_input_sha256, prove_wall_s, prove_timing_scope, prove_mhz,
  session_block_wall_s, proof_bytes, proof_sha256,
  self_contained, parity_fixture_used, proof_derived_artifact_used,
  statement_self_derived, artifact_manifest_digest, artifact_objects,
  provenance_complete, proof_protocol, protocol_complete,
  daemon_executable_sha256, runner_executable_sha256, runner_linkage,
  rust_verifier, pipeline_cache_delta?,
  reuse={runtime,resident_arena,preprocessed_state}

shutdown:
  protocol, version=4, type="shutdown", next_sequence

closed:
  protocol, version=4, type="closed", completed
```

Protocol v4 requires a non-null lowercase manifest digest, complete manifest
evidence, the exact artifact-object map, canonical proof protocol, and complete
provenance. The daemon embeds the complete canonical manifest in the committed
report. The Python client recomputes its digest and protocol digest, validates
every object ID and length against exactly one manifest entry, validates proof
and report bytes, and only then learns object references for later requests.
The service-owned artifact store snapshots admitted paths under a private
content-addressed root; authenticated object-reference hits do not reread the
original caller path. A private session `ViewCache` reuses validated adjacency
views for the large preprocessed pair and composition/program pair without
changing store identity.

The direct runner supplies `self_contained`, `parity_fixture_used`,
`proof_derived_artifact_used`, and `statement_self_derived`. The daemon promotes
those facts and constructs the manifest, canonical protocol, executable
identity, and conservative completeness state. Missing, malformed,
contradictory, or incomplete evidence fails the v4 transaction rather than
being represented by an optional null field. Production acceptance is stricter than
transport acceptance: any block that is not self-contained, uses a parity
fixture, uses a proof-derived artifact, or lacks complete PoW, provenance, or
protocol evidence becomes `production_rejected`; sustained production metrics
are withheld and the command exits nonzero. The current prepared corpus is
therefore `verified_diagnostic`, with complete v4 evidence but forbidden
proof-derived provenance.

The daemon must be started with `--rust-verifier <release-adapter>` and
`--rust-verifier-lockfile <Cargo.lock>`. It admits both into its private
artifact store, requires lock SHA-256
`72ee6a80235ff78a6e2c1724a8c6d1c45798c2a11c1c1539bc675af066b0e31c`,
copies them read-only, and remeasures them around every verification. The ready
identity and per-proof 17-field evidence bind the adapter, lock, source pins,
protocol, statement, proof, provenance, result, and verifier timings.

The runner/session/queue protocol object is exact-key and exact-type checked:

```json
{
  "channel": "blake2s",
  "channel_salt": 0,
  "log_blowup_factor": 1,
  "n_queries": 70,
  "interaction_pow_bits": 24,
  "query_pow_bits": 26,
  "fri_fold_step": 3,
  "fri_lifting": null,
  "fri_log_last_layer_degree_bound": 0
}
```

Unknown/missing keys, boolean values in integer fields, or any value drift set
`protocol_complete=false` in the one-shot evidence model and is rejected by the
v3 session. Runner, session, committed report, and queue emission are active.

Before a request starts, the client and daemon canonicalize and hash the
adapted input. The daemon hashes it again after proof verification; any mutation
fails the transaction. It writes proof and report to exclusively created
temporary siblings, fsyncs them, and publishes with exclusive hard links. It
never replaces an output created after validation. If report publication fails
after proof publication, it removes the newly linked proof. A sequence error,
timeout, malformed frame, digest mismatch, unverified proof, daemon nonzero
exit, or missing clean `closed` frame withholds queue throughput and stops later
publication.

The process correctly reuses:

- `MTLDevice` and command queues.
- Loaded libraries, AOT composition metallibs, and library-cache entries.
- PSOs and binary-archive state.
- Content-addressed artifact snapshots and authenticated object identities.
- Private preprocessed/composition adjacency views for exact object keys.
- On an exact prepared-geometry key hit, the parsed schedule, schedule digest,
  and witness, feed, relation, fixed-table, and composition bundles in a
  transactional capacity-four host cache.
- On an exact prepared-state key hit, the 26,083,213,312-byte SN2 resident
  arena and a compact authenticated immutable-state snapshot.
- On a canonical full-proof exact-key and exact-logical-layout hit, the owned
  physical `arena.Plan`, including its 17,552 bindings. Current source retains
  four such compact host plans independently of resident-state eviction; the
  latest proof pair validates the repaired cold-transfer and exact warm-hit
  paths.
- On the same capacity-one resident hit, fixed-table, multiplicity-feed, base
  AOT witness, interaction AOT witness, and three compact recipes with their
  stable arena/library/pipeline references.
- The base inverse twiddle bank as part of the prepared request-start snapshot.

Every request still:

- Revalidates schedule/bundle coverage and rebuilds the statement, proof plan,
  and staged liveness/logical-buffer metadata.
- Recreates request-local prepared proof bindings, EC and interpolation
  preparation, and the remaining protocol recipe objects.
- Configures the one-shot runner through process environment variables.

A parsed-host-geometry miss reads and transactionally stages the schedule and
bundles. A separate host-plan miss builds and stages the canonical physical
plan. Independently, a resident-state miss allocates the arena, restores
request-start inputs, and captures a compact snapshot. An exact resident hit
borrows a committed host plan, reuses the arena, clears it to fresh-buffer
semantics, and restores the snapshot in one command. A resident key mismatch
replaces only the capacity-one arena/snapshot/recipe entry; unrelated committed
host plans survive. Any failure destroys a pending plan or conservatively
evicts the active hit while retaining unrelated geometry entries.

On the repeated current SN2 request, external admission and report handling are
only milliseconds. The instrumented in-process runner spends 0.401039750
seconds before `recorded_witness_start_to_verified_proof` and 0.001179583
seconds from proof verification to report serialization. The warm pre-prove
interval includes 0.134389501 seconds of adapted-input materialization,
0.102509334 seconds of arena reset/restore, 0.051126917 seconds of liveness
analysis, 0.044161375 seconds of bundle validation, 0.030699958 seconds in the
broad recipe/protocol-prelude scope, and smaller phases. The exact recipe
subreport attributes 0.029109251 seconds to pre-prove recipe acquisition and
construction. Warm Metal pipeline preparation itself is only 0.000215530
seconds. Extracting proof/liveness metadata, bindings, interpolation and
remaining recipes into one session-owned `PreparedGeometry` and command graph
is therefore a measured service-throughput requirement, not a
shader-compilation or kernel-speed claim.

Build and run the implemented prepared-corpus JSONL path from the repository
root as follows. Use a fresh output directory on every run:

```sh
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-arena-session metal-arena-plan -Doptimize=ReleaseFast
cargo build --release --locked \
  --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml \
  --bin stwo-cairo-verifier-adapter

STWO_ZIG_METAL_REPLAY_RETAINED_LOOKUPS=1 \
  python3 scripts/sn_pie_metal_queue.py \
  --manifest scripts/sn_pie_metal_queue.example.json \
  --length 10 --seed 20260715 \
  --output-dir /private/tmp/sn-pie-session-diagnostic-10
```

This command is diagnostic because the checked-in manifest names proof-derived
semantic artifacts, although it omits parity references. Adding `--production`
activates fail-closed
production acceptance; it must reject the current corpus until the report has
the three production values in Section 3.3. The current daemon SHA-256 is
`f5ea2fa498bee479bb37835b280254230a82057f15b837ace2f7bdc6d0ed0015`;
the in-process runner has the same identity in the current evidence.

### 5.5 Command ownership remains mostly wrapper-local

The runtime still has dozens of static command-buffer creation and
`waitUntilCompleted` sites. Dynamic component and column-group loops multiply
these sites into thousands of proof-time boundaries.

The current commitment-oriented profile contains approximately:

- 1,217 command buffers.
- 389 composition-LDE commands.
- 358 compact-leaf commands.
- 128 IFFT commands.

Many runtime helpers still create, commit, and synchronously wait on their own
command buffer. The scoped exception is production composition:
`compositionPrepared` now encodes front and finalization in one command buffer
and one wait. That proves the prepare/encode ownership pattern and exact proof
parity, but its essentially flat 2.392-second composition measurement shows
that submit collapse alone does not remove transform or memory traffic. The
remaining wrappers prevent a proof-level scheduler from batching independent
work, using one ordered queue without host waits, or measuring whole protocol
epochs.

### 5.6 One Shared monolithic arena is the active ABI

The current arena is one `MTLResourceStorageModeShared` buffer. Kernels receive
that buffer plus `u32` or selected `u64` word offsets. The planner has rigorous
liveness and alias validation, but physical resource ownership is still
monolithic.

Consequences include:

- Narrow `u32` word offsets can address only the first 16 GiB of a buffer.
- Selected coefficient and decommit paths need special wide-offset ABIs.
- Every encoder that binds the arena exposes a 35-41 GB resource capacity to
  Metal and the profiler, even when it touches a small region.
- CPU diagnostic reads and writes encourage Shared storage for all proof data.
- Preprocessed state cannot be placed independently of per-geometry arena
  offsets, complicating genuine cross-block reuse.
- Counter pass descriptors caused severe residency/page-in perturbation on the
  wide SN4 arena.

### 5.7 Current dataflow repeats full-domain transforms

The base and interaction schedulers already improve lifetime management:

- A component writes evaluation columns.
- It immediately interpolates them into retained coefficients.
- Producer feeds and lookup inputs are released or replayed by explicit policy.

However, later stages repeatedly turn those coefficients back into evaluations:

- Commitment creates LDE evaluations, absorbs leaves, and discards them.
- Composition recreates component-wide LDE evaluations.
- Decommitment recreates LDE evaluations again for approximately 70 query
  positions when no full evaluations were retained.

Commitment must evaluate the full domain because queries are not known yet.
Composition and decommitment do not both need an unconditional new full-domain
materialization for every column.

### 5.8 Composition is component-wide, not tiled

`prepareCompositionRecipe` constructs one full-component `CompositionLdePlan`
and one `EvalBatchPlan` at a time. For each component it takes the union of its
preprocessed, base, and interaction source spans, allocates destinations for all
sources across the full component evaluation domain, runs all source LDEs, then
runs every generated AIR part against that tile. The tile is overwritten for
the next component; there is no transformed-source cache across components.

The Cairo bundle has 58 components, 279 AIR-part invocations, 271 unique PSOs,
and 1,325 constraint expressions. On SN2 the active component tile is
5,972,688,896 bytes (5.5625 GiB), while the four-coordinate cumulative
accumulator slab is 402,651,648 bytes across 18 log buckets. The 5,876 source
occurrences generate 7,193,570,496 terminal LDE words, or 26.798 GiB, before
FFT intermediate traffic. Only 5,870 `(tree,column,evaluation_log)` identities
are unique, so perfect reuse across component boundaries would save only six
occurrences, approximately 10.28 MiB. Cross-component caching is therefore not
the main opportunity.

A static sparse-RFFT accounting pass, excluding source and twiddle reads,
estimates 655.4 GiB of composition arena traffic on the default path. The
already implemented but opt-in upper radix-4 path projects about 382.0 GiB. The
default graph encodes 545 LDE encoders, 279 AIR encoders, and 27 finalization
encoders: 854 encoders and 869 compute dispatches, plus the accumulator clear.
Each AIR part performs a global read-modify-write of four cumulative
accumulators. That is at least 8.450 GiB of accumulator traffic versus 2.300 GiB
for one writeback per component, leaving 6.150 GiB removable before considering
cache effects.

The generated kernel already fuses each individual part's constraint
arithmetic, random-coefficient progression, denominator work, and cumulative
accumulation. The current sparse fused eleven-stage RFFT tail previously moved
composition from roughly 3.31 seconds to roughly 2.39 seconds, and component
LDE/AIR work is interleaved without host waits. The next gain therefore requires
multi-part fusion or a different transform-consumer dataflow, not merely
concatenating more source into one per-part kernel.

### 5.9 Decommitment regenerates much more than it returns

The verified zero-retention schedule walks all four trace trees and 370 trace
groups. For each non-retained group it:

1. Runs a complete circle LDE into the 2 GiB decommit tile.
2. Writes evaluation pointers and logs.
3. Gathers the mapped query values.
4. Builds sparse lower leaf and parent hashes.

The output uses only the query positions and sparse bottom-tree data. The full
LDE is a correctness oracle and simple MVP, not the target opening algorithm.

### 5.10 Profiling ranks work but does not establish causality

The public profiler records command-buffer timestamps, encoder metadata,
dispatch geometry, buffer capacities, CPU encode/commit/wait time, and errors.
The M5 Max public counter set exposes timestamps, not occupancy, bandwidth,
cache misses, or SIMD utilization.

Specific limitations that must remain visible:

- Bound buffer capacity is not bytes accessed or memory bandwidth.
- `wait_cpu_ms` includes GPU execution and scheduling.
- `encode_cpu_ms` includes all work between command creation and commit.
- An encoder interval may contain several dispatches and pipeline changes.
- Stage values can overlap hierarchically and cannot always be summed.
- Command events are currently finalized by `waitUntilCompleted`; an async
  graph would lose records unless finalization moves to completion handlers.
- NDJSON serialization and synchronous locked writes add profile overhead.
- Return-address symbolization is not a stable operation identifier.

No large encoder-counter SN PIE run is required for the immediate architecture
work. Targeted bounded kernels and a low-overhead command-only full run in a
quiet window are sufficient until full Xcode Metal System Trace is available.

### 5.11 Current implementation truth table

This table is the source-audited status at the time of this document. It is the
bridge between the verified parity harness and the target architecture.

| Capability | State | Current evidence | Remaining gate |
| --- | --- | --- | --- |
| Direct SN1-SN4 Metal proof and verification | active | Results in Section 4 | Remove forbidden dependencies without losing verification |
| Content-based extracted-PIE identity | active | `sn_pie_adapter.py`; seven focused tests | Bind adapter, bootloader, archive, and adapted output identities |
| Fail-closed evidence in one-shot, persistent, and queue reports | active | Report schema v3, session protocol v4, canonical protocol, manifest, object map, executable/verifier identity, and strict production gates | Run the live v4 gate and authenticate every adapter, schedule, and semantic-artifact source chain |
| Pipeline cache delta preservation | active | Per-block validation and complete-only queue aggregation | Include geometry and immutable-device cache telemetry |
| Content-addressed object and private view reuse | active | Repeated schema-v3 SN2; zero-read exact-object admission and exact-key `ViewCache` | Extend ownership to parsed geometry and immutable device state |
| Optional parity references end to end | active | Zig/Python/queue tests; reference-free SN2 JSONL and SN3 one-shot proofs | Prove reference-free SN1 and SN4 |
| Canonical statement bootstrap implementation | active | `statement_bootstrap.zig`, non-mutating reference validator, reference-free SN2/SN3; Zig compact SN2 statement is byte-identical to Rust encoding and consumed by the v4 envelope | Run the live v4 and full-corpus verifier gates |
| Self-ground interaction/query PoW | active | Reference-free SN2/SN3; separate scoped wall telemetry | Add persistent worker pool, then bounded GPU search in M4 |
| Runtime/library/PSO persistence | active | Latest repeated SN2 warm request has 2 library and 312 PSO hits after base AOT recipe reuse | Move all remaining preparation and resource ownership into the session |
| Resident state plus capacity-four host arena-plan reuse | active, scoped | Exact-key SN2 plan phase falls from 4.678985 s to 0.025152 s with exact proof bytes; subsequent offline A/B/A/LRU/poison tests pass | Mixed live-Metal A/B/A; expand compact plan entries into parsed/bound/recipe-owned geometry; failure injection |
| Async profiler and stable graph IDs | planned | Current profiler finalizes around synchronous waits | Completion-handler event collection and accounting gate |
| AOT composition metallib and stable binary archive | active, scoped | Explicit `composition_program`; current cold request has 337/337 archive hits and zero direct compiles | Versioned full shader manifest, read-only production archive, and zero warm source compiles for every generated family |
| Compiled composition command epoch | active, scoped | Front plus finalization in one production command buffer; byte-identical repeated SN2 proof | Extend encode-only ownership to the full proof and meet M4 wait/submit gates |
| Canonical Rust verifier adapter | mandatory protocol-v4 service wiring active | Real 8,410,304-byte reference-free SN2 Metal proof reconstructs and passes pinned `verify_cairo`; 33 library and four CLI tests; v4 offline session/queue gates pass | Run bounded live v4 SN2, then SN1-SN4 and live queue gates; authenticate remaining source chains |
| Multi-buffer resources and packed banks | planned | Current ABI is one Shared arena | M5 implementation and A/B evidence |
| Bounded composition and pruned openings | planned | Full-domain oracle paths remain active | M6/M7 parity and full-proof speed gates |

The current end-to-end path must report `self_contained=false` and
`proof_derived_artifact_used=true`. Missing provenance is interpreted as the
same fail-closed result. No existing benchmark is retroactively relabeled as a
production proof.

## 6. Protocol Dependency Graph

The STARK transcript imposes semantic dependencies that the scheduler must
preserve:

```text
statement and tree 0
        |
base trace and tree 1 commitment
        |
relation challenges and interaction PoW
        |
interaction trace, claimed sums, and tree 2 commitment
        |
composition random coefficient
        |
composition evaluation and tree 3 commitment
        |
OODS samples and quotient construction
        |
FRI commitments, folding challenges, and final polynomial
        |
query PoW and query positions
        |
trace/FRI openings and proof assembly
```

These edges prevent illegal cross-challenge work. They do not require a CPU
round trip. Roots and challenges can remain in a device control buffer, with
ordered kernels and explicit barriers on one serial queue.

Within each dependency epoch, component, column, transform, relation, Merkle,
and proof-assembly work can be batched and fused when resource lifetimes allow.

## 7. Target Service Architecture

### 7.1 End-to-end topology

```text
                         process-owned MetalProverService
  +--------------------------------------------------------------------+
  | Runtime: device, queue, libraries, PSOs, archives, profiler         |
  | Artifact cache: AIR, fixed tables, schedules, semantic bundles      |
  | Geometry cache: PreparedGeometry and ProofCommandGraph entries      |
  | Immutable device cache: preprocessed banks, tree 0, twiddles        |
  | Reusable resources: coefficient banks, scratch heaps, I/O rings     |
  +--------------------------------------------------------------------+
                 |                                  |
       CPU ingress/adaptation lane             serial GPU lane
                 |                                  |
        raw PIE n+1 -> ProverInput       reset -> prove n -> readback
                 |                                  |
                 +------------ request queue -------+
                                                    |
                                      compact proof verification lane
                                                    |
                                      ordered atomic publication
```

Only one full proof transaction uses the GPU resource set at a time. CPU
adaptation of a future block and CPU verification of a completed compact proof
may overlap GPU work after measurement confirms that shared-memory bandwidth,
thermal pressure, and ordering remain acceptable.

### 7.2 Public service API

The service contract is an asynchronous bounded queue expressed as ordinary Zig
data, not environment variables:

```zig
pub const TimingScope = enum {
    recorded_witness_start_to_verified_proof,
    request_accept_to_atomic_publish,
};

pub const ProvenanceEvidence = struct {
    self_contained: bool,
    parity_fixture_used: bool,
    proof_derived_artifact_used: bool,
    manifest_digest: [32]u8,
};

pub const VerifierEvidence = struct {
    status: enum { not_requested, passed, failed, timed_out },
    executable_digest: [32]u8,
    source_revision: [40]u8,
    statement_digest: [32]u8,
    proof_digest: [32]u8,
    wall_ns: u64,
};

pub const RawBlockRequest = struct {
    request_id: u64,
    pie: ArtifactRef,
    adapter: AdapterConfig,
    pcs: PcsParameters,
    verification: enum { resident_zig, zig_and_rust_acceptance },
    proof_destination: OutputRef,
    diagnostic_parity: ?ParityFixtureSet = null,
};

pub const VerifiedBlockResult = struct {
    request_id: u64,
    raw_pie_digest: [32]u8,
    statement_digest: [32]u8,
    adapted_input_digest: [32]u8,
    artifact_manifest_digest: [32]u8,
    adapter_executable_digest: [32]u8,
    backend_executable_digest: [32]u8,
    adapted_cycles: u64,
    proof_location: OutputRef,
    proof_digest: [32]u8,
    proof_bytes: u64,
    verified: bool,
    timing_scope: TimingScope,
    provenance: ProvenanceEvidence,
    zig_verifier: VerifierEvidence,
    rust_verifier: VerifierEvidence,
    timing: BlockTimings,
    stages: StageTimings,
    memory: MemoryTelemetry,
    cache: CacheTelemetry,
};

pub const MetalProverService = struct {
    pub fn create(allocator: std.mem.Allocator, options: ServiceOptions)
        !*MetalProverService;
    pub fn submit(self: *MetalProverService, request: RawBlockRequest)
        !SubmissionTicket;
    pub fn poll(self: *MetalProverService) !?ServiceEvent;
    pub fn wait(self: *MetalProverService, ticket: SubmissionTicket)
        !*const VerifiedBlockResult;
    pub fn release(self: *MetalProverService, ticket: SubmissionTicket) void;
    pub fn cancel(self: *MetalProverService, ticket: SubmissionTicket) !void;
    pub fn destroy(self: *MetalProverService) void;
};
```

`verified` is a derived convenience value, never an independent assertion. It
is true only when proof publication is allowed by the request's verification
policy and every required verifier has status `passed` with the same statement
and proof digests. A production report also embeds the canonical artifact
manifest named by `artifact_manifest_digest`; the three provenance booleans are
recomputed by the service from that manifest and cannot be supplied by a
caller. Runner, adapter, and verifier executable digests are sampled before the
session accepts work and are immutable for that session.

`submit` copies or takes explicit ownership of every request field. A result is
owned by the service until `release`; the proof itself is already atomically
published at `proof_location`, so no borrowed proof slice escapes the service.
`destroy` cancels unstarted work, drains in-flight GPU work, releases completed
results, and then destroys prepared objects before Runtime.

Each ticket follows exactly one state machine:

```text
submitted -> adapting -> adapted -> prepared -> gpu_in_flight
          -> verifying -> published -> released
          \-> cancelled | failed
```

Default bounds are two raw ingress entries, two adapted staging entries, one GPU
transaction, one speculative completed proof awaiting ordered verification, and
two result records. Submission blocks or returns `error.QueueFull` at the
configured boundary. Deadlines are checked before adaptation, before GPU
admission, and between bounded PoW windows. Cancellation removes queued CPU work;
an in-flight GPU transaction completes but its output is discarded and the
resource set is reset. The first ordered failure cancels later publication.

The JSONL daemon is an adapter over this API. It must not be the owner of proof
semantics, artifact parsing, or environment-based feature selection.

### 7.3 Ownership and lifetime model

| Owner | Lifetime | State |
| --- | --- | --- |
| Service | Process | Runtime, queues, caches, profiler, resource pools |
| Artifact entry | Content version | Parsed AIR, relation, fixed-table, witness metadata |
| Geometry entry | Geometry key | Plans, graph nodes, PSOs, descriptor tables, reset map |
| Immutable device entry | Persistent-state key | Preprocessed data, tree 0, twiddles |
| Proof resource set | Reused serially | Coefficient banks, scratch heaps, I/O slots |
| Transaction | One block | Statement, transcript, roots, challenges, proof state |
| Diagnostic parity | Optional transaction | Expected digests, nonces, mismatch readback |

Prepared objects are destroyed before the Runtime they reference. A geometry
entry can be evicted without evicting the Runtime pipeline cache or immutable
device state.

## 8. Self-Contained Ingress and Statement Derivation

### 8.1 Artifact identity

Every cache identity is a SHA-256 over canonical bytes and version fields.
Paths and modification times are diagnostics only.

The raw input identity includes:

- Canonical PIE archive bytes or every extracted member path and content.
- PIE format version.
- Bootloader program and configuration.
- Layout and builtin configuration.
- Adapter executable identity and semantic version.
- Adapter format version.

The adapted-input identity includes:

- Complete `ProverInput` bytes.
- Adapted cycle count and resource counts.
- Public memory and segment descriptors.
- Component real and padded row extents.

Every accepted artifact has a canonical manifest entry:

| Field | Meaning |
| --- | --- |
| `kind` | PIE member/archive, adapter, bootloader, adapted input, AIR bundle, fixed table, schedule, composition, preprocessed state, parity fixture |
| `sha256` and `bytes` | Digest and canonical byte length |
| `format_version` | Parser/ABI version for those bytes |
| `generator` | Executable/tool digest, semantic version, compiler identity, and arguments |
| `source_digests` | Ordered inputs from which the artifact was derived |
| `provenance` | `raw`, `canonical_generated`, `diagnostic_fixture`, or `proof_derived` |

Production permits only `raw` and `canonical_generated`. A caller cannot assert
`self_contained`. The service computes it after verification as the conjunction
of: all raw bytes were content-verified; the adapter/bootloader identity is
allowed; every semantic artifact has permitted provenance and a complete source
chain; the statement was derived by the canonical serializer; no parity fixture
affected execution; and the emitted proof verified against that statement.
`parity_fixture_used` is true whenever a fixture is read for execution or
comparison. `proof_derived_artifact_used` is true whenever any transitive
manifest entry has `proof_derived` provenance. Missing or malformed provenance
sets the conservative values `false`, `true`, and `true` respectively.

Cache keys are separated by responsibility:

| Key | Bound data |
| --- | --- |
| `InputKey` | Canonical PIE bytes, execution configuration, adapter identity |
| `ArtifactKey` | Semantic bytes, format, generator, ordered source digests |
| `LogicalGeometryKey` | Component order/extents, AIR identity, PCS/FRI parameters |
| `DevicePlanKey` | Logical geometry, backend ABI, metallib, device family, OS |
| `PersistentStateKey` | Preprocessed banks/tree 0/twiddles and their layout |
| `TuningKey` | Device/OS/metallib plus exact transform or kernel shape |

An arbitrary path is read and hashed before admission. A later zero-read hit is
valid only when the request names an object in the service-owned content store
and an authenticated manifest already binds that immutable object ID to its
verified digest. Path and mtime hits never establish trust. CPU and device
caches use byte-budgeted LRU admission and eviction; entry count is telemetry,
not the resource limit.

### 8.2 Statement serializer

One canonical serializer must produce the transcript bootstrap and verifier
statement from:

- Channel salt and proof-system version.
- PCS parameters and tree log geometry.
- Canonical component order, claims, and log sizes.
- Public memory and public segment boundaries.
- Program hash and output/public return values.
- Tree-0 commitment identity.

Parity tests compare every serialized ordinal against existing Rust fixtures.
Production invokes the serializer with no reference file available.

### 8.3 Self-generated transcript state

Production must:

- Initialize and bootstrap the channel from the canonical statement.
- Publish tree roots produced by the current transaction.
- Draw relation challenges in the canonical batch shape.
- Grind the interaction PoW nonce locally.
- Draw composition and OODS challenges locally.
- Materialize quotient inputs from current OODS results.
- Run FRI and gate on final-degree validity.
- Grind the query nonce and generate current query positions locally.

Parity mode may force known nonces to obtain byte-identical checkpoints. It may
not change the production result or acceptance criteria.

### 8.4 Geometry and composition derivation

`PreparedGeometry.build` takes the validated `ProverInput`, AIR registry, and
PCS parameters. It does not take a target proof.

The composition compiler separates:

- Statement-independent AIR instructions and source dependency metadata.
- Geometry-dependent dispatch sizes and column mappings.
- Statement-dependent constants placed in the transaction control table.

This separation prevents stale composition artifacts when public segment starts
or claims change and allows a semantic kernel to remain cached across blocks.

#### 8.4.1 Why bindings exist, and why they are not per-block work

A raw Cairo PIE is an execution artifact, not a Metal-ready STARK trace. The
service must derive the public statement, component row extents, execution and
builtin witness inputs, public memory, lookup inputs, and multiplicities before
it can prove. That adaptation is block-dependent and belongs behind the raw-PIE
service boundary; it must not appear as a manual preprocessing requirement for
the caller.

Metal bindings solve a different problem. The current SN2 geometry has 17,552
logical proof buffers placed in one 26,083,213,312-byte resident arena. An
`arena.Binding` maps each logical identity to a physical byte range, and the
arena planner proves that ranges may alias only when their live intervals do
not overlap. `PreparedProofBindings` then links protocol concepts such as
composition inputs, commitment workspaces, FRI layers, transcript records, and
proof assembly to those stable offsets. This map is required for correct GPU
addressing, but it is a property of geometry and backend ABI, not of the PIE's
field values.

Production therefore compiles bindings once into `PreparedGeometry`; a known
geometry request only patches transaction data. Its request path is:

```text
raw PIE -> execute/adapt -> geometry fingerprint/cache lookup
        -> lease one resident prover -> reset mutable ranges
        -> populate block data and transaction control -> dispatch graph
        -> verify and publish proof
```

On a known-geometry hit there is no schedule parsing, semantic-bundle loading,
liveness analysis, arena coloring, proof-binding collection, metallib loading,
pipeline lookup, or recipe construction. A geometry miss may compile and
transactionally admit those objects once. The compact host geometry cache is
capacity four for SN1-SN4, while the 26 GB mutable Metal workspace remains
capacity one; switching the resident workspace from A to B must not discard
host geometry A, so A/B/A avoids recompiling either plan.

The current parity runner has not completed that separation. The latest warm
SN2 request still spends 0.386450709 seconds reconstructing remaining recipes,
0.051661291 seconds rereading/validating bundles, 0.048512959 seconds rebuilding
liveness, and 0.025151958 seconds validating the cached plan and rebuilding
request proof bindings. More prepared objects are constructed after the prove
timer starts, including interaction, relation, composition, quotient, FRI,
decommit, and proof-assembly recipes. Reports must therefore distinguish GPU
execution from in-timer host preparation as the graph is extracted.

Some request work remains necessary. The service must populate PIE-derived
inputs, patch statement and real-row values, reset mutable state, advance the
transcript, execute the proof, and verify its output. Current reset isolation is
overbroad: it zeroes the whole 26.08 GB arena and restores a 4.37 GB immutable
snapshot, costing 0.103511333 seconds wall on the measured warm request.
Production replaces this with immutable/mutable resource separation or a
verified overwrite-before-read dirty-range reset; correctness requires fresh
mutable state, not clearing every byte.

### 8.5 Transcript and PoW execution

The current `TranscriptRecipe.grindAndMix` reads the Shared transcript state
back into a CPU `Blake2sChannel`, calls its threaded `grind`, writes the nonce,
and resumes Metal mixing. The legacy SN1-SN4 baselines force known reference
nonces. The reference-free SN2/SN3 runs now measure CPU search itself:
interaction PoW was 10.5-14.7 ms and query PoW was 794.1-897.2 ms in those
samples. These are per-proof observations, not an SN4 distribution or a
persistent-worker benchmark. Any model that treats PoW cost as zero, or simply
transfers one sampled nonce-search time to all blocks, is invalid.

M1 first establishes correctness with local CPU grinding. The target service
will own a persistent worker pool so each nonce search does not create a new
thread set.
That is target-state work, not current behavior. Today `channel.grind` creates
threads per search and reports only mode, bits, invocation count, wall time, and
the accepted nonce; its strided first-winner search does not guarantee the
lowest valid nonce. The worker-pool implementation will additionally report
attempts, hashes per second, aggregate worker time, and deterministic selection
semantics separately for both searches.

`fixture_forced` telemetry times nonce validation only and cannot be compared
with `self_ground` search wall. A paired-reference interaction replay can
validate the fixture twice, producing cumulative wall and two invocations; the
Python completeness gate deliberately rejects that shape as self-ground
production evidence. Query fixture validation currently occurs once.

The command-graph target uses a Metal Blake2s nonce-search kernel over bounded
contiguous windows. Each window reduces hits to the lowest nonce, writes a
device status/control record, and either advances or lets the transcript graph
continue. The CPU worker pool remains an explicit diagnostic/fallback A/B path;
it is forbidden in production MHz once the GPU path passes nonce, transcript,
proof, watchdog, and full-wall gates. GPU PoW integration belongs to M4, while
M1 requires only self-generated, verified nonces with measured cost.

## 9. Resource and Buffer Architecture

### 9.1 Resource classes

| Class | Preferred storage | Contents |
| --- | --- | --- |
| Shared I/O/control | Shared | Input staging, scalar control, compact proof output |
| Immutable device | Private | Preprocessed banks, tree-0 layers, twiddles |
| Durable transaction | Private | Base, interaction, and composition coefficients |
| Transient scratch | Private placement heaps | Trace, transform, leaf, relation, composition, opening scratch |

On Apple silicon, Private and Shared use unified physical memory; Private does
not create extra VRAM. It changes CPU visibility and can allow more appropriate
GPU resource handling. Each migration is A/B tested because the storage label
alone is not evidence of a speedup.

### 9.2 Multi-buffer address ABI

The monolithic arena offset becomes a region-qualified reference:

```zig
pub const DeviceRegion = enum(u16) {
    control,
    preprocessed,
    base_coefficients,
    interaction_coefficients,
    composition_coefficients,
    retained_evaluations,
    scratch,
    merkle,
    proof_output,
};

pub const DeviceRef = extern struct {
    region: DeviceRegion,
    flags: u16,
    word_offset: u32,
};
```

Each region is kept within the `u32` word-addressable 16 GiB range. A larger
logical class is sharded into multiple regions rather than reintroducing a
single wide buffer. Current base and interaction coefficient banks fit in
separate regions.

An `ArenaViews` argument buffer or fixed buffer table binds region bases once
per graph epoch. Descriptors select a region and local word offset. A Tier-2
argument-buffer path can use GPU addresses after a capability check; a fixed
buffer-index fallback preserves portability and testability.

### 9.3 Packed coefficient banks

Coefficients are packed by:

```text
(tree index, log size, canonical column ordinal)
```

The packed layout provides:

- Contiguous batched transforms for equal-log columns.
- Stable descriptor tables across requests of the same geometry.
- A direct mapping from canonical proof column to device address.
- Independent storage from transient trace and LDE scratch.
- Simpler retention-benefit accounting by column group.

The coefficient floor remains physical memory. Splitting it out of the mutable
arena is an ownership and addressability improvement, not a claim that the
19.907 GiB disappears.

### 9.4 Placement heaps and aliasing

The existing liveness planner remains the semantic source for non-overlap. Its
output is extended from one buffer offset to:

- Resource class.
- Heap index and placement offset.
- Storage mode and hazard mode.
- Exact first/last graph node.
- Reset or full-overwrite policy.

Start with tracked hazards. Placement-heap aliases are activated only after the
prior resource is dead and the graph contains the required ordering. Untracked
hazards require explicit barriers and focused alias tests.

### 9.5 Reset invariants

`beginTransaction` must:

1. Assert that no previous GPU work owns the resource set.
2. Activate the required immutable device entry.
3. Clear only mutable ranges that are not fully overwritten before first read.
4. Reset transcript, roots, challenges, nonces, FRI state, openings, and output.
5. Zero fixed and runtime multiplicities before producers execute.
6. Rewrite all input and padded-tail destinations.
7. Rewrite block-specific segment starts and public data.
8. Reset recipe/graph telemetry and error state.
9. Mark the geometry dirty after any failed GPU mutation.

A debug reset mode poisons mutable regions, executes the normal reset, and
proves A/B/A parity to detect stale reads.

### 9.6 Target memory envelope

The first target for one active proof is:

| Resource | Target envelope |
| --- | ---: |
| Long-lived coefficients | 19.907 GiB current hard floor |
| Optional preprocessed evaluations | Up to 1.798 GiB |
| Retained upper Merkle layers | Approximately 0.625 GiB |
| Twiddles, descriptors, control | Approximately 0.3-0.6 GiB |
| Bounded mutable scratch | 2-4 GiB |
| Adapted input and compact readback | Approximately 0.3 GiB plus proof |
| Total target | Approximately 25-29 GiB |

This target replaces the current 33.119 GiB SN4 buffer and creates operating
headroom for SN1. Retained evaluations are selected within the actual peak
envelope; they are not added unconditionally.

The envelope is process-wide, not derived from `maxBufferLength`. Admission
includes active proof resources, immutable device entries, all geometry plans,
staging/output rings, adapter/verifier RSS, runtime allocations, and reserved
system headroom. The default policy allows only one wide immutable entry to be
device-resident; other geometry entries may retain compact host plans and are
uploaded through byte-budgeted LRU admission. Retention capacity is the minimum
of the configured service budget, measured recommended working-set headroom,
and current memory-pressure headroom.

### 9.7 Device admission and recovery

The service takes a host-local exclusive device lease before allocating a wide
workspace. A second prover process fails admission rather than relying on
`maxBufferLength` to protect the machine. Admission checks device capability,
maximum single-buffer length, requested total allocation, current service RSS,
memory-pressure state, and configured system reserve.

Errors have three classes:

| Class | Examples | Recovery |
| --- | --- | --- |
| Request-recoverable | Invalid PIE, deadline before GPU admission, output collision | Reject request; resource set remains clean |
| Geometry-dirty | Kernel/device status failure after mutation, cancelled in-flight transaction | Drain, poison/reset, A/B validation before reuse |
| Fatal-device | Device removed, command queue failure, allocation/residency invariant breach | Stop session, publish nothing later, recreate service explicitly |

Critical memory pressure before GPU admission evicts caches or rejects the
request. Pressure during a proof records the event, completes or aborts at the
next safe command boundary, marks resources dirty, and invalidates performance
evidence even if a diagnostic proof can later verify.

## 10. Compiled Proof Command Graph

### 10.1 Graph node model

```zig
pub const GraphNode = struct {
    id: u32,
    stage: StageId,
    component: ?u32,
    operation: OperationId,
    epoch: ProtocolEpoch,
    encoder: enum { compute, blit },
    predecessors: []const u32,
    pipeline: PipelineHandle,
    dispatch: DispatchGeometry,
    dispatch_bounds: DispatchBounds,
    arguments: ArgumentTableIndex,
    accesses: []const ResourceAccess,
    completion_guard: ?DeviceStatusRef,
    failure_code: FailureCode,
};

pub const ResourceAccess = struct {
    resource: DeviceRef,
    byte_length: u64,
    usage: enum { read, write, read_write },
};
```

Every node has a stable ID. Debug labels, profiler records, errors, and parity
checkpoints use these IDs rather than return-address symbolization.

`predecessors` contains both protocol dependencies and resource hazards. The
graph compiler lowers these edges to encoder order, explicit barriers, fences
when resources cross encoders, and command-buffer completion dependencies.
Every protocol epoch ends with a device status guard before its outputs can be
consumed. An error writes the first failure code atomically and all later
guarded nodes become no-ops; the host publishes neither proof nor MHz.

PoW and any other variable-work node use bounded dispatch windows. A window
tests a fixed nonce interval and reduces all hits to the lowest valid nonce, so
selection is deterministic. The graph advances windows until a nonce is found
or a declared attempt and wall-clock watchdog limit fails the transaction.

### 10.2 Encode-only runtime API

Runtime operations are split into preparation and encoding:

```zig
const plan = try prepareOperation(runtime, geometry, descriptors);
try plan.encode(&command_context, transaction_resources);
```

An encode method never creates a command buffer, commits, waits, reads a Shared
buffer from the CPU, or writes a report. The graph executor owns those actions.

### 10.3 Command policy

The initial production policy is:

- One serial Metal command queue.
- Four to eight bounded command buffers per proof for fault isolation,
  scheduling, and profiler readability.
- Command buffers committed in queue order without CPU waits between them.
- One final completion notification and proof readback wait.
- Buffer barriers at true producer-consumer boundaries.
- No CPU challenge or root round trips.

The prepared epoch mapping is explicit:

| Command buffer | Protocol epochs |
| --- | --- |
| 0 | Reset, input materialization, base witness/interpolation/commitment |
| 1 | Relation challenge, interaction PoW, interaction witness/commitment |
| 2 | Composition, tree 3, OODS, quotient |
| 3 | FRI commitments, query PoW, openings, proof assembly |
| 4-7 | Reserved splits when watchdog, residency, or fault-isolation evidence requires them |

The exact split is geometry-prepared and reported; it is not allowed to create
an intermediate CPU wait. Production acceptance requires at most eight command
buffers total, zero intermediate waits, encode-plus-submit CPU time below 3
percent of proof wall, and measured queue-idle gaps below 3 percent. Encoder,
dispatch, barrier, and command-buffer counts remain separate telemetry.

The target is one synchronous wait per proof, not one wait per command buffer.
Optional diagnostic parity may add explicit checkpoints and is excluded from
production MHz.

### 10.4 Indirect command buffers and multiple queues

The proof graph is static once geometry is prepared, but normal Metal command
buffers are single-use. Prepared graph nodes and argument tables should first
make normal encoding cheap.

Use an indirect command buffer only if measured CPU encode and commit time
remains above 3-5 percent of verified proof wall after graph batching. Its
resource residency declarations, feature support, mutation model, and debugging
cost must be included in the measurement.

Use multiple queues only when the graph proves independent work and targeted
profiling shows compute or copy overlap without bandwidth contention. A second
queue is not a substitute for removing unnecessary waits.

### 10.5 Shader build and pipeline distribution

The earlier specialized witness path spent more than 7.5 minutes in runtime
source compilation without completing a proof. Section 4.4 records the compiler
expansion cause and existing mitigation. Production therefore treats
generated shader construction as an artifact build, not proof execution.

Canonical witness/AIR IR, generator version, emitted Metal source digest,
compiler/Xcode build, flags, target Metal language version, backend ABI, and
resulting metallib digest form one signed or locally authenticated manifest.
Known Cairo writer families and generated AIR kernels are compiled ahead of
service admission into versioned metallibs. Binary archives are populated by a
bounded prewarm job keyed by device family and OS, then opened read-only by the
warm service.

A missing production pipeline causes preparation to fail with its exact key; it
does not invoke `MTLCompilerService` inside a measured warm proof. An explicit
development mode may compile a miss under a wall-clock timeout, persist the
source/compiler logs and output digest, and require a service restart or cache
admission before benchmarking it. Compile failure never selects a CPU proof or
stale metallib silently.

Cold acceptance records metallib load, archive lookup/population, PSO creation,
and any permitted build time separately. Warm acceptance requires zero source
compiles, zero archive population, zero unexpected PSO creation, and a complete
pipeline-cache delta for every block.

## 11. Transform Engine Architecture

### 11.1 One shared transform contract

The prover repeatedly executes circle IFFT, RFFT/LDE, lifted transforms, and
query openings. They should share a prepared engine:

```zig
pub const TransformPlan = struct {
    direction: enum { interpolate, evaluate, pruned_evaluate },
    source_log: u32,
    destination_log: u32,
    batch_columns: u32,
    domain: CircleDomain,
    coset: CosetId,
    normalization: Normalization,
    permutation: enum { natural, bit_reversed },
    blowup_log: u8,
    layout: ColumnLayout,
    source_stride_words: u32,
    destination_stride_words: u32,
    mask_offsets: []const i32,
    lifting: ?LiftingPlan,
    rescale: ?RescalePlan,
    split: ?CoordinateSplitPlan,
    sink: TransformSink,
    variant: TransformVariant,
};

pub const TransformSink = union(enum) {
    coefficient_bank: CoefficientSink,
    evaluation_cache: EvaluationSink,
    merkle_leaf_state: MerkleSink,
    air_slice: AirSliceSink,
    query_gather: QuerySink,
};
```

The sink defines whether the final transform stages write a full global column,
write a durable coefficient bank, update leaf hash state, feed an AIR slice, or
gather only requested outputs.

The commitment sink specifies incremental Blake2s state layout, row mapping,
canonical column ordinal, and first/final-column flags. The AIR sink specifies
the circular mask halo and wrap mapping for every requested offset. The query
sink carries a prepared active-butterfly schedule, deduplicated destination
indices, and final gather order. A transform-consumer fusion is invalid unless
all of these semantics are explicit in the descriptor and covered by parity.

### 11.2 Kernel family

The transform library should provide a small measured family rather than one
kernel per proof:

- Radix-2 correctness baseline.
- Radix-4 or radix-8 global passes where register and twiddle costs win.
- Threadgroup-memory fused tails.
- SIMD-group shuffle tails for small stages.
- Sparse-offset and packed-contiguous column variants.
- Consumer variants for leaf absorption, AIR slices, and query gather.

Avoid one enormous fused shader. The planner caps register pressure, live
sources, and threadgroup memory so occupancy is not destroyed by fusion.

### 11.3 Bounded autotuning

At geometry preparation, bounded calibration selects a variant keyed by:

```text
(device registry ID, OS build, metallib hash, direction,
 source log, destination log, batch width, sink kind)
```

Calibration uses the actual transform log, representative batch widths, and a
resident-memory pressure allocation matching the prepared geometry. Tiny
cache-resident buffers are permitted only for correctness filtering. Timed
candidates run under a strict first-use budget; the service never runs a full
SN PIE trial for every choice. Selections are persisted, invalidated by the full
key, and rejected if memory pressure, page-in, or thermal telemetry is unstable.

### 11.4 Witness and relation engine

The witness and relation stages require architectural work of their own. The
5 MHz latency allocation cannot be met by improving transforms and openings
while leaving their current 6.107-second combined cost unchanged.

Base witness execution is prepared by writer archetype, row log, and producer
dependency. Compatible row-local writers share descriptor tables and are
encoded as a bounded batch per topological level. Their output remains in
column-major device storage. Padded-tail generation and the first IFFT stage may
be fused only for writers whose layout and last-consumer rules match; otherwise
the common batched IFFT path consumes the completed columns. Producer feeds are
device references with explicit final consumers, not host copies or permanent
arena allocations.

Writers are classified as native specialized, generated row-local, or
relation-backed. Stable high-cost Cairo builtins receive dedicated families:
EC and Pedersen variants batch common curve operations and inversions across
rows; Poseidon variants keep several permutation states in registers across
rounds; bitwise/range-check/memory writers use packed loads and bounded
histogram/reduction paths where their semantics permit it. This Poseidon work is
trace generation only and does not replace the Blake2s proof commitment. Every
specialized family retains the generated/scalar writer as a component-digest
oracle and is selected by semantic writer ID, never component name alone.

Multiplicity generation keeps the existing global-atomic kernel as the parity
baseline and prepares two additional strategies:

- A tile-local threadgroup histogram followed by a bounded global reduction
  when the key range and threadgroup-memory footprint fit.
- Radix partition or sort-and-reduce for wide or highly contended key ranges
  where atomics serialize.

The planner chooses from measured contention distribution, logical bytes,
atomic count, temporary storage, and end-to-end multiplicity plus witness time.
No strategy is selected from isolated uniform-key microbenchmarks alone.

Relation evaluation batches columns with compatible denominator forms and
emits numerators and denominators in structure-of-arrays layout. Batch inversion
uses a hierarchical product/scan: threadgroup products, a global block-product
scan, and a reverse propagation pass. Running sums consume inverted values in
the same bounded stream and feed interaction interpolation without a host or
full-stage synchronization. Fusion stops before register pressure, scan
barriers, or producer reuse causes more traffic than it removes.

For every writer/relation family, preparation records rows, columns, field
operations, logical bytes, atomics, dispatches, and dependency depth. A change
is retained only when component digests and claimed sums match, peak memory does
not regress beyond the declared budget, the affected full stage improves by at
least 10 percent, and the full proof improves in an A/B/A run. The 0.550-second
base and 0.450-second relation allocations in Section 17 remain feasibility
constraints until roofline lower bounds show they are attainable.

## 12. Phase Dataflow

### 12.1 Transaction reset and input upload

The CPU adapter writes the next `ProverInput` into a shared staging slot. One
ordered GPU pass validates counts, expands pointer/descriptor tables, writes
execution-table seeds, initializes mutable control, and materializes input
columns and padded tails.

Bulk proof state is not CPU mapped. Diagnostic values are reduced to digests or
copied to a bounded readback slot.

### 12.2 Base witness, interpolation, and tree 1

For each topological component or compatible level:

1. Materialize direct input or producer-derived feed data.
2. Run the native or generated base witness writer.
3. Interpolate base evaluations directly into the packed base coefficient bank.
4. Evaluate those coefficients for commitment in a bounded equal-log batch.
5. Feed final LDE values directly into the compact Blake2s leaf state.
6. Produce required subcomponent feeds.
7. Release trace, input, feed, and transform scratch at their last consumer.

Leaf absorption must follow canonical tree column order. If topological witness
order differs, the graph either chooses a canonical dependency-valid order or
uses a bounded readiness schedule before absorption. It does not keep every
base evaluation merely to repair ordering later.

The tree-1 parent reduction follows after all columns are absorbed. Parent
hashing is currently approximately 36 ms across commitments and is not the
primary optimization target.

### 12.3 Relation challenge and interaction tree

After tree 1 is published to the device channel:

1. Draw relation challenges and grind interaction PoW on device.
2. Replay or restore lookup sources according to explicit cost policy.
3. Generate relation denominators and numerators in component batches.
4. Run batched inversion/scan and running-sum construction.
5. Interpolate interaction columns into the packed interaction bank.
6. Evaluate and absorb tree-2 leaves immediately in canonical order.
7. Release lookup, relation-evaluation, and transform scratch.

Relation generation, scan, interpolation, and commitment are separate graph
nodes initially. Fuse them only where a measured producer-consumer boundary
removes a global write without excessive register or threadgroup pressure.

### 12.4 Composition input planning

At `PreparedGeometry` construction, lower every generated AIR part into:

- Exact preprocessed, base, and interaction source columns.
- Source masks and offsets.
- M31 and QM31 parameter dependencies.
- Constraint random-coefficient interval.
- Estimated register and instruction cost.
- Evaluation log and row count.

Build a bipartite graph between AIR parts and source columns. Partition parts by
evaluation log, but do not assume an AIR part can execute from a small set of
raw source columns. The current generated program contains an expression DAG
whose intermediate values are reused within and across constraint cones. Of the
1,325 individual SN2 constraint cones, 561 depend on more than 16 source
columns, and the maximum depends on 272. A cap of 8-16 transformed columns can
therefore be a transform batch size, but cannot be the complete AIR execution
working set.

Naively transforming the exact source dependency set independently for every
AIR part or constraint is also a regression: the terminal LDE output rises from
26.798 GiB on the current component-union plan to 72.263 GiB. The partitioner
must choose AIR DAG cuts, materialize a cost-ranked subset of intermediate-value
columns, and schedule transform batches against consumers. It minimizes:

```text
transform recomputation cost
+ global scratch bytes
+ accumulator read/write passes
+ selected intermediate materialization bytes
+ estimated register spill penalty
```

It preserves canonical random-coefficient and component accumulation order.

Before changing the active full-component path, add an exact pure simulator to
`composition_plan.zig` and run it over all 279 AIR parts for SN1-SN4. It must
model expression-DAG cuts rather than only raw-column incidence. For every
transform batch, retained-intermediate set, fusion cap, and slice order, record
terminal and intermediate transform bytes, repeated transforms, accumulator
read/write bytes, materialized intermediate bytes, mask-halo and circular-wrap
loads, kernel count and code size, peak live bytes, and an estimated
register/spill score. Calibrate transform, accumulator, and intermediate costs
from bounded Metal measurements. M6 proceeds only if the model predicts lower
full-stage time and no more than 2 GiB composition scratch for every PIE;
otherwise revise the cuts and schedule before generating new kernels.

### 12.5 Dependency-minimal composition execution

The first low-risk execution change keeps the current component tile and fuses
multiple compatible AIR parts. It keeps four QM31 accumulator coordinates in
registers across the fused slice and writes the cumulative log-specific
accumulator once. A 4,096-generated-operation cap projects 279 AIR dispatches
to 77 and accumulator traffic from 8.450 GiB to 2.808 GiB, a 5.642 GiB saving.
A 2,048-operation cap projects 105 dispatches and is the safer initial register
pressure experiment. Both require per-component Rust-oracle comparison after
each component, followed by an A/B/A verified full proof.

In parallel, validate and enable the existing upper radix-4 sparse RFFT path as
a typed prepared-plan property. It must pass transform parity across every log,
per-component cumulative-accumulator parity, and interleaved full-proof A/B/A.
Its static arena-traffic projection is materially larger than the fusion-only
accumulator saving, so it precedes a speculative dataflow rewrite.

Only after the exact DAG-cut simulator passes does bounded execution replace
the component tile. Its 8-16 full-LDE-column allocation is a transform batch,
not the whole AIR working set. For each scheduled slice it:

1. Binds retained transformed inputs and selected materialized intermediates.
2. Transforms the next bounded source batch and consumes it into DAG-cut
   intermediates or directly into ready constraints.
3. Remaps canonical identities into compact slice-local slots.
4. Executes several compatible AIR parts or constraint ranges in one generated
   kernel when every dependency is ready.
5. Keeps four QM31 accumulator coordinates in registers across that slice.
6. Writes the cumulative log-specific accumulator once per slice.
7. Releases transformed sources and intermediates at their exact last consumer.

The later transform-consumer implementation fuses final RFFT stages with a DAG
slice whose dependency frontier fits the tile. Values move from threadgroup
memory or registers into cut intermediates or constraint evaluation without a
full global LDE write. It is not implemented as independent per-part transforms,
which the 72.263-GiB counterexample already rules out.

Production groups work aggressively. Diagnostic mode preserves a boundary
after every one of the 58 components and compares a digest of Metal's four
cumulative accumulator coordinates with the Rust oracle. On mismatch, it
narrows to per-part GPU digest and then bounded full-array comparison. This is
the primary iteration loop because it identifies the first semantic divergence
without paying for a complete proof.

### 12.6 Composition finalization and tree 3

The per-log accumulators are lifted into the maximum domain, interpolated, and
split into eight composition coefficient columns. The current finalization
already batches lift, IFFT layers, rescale, and split; production now encodes
that finalization in the same `compositionPrepared` command buffer as the
composition front. Diagnostics retain explicit boundaries for readback.

An optimization experiment should determine whether the canonical tree-3
evaluation can be committed directly from the final lifted composition
evaluation before or while coefficients are produced. It is accepted only if:

- Tree-3 leaf order and root are byte-identical.
- All eight coefficient columns remain correct for OODS and openings.
- Full verified proof parity holds.
- The separate composition commitment LDE is eliminated measurably.

Even if tree 3 is committed directly from the lifted accumulator, coefficient
production cannot simply disappear: OODS and the current opening path still
consume the eight split coefficient columns. The experiment therefore reports
which transform/materialization is removed and which is merely rescheduled.

### 12.7 OODS and quotient

OODS remains a batched device evaluation grouped by `(log size, point set)`.
The statement-derived transcript supplies points and masks. Quotient input
materialization consumes current samples, linear terms, and partials with no
reference payload.

The quotient executes, commits into the first FRI layer, and exposes a
completion/degree-valid gate. A reference digest remains a diagnostic assertion.

### 12.8 FRI

Each FRI round:

1. Folds the current coordinates into the next layer.
2. Feeds the folded output directly into compact leaf hashing where layout
   permits.
3. Retains exactly the values and upper authentication layers required later.
4. Publishes the root and draws the next challenge on device.
5. Aliases dead prior-layer scratch after its commitment/opening obligations
   are satisfied.

FRI is currently small relative to witness, transforms, composition, and trace
decommitment. Preserve its existing parity while removing command boundaries;
do not divert the first architecture pass into local FRI arithmetic tuning.

### 12.9 Query generation

After all commitments and the final FRI polynomial are bound into the channel:

- Grind the query PoW nonce locally.
- Draw query positions at the correct FRI start log.
- Sort and deduplicate mapped positions per source log.
- Build reusable query maps for trace trees and FRI layers.

Query maps remain in a small device control buffer and drive both retained
gathers and pruned transforms.

### 12.10 Retained-or-pruned trace openings

For every trace column group:

- If the required full evaluations were retained, gather query values directly.
- Otherwise execute a query-aware pruned circle RFFT from retained coefficients.
- Build sparse bottom leaf states and lower parents for only the required mapped
  positions.
- Combine them with retained upper Merkle siblings.

A radix-2 pruned transform constructs its active butterfly set backwards from
the requested output positions. It executes only nodes that feed those outputs.
For `k` requested outputs from an `N`-point transform, expected work is roughly
`O(N log k)` rather than `O(N log N)`. This is not `O(k log N)`: arbitrary FFT
outputs still depend on the full coefficient set.

With approximately 70 proof queries and at most 1,120 sparse leaf positions,
the expected transform-work reduction is material but not an order of
magnitude. The initial target is decommit LDE from 2.250 seconds to 0.7-0.9
seconds, subject to exact parity.

The prepared plan computes the exact active butterfly set per log and query map,
including coefficient and twiddle reads, intermediate writes, final gathers,
and sparse-hash work. Each trace group receives a measured choice among retained
full evaluations, pruned evaluation, and the full-LDE oracle. The 0.7-0.9-second
range is a target, not a derived forecast, until the summed per-group model and
targeted Metal measurements support it.

Prototype order:

1. Tree 3, which has eight equal-log composition columns.
2. Tree 2 interaction groups.
3. Tree 1 base groups.
4. Tree 0 only if immutable retained data does not already cover it.

### 12.11 Proof assembly, readback, and verification

The GPU writes the compact proof into a bounded shared output slot and signals
completion. The CPU:

1. Validates output length, status, statement digest, and error fields.
2. Copies or transfers ownership of the compact proof bytes.
3. Runs the resident cryptographic verifier against the independently derived
   statement.
4. Runs canonical Rust cross-verification for SIMD-prover compatibility when
   the request or acceptance suite selects `zig_and_rust_acceptance`.
5. Atomically publishes proof and report only after verification succeeds.

After compact output is detached from the proof workspace, the GPU may begin
the next transaction while CPU verification completes, provided ordered
publication and fail-closed queue behavior are preserved.

### 12.12 Canonical Rust cross-verification contract

Rust verification is an independent acceptance implementation, not a call back
into Zig and not an input to proof generation. The service owns a pinned
`RustVerifierConfig` containing source revisions, executable SHA-256, semantic
version, envelope ABI, argv template, timeout, and resource limit.

More precisely, it pins both the `stwo-cairo` and Stwo revisions and the
adapter's `Cargo.lock` SHA-256. The lockfile and measured binary are included in
the artifact manifest and the exact identity is emitted in `ready`. Those two
manifest entries are currently classified as `unattested`, so this measurement
pin is not yet a deployment allowlist or a complete source chain. The
repository contains a fail-closed adapter at
`tools/stwo-cairo-verifier-rs`. It implements strict STWZCVE/1 framing, bounded
lengths, exact section order, reserved and mandatory-flag checks, SHA-256
authentication, source/executable/lockfile identity reporting, direct-argv
configuration, and atomic no-replacement result publication. Its complete-JSON
path reconstructs `CairoProofForRustVerifier` and calls pinned canonical
`verify_cairo`. Its compact path constructs typed `PublicData`, inverts all 83
base-claim slots into `CairoClaim`, enforces fixed logs and the contiguous
16-slot memory-big prefix, derives the memory-big aggregate interaction sum,
constructs `CairoInteractionClaim`, and re-flattens both typed claims for exact
comparison. It derives the sampled-value shape from pinned `CairoComponents`,
reconstructs all commitments, trace openings, FRI layers, Merkle witnesses,
decommitments, the final line polynomial, nonces, and fold-3 PCS configuration,
then calls canonical `verify_cairo` with panic-to-error containment. The
canonical verifier is a Rust CPU verifier; “SIMD”
describes the prover lineage whose proofs it checks, not a SIMD verification
implementation.

The audited canonical checkout is
`/Users/theodorepender/code/personal/stwo-cairo`, branch `generic-backend`, at
commit `dcd5834565b7a26a27a614e353c9c60109ebc1d9`. Its declared Stwo revision is
`9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2`. The upstream
`stwo_cairo_prover/crates/dev_utils/src/bin/verify.rs` calls
`verify_cairo::<Blake2sMerkleChannel>()`, but accepts only a complete serde JSON
`CairoProofForRustVerifier`; it cannot consume the Zig compact proof. The
repository adapter is isolated from enclosing workspace patches and uses exact
Git revisions plus a checked lockfile. Protocol v4 copies the measured release
executable and lockfile into its private store, remeasures both, and rejects
mutation. Deployment authorization and complete generator/source provenance
remain separate production gates.

The existing JSON verifier can still be used as a diagnostic reference:

```sh
cd /Users/theodorepender/code/personal/stwo-cairo/stwo_cairo_prover
cargo build --release --locked -p stwo-cairo-dev-utils --bin verify
target/release/verify \
  --proof_path /private/tmp/SN_PIE_2.fold3.reference.proof.json \
  --channel_hash blake2s
```

The older reference-JSON verification was approximately 30.5 ms total, with
12.2 ms inside `verify_cairo`. The compact path now has the relevant
end-to-end adapter measurement described below; the older number remains only
an API baseline.

The implementation in `tools/stwo-cairo-verifier-rs` uses exact-revision Git
dependencies, decodes authenticated payloads into the existing Rust types, and
calls the canonical verifier; it does not reimplement Cairo verification. The current compact
`resident_sn2_bundle_v1` is little-endian `u32` words in this order:

1. Four 32-byte commitments.
2. Flattened interaction claimed sums.
3. Interaction PoW nonce.
4. Flattened sampled values.
5. Eight FRI commitments.
6. Final line polynomial.
7. Query PoW nonce.
8. Versioned decommitment assembly.

Those bytes do not contain a complete public statement, component enables and
log sizes, preprocessed variant, channel/PCS configuration, section framing, or
authenticated provenance. Transcript ordinals 15 and 16 contain only
output/program roots respectively; Rust needs the actual public program and
output values to compute public LogUp data and check the statement. Feeding
Rust a reference JSON claim is useful only as a decoder-development oracle and
can never pass M1.

The v1 decoder is deliberately fixed to the current corpus shape: four
commitments, four sampled trees with 161/3449/2268/8 columns, twelve
decommitment records, eight FRI layers, and one final QM31 coefficient. A
different shape requires a new authenticated layout version, not a permissive
best-effort parse.

The interchange object is `STWZCVE/1`, a length-delimited binary envelope with:

- Canonical PCS and protocol parameters.
- Canonical statement bytes and their SHA-256.
- Compact proof bytes, length, and SHA-256.
- Adapted-input and artifact-manifest digests.
- Backend ABI and proof serialization version.

The envelope has fixed magic `STWZCVE\0`, version 1, explicit little-endian
lengths, reserved-zero fields, and four mandatory uniquely typed sections:

| Section | Required contents |
| --- | --- |
| `protocol` | Blake2s channel, canonical preprocessed variant, salt, blowup 1, 70 queries, 24-bit interaction PoW, 26-bit PCS/query PoW, fold step 3, `lifting=None`, `log_last_layer_degree_bound=0`, and every compact-layout word count |
| `statement` | Initial/final Cairo states, eleven public segment ranges, safe-call IDs, complete program/output `(id,[u32;8])` entries, 83 component-enable bits, and active component log sizes in canonical flatten order |
| `proof` | Exact compact bytes, byte length, serialization identifier, and SHA-256 |
| `provenance` | Statement, adapted-input, artifact-manifest, protocol, runner/backend ABI, and proof-serialization digests |

The decoder rejects duplicate or missing sections, unknown mandatory flags,
nonzero reserved fields, integer or allocation overflow, trailing bytes,
noncanonical M31 limbs, invalid section counts, and every digest mismatch before
constructing a Rust proof object.

The adapter implementation sequence is explicit. All eight steps are
implemented and covered by 33 library tests plus four CLI tests:

1. Decode and authenticate `STWZCVE/1` under bounded allocation limits.
2. Construct typed `PublicData` and the canonical preprocessed trace variant.
3. Invert `CairoClaim::flatten_claim` using a version-pinned explicit 83-slot
   component table/macros, validating fixed-log and active-log invariants. No
   inverse component registry exists in the audited Rust code.
4. Invert `flatten_interaction_claim` from compact sums; for
   `memory_id_to_big`, treat `big_claimed_sums` as the active prefix and derive
   the absent `claimed_sum` as their sum.
5. Translate compact commitments, samples, FRI data, nonces, and decommitments
   exactly as Zig `resident_verifier.zig::decodeProof` does.
6. Construct `CairoProofForRustVerifier<Blake2sMerkleHasher>`.
7. Re-flatten the base claim and compare it with the envelope statement; then
   re-flatten the interaction claim and compare it with the compact interaction
   words.
8. Call `verify_cairo::<Blake2sMerkleChannel>`, catch panics as structured
   failures, and atomically emit the result JSON.

The adapter's clean build and identity gate is:

```sh
cargo test --locked \
  --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml
cargo build --release --locked \
  --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml \
  --bin stwo-cairo-verifier-adapter
shasum -a 256 \
  tools/stwo-cairo-verifier-rs/target/release/stwo-cairo-verifier-adapter
```

The bring-up diagnostic combined the existing Rust reference statement with
the actual reference-free SN2 compact proof. The 8,410,304-byte proof with
SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`
reconstructed and passed canonical `verify_cairo`. The optimized adapter
reported 68,951,334 ns for envelope decoding, typed reconstruction, and
verification. Its release executable SHA-256 was
`aa9684a92768c8691ef1d9506bde0d01e84bd997742b5877cd8ed20cdd58ac82`.
An offline rerun of the same diagnostic proof during the protocol-v4 wrap-up
reported 34,612,959 ns with the same executable, protocol, statement, proof,
and provenance digests. These are CPU adapter timings, not Metal MHz.

The original diagnostic establishes compact proof equivalence, not production provenance. The
diagnostic statement was serialized from the reference verifier JSON and the
external adapted-input/manifest/runner/backend identity fields were explicit
placeholders. Protocol v4 no longer uses those placeholder identities in the
live service path; it supplies the Zig-owned statement and real adapted-input,
manifest, runner, backend, protocol, and proof digests. The remaining release
gate is authenticated source-chain provenance plus live SN1-SN4 coverage.

The producer-side part of that release gate is implemented. Zig
`statement_bootstrap.encodeCompactStatementV1` serializes the public states,
eleven segment ranges, safe-call IDs, complete program/output memory entries,
83 enable bits, and active logs directly from the same `ProverInput` and
composition schedule that seed the transcript. For SN2 it emitted exactly
157,032 bytes with SHA-256
`36c41bd4fd5bb256dcef94d15084e46dc1c30c1b99f82de1036162dfb9fb2623`,
byte-identical to the independently encoded Rust statement. The live
`metal-arena-plan` path exposes this through the exclusive
`STWO_ZIG_SN2_COMPACT_STATEMENT_OUTPUT` hook. The persistent session consumes
the same serializer directly, derives the compact protocol from the runner's
reported layout, streams `STWZCVE/1` from private statement/proof files, and
binds real provenance without the reference JSON.

The verification lane creates a per-request private `0700` scratch directory,
writes proof, statement, runner report, envelope, and result files there, and
invokes an argv array directly, never through a shell:

```text
<pinned-rust-verifier> verify
  --envelope <exclusive-STWZCVE/1-path>
  --result <exclusive-result-json-path>
```

The result schema contains the verifier executable and lockfile digests, pinned
`stwo-cairo` and Stwo revisions, statement digest, proof digest, protocol
digest, verification boolean, wall time, and structured error. Acceptance
requires exit zero, `verified=true`, and
exact equality of every digest with the envelope and Zig result. Timeout,
signal, nonzero exit, malformed output, unexpected file replacement, or digest
drift is a verification failure. The service terminates the verifier process
group after a 30-second timeout, gives it a two-second termination grace, reaps
it exactly once, and publishes no proof or report on failure. Rust acceptance
precedes prepared-state commit and exclusive proof/report publication.

Both verifier outcomes enter `VerifiedBlockResult`. Resident Zig verification
and canonical Rust verification are both mandatory in the current protocol-v4
implementation. A future resident-only deployment policy would require an
explicit protocol and acceptance change; it is not an available v4 mode.
Rust wall time is reported separately and does not alter Metal prove-only MHz.
When Rust is required, block-service and sustained-queue wall include it, with
CPU verification of block n-1 permitted to overlap GPU proving of block n.

## 13. Evaluation Retention Planner

### 13.1 Why retention is selective

Commitment evaluates every trace column before query positions exist.
Composition later needs many of the same evaluations. Decommitment later needs
only queried evaluations. Retaining every commitment evaluation would exceed
the memory budget, while retaining none causes repeated transforms.

### 13.2 Candidate model

Each equal-log column group records:

```zig
pub const RetentionCandidate = struct {
    group: ColumnGroupId,
    bytes: u64,
    retain_first_node: u32,
    retain_last_node: u32,
    commitment_transform_ms: f64,
    composition_reuse_count: u32,
    decommit_full_transform_ms: f64,
    pruned_transform_ms: f64,
};
```

Its estimated saved time is:

```text
composition transform savings
+ max(0, decommit full/pruned transform savings)
- extra copy or placement cost
```

The planner selects candidates by saved milliseconds per peak-live byte while
respecting interval overlap at every graph node. A simple byte-only knapsack is
invalid because a retained value consumes capacity throughout its lifetime.

### 13.3 Per-PIE policy

SN4 currently has roughly 6.19 GB between its planned arena and device buffer
cap. SN1 has only roughly 0.90 GB. Therefore:

- The baseline must work with zero retained full evaluations.
- Composition scratch reduction comes before broad retention on SN1.
- Freed scratch capacity can then be reinvested in the highest-value retained
  groups.
- Retention policy is geometry-specific and reported in every benchmark.

## 14. Streaming Queue Architecture

### 14.1 Serial GPU, overlapped CPU

The queue has three logical lanes:

```text
CPU lane A: execute/adapt block n+1
GPU lane:   prove block n
CPU lane B: verify and publish block n-1
```

The GPU lane is serial because the coefficient floor and scratch envelope make
two simultaneous proof workspaces counterproductive on a 64 GB system.

Only these resources are double-buffered initially:

- Adapted-input staging, approximately 271 MB for SN4.
- Compact transaction control.
- Compact proof output, approximately 8.4 MB for current proofs.

Queue depths match Section 7.2: two raw requests, two adapted inputs, one GPU
transaction, and at most one speculative proof beyond ordered verification.
Backpressure stops new adaptation before it exceeds those bounds. Cancellation
terminates queued adapter process groups, removes staging files, and never
reuses a mutated GPU resource set without reset. A geometry switch reports plan
lookup, immutable eviction/upload, descriptor rebinding, and first-use pipeline
cost rather than hiding them in proof wall.

Sustained throughput is always:

```text
sum(adapted cycles for verified published blocks) / clean queue wall / 1e6
```

At steady state it is bounded by the slowest of adaptation, serial GPU proving,
and ordered verification/publication, with measured unified-memory contention
included. Lane overlap is retained only when full-queue wall improves and
prove-only wall does not regress materially.

### 14.2 Four-entry logical geometry cache

The local service can hold at least four compact `PreparedGeometry` plans for
SN1-SN4 within a byte budget. This does not imply four multi-gigabyte immutable
device states or workspaces are resident simultaneously.
The key includes:

- Content hashes of all statement-independent semantic artifacts.
- Exact component order and real/padded row extents.
- PCS and FRI parameters.
- Packed bank layout and placement plan hash.
- Device registry ID, supported GPU family, OS build, and metallib hash.
- Backend ABI and graph schema versions.

Statement values, roots, challenges, and nonces do not belong in this cache key.
They are transaction control data.

### 14.3 Immutable device cache

Preprocessed coefficients/evaluations, tree-0 retained layers/root, and twiddle
banks use a separate content key independent of mutable arena placement. A
geometry entry references them through region-qualified descriptors.

For a previously verified object in the service-owned content store, an exact
content hit performs zero disk reads, zero host uploads, and zero tree-0
recomputation. It is not called a hit merely because the source path matches.

### 14.4 Failure semantics

- The first failed request stops ordered publication.
- No proof or MHz is emitted for an unverified request.
- A GPU mutation failure marks the active resource set dirty.
- Reuse after failure requires the complete prepared reset/poison path.
- Speculatively computed later proofs are discarded if an earlier proof fails.
- Output files are published atomically and exclusively.

## 15. Debug and Parity Architecture

Production and diagnostic modes use the same arithmetic kernels and graph
descriptors. Diagnostic mode adds checkpoints; it does not provide production
inputs.

### 15.1 Required checkpoints

| Boundary | Diagnostic comparison |
| --- | --- |
| Statement | Serialized transcript ordinals and claim digest |
| Base components | Per-component coefficient and cumulative leaf digests |
| Tree 1 | Leaf-state checkpoints, retained layers, exact root |
| Relation | Challenges, claimed sums, relation output digest |
| Interaction components | Per-component coefficients and running sums |
| Tree 2 | Leaf-state checkpoints and exact root |
| Composition components | Four-coordinate cumulative accumulator digest |
| Tree 3 | Composition coefficients, leaf state, exact root |
| OODS | Points, masks, samples, transcript payload |
| Quotient | Input digest, output digest, selected rows |
| FRI | Eight roots, challenges, final coefficients and degree |
| Queries | Nonce, positions, mapped/deduplicated indices |
| Openings | Values, sparse leaves/parents, authentication siblings |
| Proof | Decoded fields and cryptographic verification |

### 15.2 Fast parity loop

The default composition bring-up loop is:

1. Execute one Metal component into the cumulative accumulator.
2. Compute a GPU digest for four coordinates.
3. Compare it with the canonical Rust/current-Metal oracle.
4. On the first mismatch, enable per-part digests for that component.
5. On the first mismatched part, read back only the bounded affected rows or
   full accumulator needed to locate the arithmetic difference.

Production removes these waits and digest readbacks. This preserves the fast
correctness loop without making component synchronization part of the final
architecture.

### 15.3 Retained old paths

Keep these opt-in diagnostic oracles until the replacement passes all four PIEs:

- Full component-wide composition LDE path.
- Full trace decommit LDE path.
- Full-log leaf-state commitment fallback.
- Forced reference nonces and exact transcript comparisons.
- Current single-buffer Shared resource mode for focused A/B tests.

No old path may be selected silently in a production benchmark.

## 16. Profiling and Observability

### 16.1 Async-safe profiler

Before command-graph conversion, profiler finalization moves from synchronous
wait interception to Metal command-buffer completion handlers. The profiler:

- Assigns proof, block, graph, stage, component, node, and operation IDs.
- Records absolute CPU and GPU timestamps.
- Records queue gaps and stage spans.
- Tracks expected and observed encoder timestamp coverage.
- Buffers events in an in-memory ring.
- Writes NDJSON from a background writer after the measured hot path.
- Reports dropped events and ring overflow as strict failures.

The disabled profiler path remains allocation-free and uses the original queue
without proxies.

### 16.2 Accounting gates

A full command-only profile is acceptable when:

- The proof verifies.
- At least 95 percent of proof wall is assigned to measured GPU queue occupancy,
  queue gaps, verifier, preparation, or publication/I/O spans; residual is at
  most 5 percent and is reported separately.
- Every command has a stable operation ID and completion status.
- The profiler adds no more than 2 percent to a representative verified run.
- No page-in or memory-pressure anomaly invalidates the run.

Coverage is computed as a non-overlapping wall-clock interval union, partitioned
into GPU queue occupancy, CPU preparation, CPU verification, publication/I/O,
explicit queue gaps, and residual. Residual completes the partition but does
not count as measured coverage. Hierarchical stages explain occupied GPU
intervals but are never added again to the coverage numerator. Overlapping CPU
lanes are reported independently and as a union, so concurrent adaptation and
verification cannot exceed 100 percent wall coverage.

Encoder counters remain limited to bounded targeted workloads unless the full
capture is shown not to perturb residency.

### 16.3 Roofline measurements

Because public counters do not expose occupancy or bandwidth, create bounded
device-specific baselines for:

- Sequential M31 buffer read/write bandwidth by storage mode and buffer size.
- M31 add, multiply, inverse, and QM31 arithmetic throughput.
- Circle IFFT and RFFT by log, batch width, and sink.
- Blake2s leaf absorption by columns and row log.
- Generated AIR instruction throughput and register-pressure variants.
- Pruned RFFT by `N`, query count, and query distribution.

Every graph node estimates logical bytes read/written and arithmetic operations.
Compare its observed time with measured device baselines. If the 5 MHz budget
requires more bandwidth or arithmetic throughput than the bounded baselines,
the decision becomes algorithmic change, more hardware, or a revised target,
not speculative kernel tweaking.

Full Xcode Metal System Trace should later add occupancy, cache, residency, and
memory-system evidence. It supplements, rather than replaces, verified MHz.

No new MHz forecast is promoted from hypothesis until node-level byte/op
accounting, adaptation and verifier baselines, pressure/page-in checks, stable
thermal context, and a causal full-proof A/B/A measurement are present. The
roofline result is an architecture decision gate in M4-M8, not optional
post-hoc explanation.

### 16.4 Safe capture and report procedure

The current public profiler is disabled unless
`STWO_ZIG_METAL_PROFILE_OUT` names an output. With only that variable it records
command-buffer timelines and is the only permitted full SN PIE capture mode.
`STWO_ZIG_METAL_PROFILE_ENCODER_COUNTERS=1` allocates timestamp sample buffers
and may materially perturb wide-arena residency; use it only on bounded kernel
benchmarks until a controlled experiment proves otherwise.

Run a bounded encoder-counter smoke as follows:

```sh
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-bench -Doptimize=ReleaseFast
STWO_ZIG_METAL_PROFILE_OUT=/private/tmp/metal-smoke.ndjson \
STWO_ZIG_METAL_PROFILE_ENCODER_COUNTERS=1 \
  zig-out/bin/metal-bench --columns 16 --log-size 12 --repetitions 1
python3 scripts/metal_profile_report.py \
  /private/tmp/metal-smoke.ndjson --strict \
  --json-out /private/tmp/metal-smoke.report.json
```

For one full proof, run the same reference-free gate with only command-buffer
profiling enabled:

```sh
STWO_ZIG_METAL_PROFILE_OUT=/private/tmp/sn2-command-only.ndjson \
  python3 scripts/sn_pie_metal_benchmark.py \
  --input /private/tmp/SN_PIE_2.generic.stwzcpi \
  --mode full-proof --runner zig-out/bin/metal-arena-plan \
  --schedule /private/tmp/sn2-arena.json \
  --budget-gib 29 --timeout 300 \
  --preprocessed-evaluations \
    /private/tmp/stwo-zig-sn2-preprocessed-evaluations.spill \
  --preprocessed-coefficients \
    /private/tmp/stwo-cairo-canonical-preprocessed.stwzppc \
  --tree0-root-hex \
    a98e22423bf5d235981f0b36d939ae56ef3be2751c58b032b2831e6e24ba0364 \
  --proof-output /private/tmp/sn2-profiled.proof \
  --stderr-output /private/tmp/sn2-profiled.stderr \
  --output /private/tmp/sn2-profiled.json
```

Then validate the stream:

```sh
python3 scripts/metal_profile_report.py \
  /private/tmp/sn2-command-only.ndjson --strict \
  --json-out /private/tmp/sn2-command-only.report.json
```

Strict mode rejects command errors, profiler configuration errors, unavailable
counter buffers, counter-capacity overflow, and missing encoder timestamp pairs
when encoder counters are enabled. The default encoder sample capacity is 1024
and may be changed with `STWO_ZIG_METAL_PROFILE_MAX_ENCODERS`, but raising it is
not permission to use counters on a wide proof. Use one wide process at a time,
confirm memory pressure and swaps before and after, and let the machine return
to a stable thermal/memory state. Profiled proof MHz remains diagnostic; compare
the same build and input in a separate unprofiled verified A/B/A run.

## 17. Performance Budget

### 17.1 Necessary 5 MHz latency allocation

SN4 has 14,328,780 adapted cycles. A 5 MHz verified proof must complete in:

```text
14,328,780 / 5,000,000 = 2.865756 seconds
```

One possible necessary latency allocation is:

| Category | Current SN4 | 5 MHz budget | Required reduction |
| --- | ---: | ---: | ---: |
| Base witness and interpolation | 3.564 s | 0.550 s | 6.5x |
| Relation, interaction witness, interpolation | 2.543 s | 0.450 s | 5.7x |
| Trace commitments | 2.333 s | 0.450 s | 5.2x |
| Composition | 3.581 s | 0.550 s | 6.5x |
| Trace openings | 2.311 s | 0.350 s | 6.6x |
| Quotient, FRI, transcript, other GPU | approximately 0.19 s | 0.120 s | 1.6x |
| Verification, submission, I/O, remaining residual | approximately 5.00 s | 0.396 s | 12.6x |
| Total | 19.519 s | 2.866 s | 6.8x |

This is not a feasibility model or forecast. A stage becomes feasible only when:

```text
stage lower bound = max(
    logical bytes / measured sustainable bytes per second,
    field operations / measured sustainable field operations per second,
    protocol and kernel dependency-chain latency
)
```

The lower bounds, plus measured efficiency margins and unavoidable serial
dependencies, must sum below 2.865756 seconds before 5 MHz can be described as
architecturally feasible. Until then it is a research target. The allocation
still proves that 5 MHz cannot come from persistence, command batching, or one
fused kernel alone: it requires repeated-transform removal, much faster witness
and relation execution, and very low orchestration/verification cost.

### 17.2 Non-double-counted performance waterfall

The current 14.520-second non-overlapping GPU total alone limits SN4 to about
0.987 MHz even if the entire 4.999-second residual disappeared. Oracle removal
also adds self-grinding work. Reference-free SN2/SN3 measured roughly
0.81-0.91 seconds for the two isolated CPU searches, but no reference-free SN4
distribution has been measured, so it is not valid to forecast SN4 by either
subtracting fixture overhead or inserting one sampled PoW time.

| Scenario | Non-overlapping wall construction | Result/status |
| --- | --- | --- |
| Current warm SN4 | 19.519 s verified prove wall | 0.734 MHz measured |
| Current GPU work with zero residual | 14.520 s GPU | 0.987 MHz mathematical upper bound, not achievable proof wall |
| Best immediate stage targets, residual 1.5 s | 3.564 base + 2.543 relation + 1.4 commitment + 1.5 composition + 0.7 openings + 0.19 other + 1.5 residual = 11.397 s | 1.257 MHz conditional hypothesis |
| Same stages, residual 0.396 s | 10.293 s | 1.392 MHz conditional hypothesis |
| 2 MHz | Total must be at most 7.164 s | Requires base, relation, and residual reductions beyond immediate targets |
| 5 MHz | Total must be at most 2.866 s | Blocked on measured lower bounds |

Future waterfall rows must identify baseline time, independently removable
time, dependencies on other changes, expected range, confidence, and the
verified exit measurement. Effects are never added when they remove the same
command, transform, materialization, or residual interval. Values remain
labelled hypotheses until an unprofiled verified proof replaces them.

### 17.3 Immediate stage targets

The first architecture pass uses these directional gates:

- M4a transition: fewer than 100 command buffers for commitment and decommit
  combined, with no waits inside those stages.
- M4 exit: at most eight command buffers for the entire production proof, zero
  intermediate CPU waits, and encode/submit plus queue-gap gates from Section 10.
- No more than one synchronous wait in the production proof graph.
- Residual classified and reduced below 1.5 seconds.
- Base witness plus interpolation and relation plus interaction each improve by
  at least 10 percent in their first retained architecture pass; later targets
  are set from their measured roofline bounds.
- Decommit LDE reduced from 2.250 seconds to 0.7-0.9 seconds.
- Composition reduced from 3.581 seconds to 1.5-2.0 seconds.
- Composition scratch reduced from 11.125 GiB to at most 2 GiB.
- Commitment reduced from 2.333 seconds toward 1.4-1.7 seconds.
- One-proof physical footprint reduced toward 25-29 GiB.

## 18. Delivery Plan

Milestones are ordered by product risk, not by how locally attractive a kernel
optimization appears. The critical dependency chain is:

```text
M0 truthful evidence
  -> M1 reference-free protocol execution
  -> M2 raw-derived statement and geometry
  -> M3 reusable production service
  -> M4 compiled asynchronous command graph
  -> M5 explicit resource architecture
  -> M6 bounded commitment/composition dataflow
  -> M7 pruned openings
  -> M8 sustained tuning and queue acceptance
```

M4 profiler work can start beside M1-M3, and M6 dependency analysis can start
beside M4-M5, but neither branch may publish a production throughput claim
before the preceding correctness and provenance gates pass. Every performance
change follows `oracle checkpoint -> isolated A/B -> full proof -> mixed queue`.

### M0: Truthful production reporting

Implementation:

- Add complete PIE member/archive, adapter, bootloader, artifact, and statement
  digests.
- Emit the canonical artifact manifest and derive provenance booleans inside the
  service rather than accepting caller assertions.
- Report adapter implementation explicitly.
- Add `self_contained`, `parity_fixture_used`, and
  `proof_derived_artifact_used` fields.
- Make production queue acceptance fail if any forbidden dependency is true.
- Preserve pipeline cache deltas in per-block and queue summaries.

Exit gate:

- Existing proofs still verify in diagnostic mode.
- The current proof-derived-artifact path reports production acceptance false,
  whether optional parity fixtures are present or absent.
- Artifact mutation with preserved size/mtime is detected.

Current status: substantially active. Content-based directory identity,
fail-closed queue provenance, complete-only pipeline-cache aggregation,
authoritative one-shot runner provenance, and a complete byte/hash artifact
manifest are implemented. The manifest deliberately labels unattested adapted
inputs, schedules, and semantic artifacts as `proof_derived`; authenticated
adapter/bootloader/source chains remain open. Service-native statement identity
and digest binding are active. The persistent result/report now promote and
strictly validate report schema v3 over session protocol v4, the canonical
protocol, complete manifest, exact artifact-object map, in-process executable
identity, mandatory Rust-verifier evidence, and provenance fields. Production queue
acceptance rejects incomplete or forbidden evidence. The current repeated-SN2
queue is therefore correctly `verified_diagnostic`: its evidence objects are
complete, while proof-derived source chains keep production acceptance false.

### M1: Oracle-free proof

Implementation:

- Integrate the existing canonical statement serializer as the authoritative
  prover and verifier bootstrap.
- Self-grind interaction and query nonces with a persistent CPU worker pool and
  retain the implemented separate cost telemetry.
- Require OODS before quotient.
- Gate quotient on execution/completion instead of reference parity.
- Gate FRI on completion and final-degree validity.
- Make transcript, quotient, and FRI comparisons optional diagnostics.
- Complete and pin the existing fail-closed `STWZCVE/1` Rust verifier scaffold.

Exit gate:

- SN1-SN4 prove with reference files absent.
- Every proof passes resident and canonical Rust verification.
- Parity mode still reproduces exact checkpoints with forced nonces.

Current status: in progress with reference-free SN2 and SN3 passing resident
verification. The statement serializer is wired into the runner, diagnostic
comparison is non-mutating, transcript and quotient references are optional in
one-shot, Python, queue, and JSONL paths, and both PoW stages self-grind when
diagnostic nonces are absent. Interaction and query PoW now have separate scope,
mode, bits, invocation, nonce, and wall-time telemetry. SN2 has also passed the
strict persistent transport and clean shutdown. The real compact SN2 Metal
proof also reconstructs and passes canonical Rust verification. Zig-owned
statement/provenance envelope production and mandatory verifier invocation are
implemented in protocol v4. Remaining exit work is a bounded live v4 SN2,
reference-free SN1 and SN4, a reusable CPU PoW worker pool, and canonical Rust
cross-verification for the full corpus. Reference-free here does not imply M2
self-containment.

### M2: Raw-derived geometry and statement-independent kernels

Implementation:

- Derive schedules and geometry from `ProverInput` and AIR metadata.
- Remove target-proof input from schedule/composition generation.
- Move statement constants out of generated Metal source.
- Content-address semantic kernels and geometry descriptors separately.
- Produce versioned AOT metallibs and shader manifests; forbid generated-source
  compilation on the production proof path.

Exit gate:

- Fresh raw SN1-SN4 inputs execute, adapt, prepare, prove, and verify with no
  target proof or proof-derived semantic artifact.
- Changing a public segment or claim changes statement/control data without
  requiring an unrelated AIR source recompile.

### M3: True persistent service

Implementation:

- Extract `MetalProverService`, `ArtifactCache`, `PreparedGeometry`, immutable
  device cache, and reusable resource set from the CLI.
- Implement the bounded asynchronous submission/state-machine API.
- Replace environment configuration with typed request fields.
- Implement reset ranges, poison mode, and dirty recovery.
- Hold four compact logical geometry entries for SN1-SN4 within a byte budget.
- Enforce the exclusive device lease and process-wide memory admission policy.

Exit gate:

- A/B/A reproduces both A proofs semantically and cryptographically.
- Runtime, geometry, resources, and compatible immutable state report reuse.
- Repeated geometry performs zero artifact parsing, plan construction,
  preprocessed disk reads, and preprocessed uploads.
- The randomized 10-block queue verifies.

Current status: protocol-v4 `ArtifactStore`, `ViewCache`, and a capacity-one
transactional `PreparedStateCache` are active. The latter reuses the resident
arena, compact immutable preprocessed snapshot, and canonical full-proof
physical arena plan after a full GPU reset; the second SN2 request reports all
applicable hits and preserves exact proof bytes. The multi-second warm plan
build is 0.026940083 seconds in the latest pair. Parsed schedule/bundles are
host-geometry-owned, while fixed-table, multiplicity-feed, both AOT, and three
compact recipes are resident-owned and reused. Request proof bindings,
proof/liveness metadata, interpolation recipes, and the remaining prepared
recipe/graph objects are still rebuilt. The measured warm pre-prove interval is
now 0.401039750 seconds. The immutable host plan is
in a transactional capacity-four LRU while only one wide proof workspace is
resident. Its initial live integration exposed and then repaired an ownership
transfer regression; the repaired cold/warm SN2 pair verifies. Focused A/B/A,
capacity, poison, key, noncanonical, and post-transfer binding tests pass. The
parsed host entry and physical-plan entry are still separate caches rather than
one complete `PreparedGeometry`; proof bindings and several recipes are not yet
part of either. Mixed live-Metal A/B/A,
injected-failure recovery,
byte-budgeted full-geometry admission, and the randomized 10-block gate remain
open.

### M4: Async profiler and compiled command graph

Implementation:

- Make profiler completion-handler based and add stable span IDs.
- Convert runtime helpers to prepare/encode APIs.
- Compile explicit resource accesses and barriers into a proof graph.
- Batch current component/column operations into bounded command streams.
- Move 24-bit and 26-bit PoW to deterministic bounded GPU search windows.

Exit gate:

- Production has one final synchronous wait.
- Production uses at most eight command buffers total; the `<100`
  commitment/decommit threshold is a reported transition gate, not completion.
- Encode plus submit time and queue-idle gaps are each below 3 percent of wall.
- At least 95 percent accounting coverage and at most 2 percent profiler
  overhead.
- Node byte/op/dependency lower bounds and stable pressure/thermal evidence are
  recorded before any new MHz forecast.
- Exact proof parity and no more than 5 percent memory growth.
- At least 10 percent verified full-proof wall improvement.

Current status: the composition epoch is the first scoped prepare/encode
conversion. Production front and finalization share one command buffer and one
wait through `compositionPrepared`; diagnostic boundaries remain. Repeated SN2
is byte-identical and verified, while composition remains 2.392 seconds. The
full-proof command count, asynchronous profiler, stable IDs, bounded GPU PoW,
and M4 exit gates remain open.

### M5: Multi-buffer resources and packed coefficient banks

Implementation:

- Introduce `DeviceRef` and `ArenaViews`.
- Move immutable and coefficient banks out of the mutable arena.
- Pack coefficients by tree/log/canonical ordinal.
- Introduce tracked Private scratch heaps and small Shared I/O rings.
- A/B each phase against the Shared path.

Exit gate:

- No single buffer depends on crossing the 16 GiB narrow word range.
- No full proof data structure requires CPU mapping.
- Peak physical footprint trends toward 25-29 GiB.
- Total service residency, not single-buffer capacity, satisfies the admission
  budget with adapter/verifier and system reserve included.
- Private/heap migration is retained only where measured phase or system
  behavior improves without parity or memory regression.

### M6: Consumer-driven commitments and composition

Implementation:

- Route base/interaction transform output into compact leaf absorption.
- Validate the existing upper radix-4 sparse RFFT path across all active logs.
- Fuse bounded multi-part AIR slices with register-resident accumulation.
- Build exact AIR expression-DAG cut metadata and a cost simulator.
- Simulate all 279 AIR parts and reject plans whose transform, intermediate,
  accumulator, halo, code-size, or spill model does not predict a net win.
- Use 8-16 transformed columns only as a transform batch, with selected
  intermediate materialization to satisfy wider dependency cones.
- Add cost-ranked evaluation retention.

Exit gate:

- All per-component accumulator digests match.
- All four commitment roots match.
- Composition scratch is at most 2 GiB.
- At least 30 percent fewer materialized bytes in the affected stages.
- Composition and commitment meet the first-stage targets in Section 17.3.

### M7: Pruned openings

Implementation:

- Build per-log deduplicated query maps.
- Build exact active-butterfly and byte/op models per trace group.
- Implement pruned radix-2 circle RFFT and batched query gather.
- Integrate retained-or-pruned selection.
- Reuse the current sparse leaf/parent authentication assembly.

Exit gate:

- Query values, sparse hashes, siblings, and proof payload match the full-LDE
  oracle for SN1-SN4.
- Decommit LDE reaches 0.7-0.9 seconds or a measured lower-bound report explains
  why it cannot.
- Full verified proof improves, not just isolated opening time.

### M8: Sustained service and transform tuning

Implementation:

- Add bounded transform autotuning.
- Overlap adaptation n+1, GPU proof n, and verification n-1.
- Run randomized 10- and 100-block queues.
- Add failure injection, plateau, p50/p95, and thermal/resource telemetry.

Exit gate:

- 100/100 proofs verify with no restart or fallback.
- No warm compile, artifact read, recipe build, or immutable upload.
- Last-20 memory and Metal allocation remain within 2 percent of the warm
  plateau and under budget.
- Warm sustained service MHz is at least 90 percent of aggregate warm
  prove-only MHz unless measured CPU adaptation/verification contention is
  reported separately.

## 19. Acceptance Matrix

### 19.1 Single-proof correctness

- Raw input and all derived artifacts have content digests.
- No production-forbidden fixture or proof-derived artifact is used.
- Statement serialization matches the canonical protocol.
- All four tree roots, OODS, quotient, FRI, query, and opening gates pass.
- Proof verifies in Zig and the canonical Rust verifier.
- Error paths emit no proof and no MHz.

### 19.2 Ten-block queue

The canonical sequence uses seed `20260715`, Python's seeded `Random`/MT19937
and `randrange(4)`, with `0=SN1`, `1=SN2`, `2=SN3`, and `3=SN4`. The report
records the seed, generator identity, Python version, and expanded indices, and
must match this checked sequence exactly:

```text
0101112130
```

- All 10 requests complete in one process and one clean session; every proof is
  non-empty, verifies in Zig and the canonical Rust verifier, and is atomically
  published in sequence order.
- Exactly one Runtime and one serial reusable proof resource set are created.
  Arena allocation count is one plus explicitly reported bounded growth before
  the largest encountered geometry; no per-block arena allocation is allowed.
- All four geometries appear. After a key first appears, its next use reports a
  geometry-cache hit with zero plan and recipe reconstruction.
- The `SN1/SN2/SN1` prefix is an A/B/A reset gate. With forced diagnostic
  nonces, both A transactions match every parity checkpoint; with self-ground
  nonces, both verify the independently serialized A statement.
- A poison/reset variant produces the same checkpoint result and records zero
  read-before-write, incomplete reset, or dirty-resource reuse violations.
- With the checked warm archive, direct compiles, archive misses, archive
  populations, and serialization are zero. Later pipeline uses report PSO
  memory-cache hits.
- Preprocessed/tree-0 data is read, computed, and uploaded at most once per
  `PersistentStateKey`; compatible later blocks report device-state hits.
- Every block records pipeline-cache before/after/delta counters. Deltas are
  nonnegative, monotonic, and sum exactly to queue cumulative counters.
- Adapter prefetch depth never exceeds two, cancellation kills its process
  group, adaptation starvation is reported, and overlap is retained only when
  it improves full queue wall without materially slowing proof wall.
- Prove-only, preparation, adaptation, verifier, block-service, and sustained
  queue scopes remain separate. The final throughput is accepted only after the
  exact `closed` frame and zero daemon exit status.

### 19.3 One-hundred-block queue

The canonical 100-block sequence uses the same mapping and must equal:

```text
0101112130121101232321012001312330102303122120202212233330310201100002323102332030312321122310220022
```

- 100/100 proofs verify in Zig and the canonical Rust verifier without process
  restart, backend fallback, timeout, missing report, or null metric. Runtime
  and reusable proof resource creation counts remain one.
- After all four geometry keys appear, arena capacity, geometry-cache entries,
  metallib count, immutable-device entries, pipeline count, RSS, and Metal
  allocated size plateau. The report identifies the post-warm baseline; every
  sample in the last 20 blocks stays within 2 percent of it and below the
  configured byte budget.
- Warm blocks record zero direct compile, archive miss/population/serialization,
  repeated semantic-artifact disk read, preprocessed host upload, tree-0
  recomputation, and recipe rebuild.
- Pipeline preparation p95 is reported and is below 1 percent of warm verified
  prove p50. Per-block cache before/after/delta sums exactly match queue totals.
- Report p50/p95 prove-only MHz per PIE, aggregate prove-only MHz, sustained
  queue MHz, p50/p95 block latency, adaptation and both verifier costs, cache
  hit rates, arena growth, peak RSS, peak footprint, memory pressure, swaps, and
  thermal/clock context.
- For each PIE, warm proving p50 over blocks 51-100 is no more than 10 percent
  slower than its p50 over blocks 11-50 unless a separately reproduced thermal
  explanation is attached.
- Three independent failure-injection runs fail blocks 10, 50, and 90. The
  injected block emits no proof or MHz, later ordered publication stops, the
  active resource set is marked dirty, and a fresh recovery queue executes the
  full reset/poison path and reproduces the next block's verified result.

### 19.4 Separate SNIP-36 benchmark track

SNIP-36 is an additional client workload for the completed service, not an
adapter for proving SN PIEs and not part of their benchmark numerator. Its
acceptance report is separate and includes:

- The exact SNIP-36 repository revision, input, configuration, and statement.
- The same backend ABI, Runtime/cache telemetry, proof verification gates, and
  metric scopes used by the direct SN PIE service.
- Cold, warm prove-only, and sustained queue measurements labelled `SNIP-36`.
- No result merged into the SN1-SN4 average or described as an SN PIE proof.

It enters the benchmark matrix after M3 exposes the typed service boundary, so
integration work does not delay reference-free direct SN PIE proofs.

## 20. Engineering Rules

- Correctness gates precede throughput claims.
- Keep the existing full paths as explicit oracles until replacements verify.
- Never infer a host bottleneck from proof wall minus stage totals alone.
- Never infer memory bandwidth from bound resource capacity.
- Never trade away Blake2s proof compatibility silently.
- Never retain full evaluations without peak-lifetime accounting.
- Never spill or release coefficients or Merkle data still required by OODS or
  openings without an executed recovery path.
- Never introduce a second full proof workspace merely to claim overlap.
- Never use one giant fused shader when a tiled pipeline has better register,
  occupancy, and debugging behavior.
- Never tune only one PIE; every architecture milestone returns to SN1-SN4.
- Never report sustained service throughput before a clean verified queue close.
- Never run two wide SN PIE proof workspaces concurrently on this 64 GB host.
- Never use full encoder-counter capture on SN4 until a bounded capture proves
  that residency and proof wall are not materially perturbed.
- Use SN2 for the first smoke after a semantic or command-graph change, then one
  representative wide PIE; run the full corpus only after those gates pass.
- Record memory pressure and thermal/clock context for long queue runs, execute
  them serially, and allow the machine to return to a stable state before A/B
  comparisons.

## 21. Immediate Implementation Backlog

### 21.1 Source ownership map

| Workstream | Current modules | Target module/type | Milestone and focused gate |
| --- | --- | --- | --- |
| Raw identity/adaptation | `scripts/sn_pie_adapter.py` | `artifact_manifest.zig`, `BlockExecutor` | M0/M2: mutation, source-chain, raw-to-adapted digest tests |
| Queue/benchmark evidence | `sn_pie_metal_queue.py`, `sn_pie_metal_benchmark.py` | Service `BlockReport`, thin report adapters | M0/M8: fail-closed schema and 10/100 queue tests |
| Session transport | `sn_pie_metal_session.py`, `tools/metal_session/protocol.zig`, `tools/metal_prover_session/`, `artifact_store.zig`, `artifact_views.zig` | JSONL adapter over `prover_service.zig` | M1/M3: protocol-v4 object/view/verifier gates, ordering, cancellation, shutdown tests |
| Statement/transcript | `statement_bootstrap.zig`, `protocol_recipes.zig` | Authoritative `StatementSerializer`, `TranscriptEngine` | M1/M4: ordinal parity, self-PoW, nonce and transcript tests |
| One-shot orchestration | `metal_arena_plan_cli.zig` | Temporary service client | M1-M3: reference-free SN1-SN4, then no semantic ownership |
| Geometry/liveness | `proof_plan.zig`, `staged_arena_planner.zig`, `arena_lifetime.zig` | `PreparedGeometry`, `command_graph.zig` | M2-M4: raw derivation, graph hazards, reset A/B/A |
| Shader build | `witness_codegen.zig`, AOT composition metallib, Runtime source compilation | `shader_manifest.zig`, complete AOT metallib build | M2: digest/compiler tests; zero warm source compiles |
| Recipe binding | `witness/arena_binding.zig`, `protocol_recipes.zig` | Prepared node descriptors and encode-only operations | M4: no local command creation/wait tests |
| Resources | `arena_plan.zig`, monolithic Shared arena | `resource_pool.zig`, `DeviceRef`, `ArenaViews` | M5: alias, admission, pressure, dirty-recovery tests |
| Witness/relation | `witness/*`, `protocol_recipes.zig`, `kernels.metal` | `witness_engine.zig`, `relation_engine.zig` | M5/M6: component digests, sums, roofline and full-wall A/B/A |
| Transform/composition/opening | `runtime.m`, `kernels.metal`, generated AIR | `transform_engine.zig`, bounded AIR planner, pruned RFFT | M6/M7: roots, accumulators, exact openings, byte/op gates |
| Profiling | `runtime_profile.m`, `metal_profile_report.py` | Async stable-ID graph events | M4: interval-union coverage and under-2-percent overhead |
| Verification | `core/pcs/verifier.zig`, `core/vcs_lifted/*`, `tools/stwo-cairo-verifier-rs` | Independent service acceptance | M1-M8: Zig plus canonical Rust cross-verification |

The extraction rule is strict: semantic ownership moves from the CLI into typed
Zig objects before the CLI is simplified. Environment variables remain only as
temporary diagnostic controls and are not copied into the service API.

### 21.2 Ordered backlog

Execute these items in order, with correctness and performance work proceeding
in parallel where ownership permits:

1. Bind the implemented M0 artifact manifest to authenticated adapter,
   bootloader, raw-PIE, schedule-generator, and semantic-artifact source chains;
   report schema v3 and JSONL protocol v4 canonical protocol, manifest, exact
   object map, executable/verifier identity, and queue provenance/protocol
   gates are implemented. Keep the
   current path production-false until every source chain is complete.
2. Preserve the wired statement bootstrap and optional, non-mutating parity
   diagnostics. Python session/queue references are now optional and the
   reference-free persistent SN2 gate passes. The session runner scrubs every
   `STWO_ZIG_SN2_*` input before installing request-derived controls, and the
   hidden forced-nonce/transcript-restore regression passes.
3. Separate self-generated 24-bit and 26-bit PoW timing is implemented. Compact
   PCS/FRI proof reconstruction now passes canonical `verify_cairo` for the
   actual SN2 Metal proof. Zig compact statement serialization and its exclusive
   live-prover output hook are implemented and byte-identical to Rust for SN2.
   The session assembles the protocol/provenance envelope and invokes the
   mandatory pinned verifier. Add the persistent CPU worker pool, run a bounded
   live v4 SN2, then reference-free SN1 and SN4, and cross-verify the full
   SN1-SN4 corpus.
4. Derive schedules and composition semantics from adapted input/AIR metadata,
   with no target proof, and separate statement constants from generated code.
5. Expand the active AOT composition metallib and content-keyed binary archive
   into versioned manifests for every generated shader family; enforce zero
   generated-source compilation on the warm service path.
6. Extend the active capacity-one arena/immutable-state cache into parsed
   `PreparedGeometry` and prepared recipe/graph ownership. Subphase timers and
   canonical physical-plan reuse are implemented, and the compact plan now has
   an independent capacity-four cache. Extend each entry into full parsed/bound
   host geometry, extend resident ownership beyond the active recipe set, and
   drive the remaining measured 0.401040-second warm pre-prove
   interval toward zero. Complete byte-budgeted
   multi-geometry admission, cancellation and dirty-recovery injection, and
   A/B/A validation; the exact-key lease, reset, plan ownership transfer,
   commit, and poison MVP is implemented.
7. Make profiler completion asynchronous, add stable graph IDs, and establish
   non-overlapping accounting plus node byte/op/dependency baselines.
8. Extend the active composition `compositionPrepared` pattern into encode-only
   `CommandContext` epochs with cross-node barriers/status guards, add bounded
   GPU PoW, and progress from the scoped M4a gate to at most eight total command
   buffers and one final wait.
9. Introduce region-qualified resources, packed coefficient banks, placement
   scratch, and process-wide residency accounting.
10. Implement and measure witness-writer batching, multiplicity strategy
    selection, and hierarchical relation inversion/scan.
11. Validate the existing upper radix-4 sparse RFFT path, then A/B bounded
    2,048- and 4,096-operation multi-part AIR fusion using per-component Rust
    accumulator comparisons. Build the exact expression-DAG-cut simulator; use
    8-16 columns only as a transform batch and implement bounded composition
    and transform-to-commit sinks only where the model and full proof agree.
12. Model and implement retained-or-pruned openings on tree 3, tree 2, then tree
    1, retaining the full LDE as the diagnostic oracle.
13. Run A/B/A, randomized 10, randomized 100, failure injection, cache plateau,
    memory pressure, and thermal-stability acceptance.
14. Rebuild the non-double-counted waterfall from verified unprofiled results
    and measured lower bounds before publishing any new 2 or 5 MHz forecast.

## 22. References

Repository evidence and companion documents:

- `docs/history/metal-handover-2026-07-15.md`
- `docs/sn-pie-streaming.md`
- `docs/sn-pie-persistent-session.md`
- `docs/metal-profiling.md`
- `docs/metal-resident-prover-design.md`
- `docs/metal-backend-progress.md`
- `docs/cairo-zig-adapter.md`
- `src/metal_arena_plan_cli.zig`
- `src/tools/metal_prover_session/`
- `src/backends/metal/runtime.m`
- `src/backends/metal/runtime_profile.m`
- `src/backends/metal/protocol_recipes.zig`
- `src/backends/metal/arena_plan.zig`
- `src/frontends/cairo/staged_arena_planner.zig`
- `src/frontends/cairo/witness/arena_binding.zig`

Metal resource and command architecture:

- Apple `MTLHeap`: https://developer.apple.com/documentation/metal/mtlheap/
- Apple resource storage modes:
  https://developer.apple.com/documentation/metal/setting-resource-storage-modes
- Apple argument buffers:
  https://developer.apple.com/documentation/metal/improving-cpu-performance-by-using-argument-buffers
- Apple indirect command encoding:
  https://developer.apple.com/documentation/metal/indirect-command-encoding
- Apple GPU counters:
  https://developer.apple.com/documentation/metal/gpu-counters-and-counter-sample-buffers
