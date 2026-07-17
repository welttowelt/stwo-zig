# Metal Resident Commitment Epoch

Status: implementation; compact streaming graph and bounded callsite timing accepted

## Performance Hypothesis

```text
Measured bottleneck:
  The bounded Metal profile spends 1.476 ms on GPU work but 9.690 ms in host waits across 17
  command buffers. Native commitment waits after LDE and restages host-shaped evaluations into a
  separate Merkle operation. Cairo recipes are resident-capable but still submit and wait inside
  individual operations.
Proposed mechanism:
  Give one request-owned CommandEpoch submission authority for IFFT -> LDE -> leaf hashing ->
  parent reduction. Every operation encodes into one caller-owned command buffer; one terminal
  wait makes the root visible.
Expected structural result:
  One command buffer, one terminal wait, zero intermediate waits, zero LDE-to-Merkle staging, and
  no host materialization before commitment for an eligible group.
Expected whole-proof effect:
  Lower host wait and transfer time across Native and Cairo commitments. Exact improvement is not
  claimed until a policy-crossover fixture and the affected matrix are measured.
Correctness oracle:
  CPU boundary parity, exact CPU/Metal proof bytes, Zig verification, and pinned Rust Stwo commit
  a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2.
Rollback condition:
  Any hidden wait, unbounded arena/cache growth, lifetime ambiguity, root/opening/decommitment
  difference, command error loss, or affected-class geometric-mean regression.
```

## Why Submission Ownership Comes First

`runtime.m` contains many primitive wrappers that create a command buffer, commit it, and call
`waitUntilCompleted`. Counting those sites is not a proof that every site executes in one proof,
but the command profile confirms that distributed synchronous ownership is active. A new fused
kernel inside another synchronous wrapper would preserve the host serialization that dominates the
profile.

The first change is therefore an encode-only execution boundary. Kernel fusion, untracked hazards,
multiple queues, and indirect command buffers remain later measured choices.

The current resident-Merkle policy starts at `2^24` M31 cells. The normal three-row Native matrix
does not cross that threshold and reports CPU Merkle fallback. This increment must include a
bounded eligible commitment fixture and a crossover sweep; the threshold is not changed from
intuition and the backend remains named `metal_hybrid`.

## Dataflow

```text
owned input evaluations
  |
  v
resident coefficient region -- IFFT encoder
  |
  v
resident extended region ---- LDE encoder
  |
  v
resident leaf region -------- leaf-hash encoder
  |
  v
resident layer regions ------ parent encoders
  |
  v
terminal wait -> root read -> transcript mix
```

Every edge is an arena offset and shape contract, not an allocator-owned slice transfer. Shared
mapping is permitted for explicit recovery and decommitment, but no host read occurs before epoch
completion.

## Session And Request Ownership

The backend-neutral host session already owns the canonical twiddle tower. Metal adds a composed
session instead of returning to global runtime ownership:

```text
MetalProverSession
  +-- HostProverSession
  +-- Runtime and command queue
  +-- compiled library and semantic pipeline cache
  +-- immutable device twiddle bank
  `-- bounded plan cache

RequestSlot
  +-- one resident arena lease
  +-- one in-flight CommandEpoch
  `-- completion and recovery state

CommitmentTree
  `-- completed arena lease containing evaluations and Merkle layers
```

`ProverEngine` selects a backend session type when the backend declares one; CPU keeps the current
host session. A plan borrows the session and owns immutable geometry. An epoch borrows the plan and
slot and retains all Objective-C resources until completion. Completion transfers the arena lease
to the commitment tree. The slot cannot be reused while either the epoch is in flight or the tree
retains the lease.

No `ColumnEvaluation.values` view is individually allocator-freed when backed by resident storage.
Column storage must be an explicit tagged union: individual allocator ownership, grouped allocator
ownership, or one Metal arena lease.

## Command Epoch Contract

`CommandEpoch` has the states `encoding`, `submitted`, `completed`, and `failed`.

- `begin` obtains one command buffer and binds a live request slot.
- encode methods validate plan identity, arena generation, offsets, lengths, alignment, and state.
- encode methods never create, submit, wait for, or read back a command buffer.
- `submit` is allowed exactly once and closes encoding.
- `wait` is the only synchronous completion edge and preserves the first command error.
- root access and storage transfer require `completed`.
- `deinit` joins an in-flight command before releasing retained resources; debug builds report the
  contract violation.
- recovery poisons the slot after a command error until explicit reset completes.

Existing synchronous runtime calls remain compatibility wrappers expressed as begin, encode,
submit, wait, and result access. There is one encoding implementation, not a resident fast path and
a separately drifting compatibility kernel.

## Semantic Cache Keys

Plans and pipelines are reusable only under a complete key:

- device registry identity and Metal feature family;
- runtime, kernel, layout, and hash ABI versions;
- ordered input column logs and counts;
- PCS blowup, lifting, fold, and query geometry relevant to the operation;
- source, coefficient, extended-evaluation, leaf, and layer offsets;
- hash seed/initial-state representation;
- twiddle representation and maximum log.

The plan cache has explicit entry and byte limits. Exhaustion is an error or measured uncached
execution, never silent unbounded growth.

## Source Changes

1. `src/backends/metal/command_epoch.zig`: lifecycle, submission ownership, retained-resource and
   arena-generation checks.
2. `src/backends/metal/runtime.zig` and `runtime.m`: narrow epoch ABI plus encode-only extraction
   from the existing prepared IFFT, LDE, and resident-Merkle implementations.
3. `src/backends/metal/protocol_recipes.zig`: `encode(epoch)` on `CircleIfftRecipe`,
   `CircleLdeRecipe`, and `MerkleCommitRecipe`; synchronous `execute` becomes a wrapper.
4. `src/prover/pcs/columns/storage.zig`: explicit host/grouped/resident ownership union.
5. `src/prover/pcs/columns/preparation.zig` and `commitment_tree.zig`: transfer one completed arena
   lease through quotient use, sampling, openings, and decommitment.
6. `src/backends/metal/commit_backend.zig`: capability-gated resident commitment epoch without a
   policy-threshold change.
7. `src/backends/metal/telemetry.zig` and native reports: fail-closed epoch and residency counters.

## Telemetry

Authoritative unprofiled counters are:

- resident commitment epochs and eligible groups;
- epoch command buffers and intermediate waits;
- host LDE materializations and bytes;
- LDE-to-Merkle staging bytes;
- resident arena current/peak bytes;
- plan-cache hits, misses, entries, and retained bytes;
- terminal command errors and poisoned-slot recoveries.

The command profiler additionally records CPU encode/commit/wait time, GPU interval, compute and
blit encoders, dispatches, requested transfer bytes, and dropped events. The report fails closed if
an eligible epoch records more than one command buffer, any intermediate wait, staging bytes, or no
Metal dispatch.

## Staged Implementation

1. Land state and failure semantics with a mock submission driver.
2. Extract encode-only IFFT and LDE helpers and prove that a two-stage epoch removes one submission
   and wait without changing either buffer.
3. Add leaf and parent encoding, terminal root access, and the completed arena lease.
4. Route Cairo prepared recipes through the same epoch API.
5. Add native PCS resident storage and capability selection.
6. Measure the commitment crossover and change policy only in a separate evidence-backed commit.
7. Reuse the executor for resident inner FRI after this lifetime model is accepted.

Every stage must execute real hardware work. An unused state wrapper is not reported as a
performance increment.

## Acceptance Matrix

- Pure plan tests cover mixed logs, checked offset arithmetic, alignment, arena budget, cache key,
  and every state transition.
- Hardware parity covers IFFT coefficients, extended evaluations, every Merkle layer, root,
  queried openings, and decommitment for mixed `2^10`/`2^11` columns.
- Failure tests inject encode failure, command error, double submission, early root access,
  destruction in flight, stale arena generation, and recovery.
- A bounded command profile proves one command buffer, one wait, and no intermediate materialization
  for an eligible commitment.
- A targeted crossover sweep surrounds the existing `2^24`-cell policy boundary.
- Native small/medium/wide and one bounded Cairo/virtual-SNOS fixture pass exact CPU/Metal parity.
- The clean formal matrix and every applicable artifact pass the Zig verifier and pinned Rust
  oracle.
- Retained and peak bytes remain within configured session and request-slot budgets.
- The affected-class geometric-mean proof time improves, no normal row regresses above 2 percent,
  and no row crosses the program's 5 percent hard bound.

## Accepted Command-Epoch Core

Commit `b7c2c0f` extracts encode-only implementations from the prepared circle IFFT, circle LDE, and
resident Merkle runtime operations. Their existing synchronous entrypoints now call those same
encoders and retain compatibility behavior. `CommandEpoch` owns one Objective-C command buffer,
retains its runtime, arena, and plans, rejects empty or duplicate submission, exposes one terminal
wait, and reports command-buffer, wait, encoder, dispatch, and GPU-duration statistics through a
checked Zig/C ABI.

The bounded real-hardware test uses two columns at circle log 10, extends them to log 11, and encodes
IFFT, LDE, leaf hashing, and every parent layer before one submit. It records exactly one command
buffer, one wait, zero intermediate waits, and zero blit encoders. CPU parity covers both coefficient
columns, both extended-evaluation columns, and the final lifted Merkle root. Lifecycle, empty-epoch,
telemetry-ABI, synchronous-wrapper regression, full Metal, source-conformance, and API-parity tests
pass.

No production policy or `2^24` resident-Merkle crossover changed, so this commit makes no whole-proof
speed claim. The current SN streaming commitment graph uses composition LDE, compact leaf
absorption, arena copies, and a parent-chain plan rather than this three-plan layout. The next Metal
stage must route that production graph through the same submission owner, prove a measured command
and wait reduction, and only then publish a backend MHz change.

## Accepted Compact Streaming Graph

Commit `c0fbb7f` routes the default compact Cairo commitment through one command epoch. Composition
LDE groups, compact leaf accumulation, leaf-state snapshots, and the complete prepared Merkle parent
chain are encoded in dependency order before one submit and one terminal wait. Debug and repair
modes that inspect intermediate host-visible state deliberately retain the synchronous path.

The bounded hardware test uses 32 mixed-log columns in two groups, retains prepared plans after their
Zig owners are destroyed, and compares every extended evaluation plus the final lifted Merkle root
with CPU construction. The epoch records one command buffer, one wait, zero intermediate waits, 23
compute encoders and dispatches, and one blit encoder. The same six prepared operation classes run
synchronously with six command buffers and six waits, so the accepted graph removes five of six
submission and wait boundaries (83.3 percent) without changing kernels or proof semantics.

No SN PIE or heavy block run was used for this acceptance, no crossover threshold changed, and the
bounded Native proof lane does not exercise this Cairo callsite. Therefore these command statistics
are architecture and correctness evidence, not a whole-proof MHz result. The next measured step is a
bounded virtual-SNOS or equivalent compact-streaming fixture, followed by a full formal parity and
Rust-oracle gate before any large PIE escalation.

## Accepted Production-Callsite Timing

Commit `cc176f5` adds a bounded benchmark that enters the exact production compact-commitment core
through an explicit benchmark hook. Its Cairo-shaped fixture has two mixed-log groups, 32 columns,
and a 30,208-byte resident arena. It verifies the final lifted Blake2s root against the CPU builder
and separately verifies the transcript copy after every request. The JSON labels its scope
`cairo_streaming_commitment_only`, sets `proof_generated` to false, and leaves `prove_seconds` null;
these measurements are not full-proof latency or MHz.

Identical benchmark-only plumbing was applied to detached ReleaseFast revisions `653cccd` and
`c0fbb7f`. Each process constructed its runtime and fixture once, performed two warmups, and then
executed 11 timed requests through the same resident fixture:

| Metric | Before epoch | Compact epoch | Improvement |
| --- | ---: | ---: | ---: |
| Median request latency | 2.490 ms | 0.507 ms | 4.92x |
| Median GPU duration | 0.398 ms | 0.305 ms | 1.30x |

Every timed root and transcript matched the CPU oracle. The accepted epoch reports one command
buffer, one wait, zero intermediate waits, 23 compute encoders and dispatches, and one blit. One
2.490-ms-baseline sample reached 27.0 ms, but did not affect the median; raw samples are retained as
the evidence rather than silently trimmed.

A process-level alternating attempt was rejected for request-latency comparison because every
single-sample process paid a cold Metal start. Its GPU median still favored the epoch, 0.435 to
0.362 ms, but it is not substituted for the sustained result. Backend initialization, fixture
construction, warmups, request latency, and GPU duration remain separate fields precisely so cold
setup cannot be mislabeled as steady-state proving.

This establishes that removal of five submission/wait boundaries materially improves the actual
production commitment transaction, not just a synthetic encoder test. It does not establish proof
MHz, block latency, queue throughput, cache bounds, or the next GPU hotspot. Those require a bounded
full-proof fixture and the report-v3 transaction matrix before any SN PIE escalation.

## Post-Epoch Metal Profile

The accepted production-callsite benchmark was profiled on the Apple M5 Max through the existing
real `MTLCommandBuffer` and encoder timestamp instrumentation. Encoder counters were enabled; the
capture reported no command errors, counter overflow, or dropped evidence, and every request
retained exact CPU Blake2s root and transcript parity.

The unprofiled 2-warmup/11-sample run measured 0.588 ms median request latency and 0.357 ms median
GPU duration. Counter instrumentation raised those medians to 0.823 and 0.412 ms respectively, so
profiled latency is diagnostic only. Within the profiled command, encoder intervals sum to
0.395 ms, leaving 0.0173 ms unattributed. Median CPU encoding was 0.0865 ms and the terminal host
wait was 0.585 ms.

| Stage | GPU median (ms) | Dispatches |
| --- | ---: | ---: |
| Small-group LDE | 0.0573 | 6 |
| Small-group leaf hash | 0.0456 | 1 |
| Large-group LDE | 0.0753 | 8 |
| Leaf-state copy | 0.00571 | 1 blit |
| Large-group leaf hash | 0.0398 | 1 |
| Seven Merkle parent levels | 0.1709 | 7 |

The parent chain is about 43 percent of measured encoder GPU time. Its individual medians remain
nearly flat at 0.0233-0.0284 ms while the output grid shrinks from 64 hashes to one, identifying
dependent dispatch boundary cost rather than arithmetic volume as the leading measured tail.

One experiment reused a single compute encoder for all seven existing parent dispatches and inserted
explicit Metal buffer barriers between levels. It reduced total encoders from 24 to 18 and compute
encoders from 23 to 17, but parent time regressed from 0.171 to 0.178 ms and profiled command GPU
time regressed from 0.412 to 0.424 ms. The unprofiled movements, 0.588 to 0.567 ms request and 0.357
to 0.354 ms GPU, were inside noise and contradicted the targeted counters. The experiment was
reverted.

Encoder reuse is therefore not the next architecture. The next measured experiment is a
multi-level Blake2s parent-tail shader: one eligible threadgroup reduces several dependent small
levels through threadgroup memory and barriers while writing every protocol-required retained
layer. It must preserve the current per-level path as a checked fallback, enforce explicit
threadgroup-memory and layer-capacity bounds, and demonstrate fewer dispatches plus lower parent
GPU time before acceptance. This VCS mechanism is below workload selection and applies to Cairo,
Native/RISC-V, SNIP-36, and SN proofs that use the same lifted Blake2s commitment path.

## Accepted Merkle Parent Tail

Commit `0b2eb10` implements that measured experiment. `stwo_zig_blake2s_parent_tail_sparse` reduces
an eligible contiguous upper Merkle chain inside one threadgroup and one dispatch. Intermediate
hashes remain in dynamic threadgroup memory, while every level is also written to its original
resident-arena destination so openings and decommitments retain the complete protocol-required
layer set.

Preparation selects the earliest eligible suffix only when it contains at least two levels, its
first parent count is a power of two, every following count exactly halves, each child offset equals
the previous destination, destination ranges do not overlap, and the first level fits the minimum
of 256 threads, the pipeline limit, and available device threadgroup memory at 32 bytes per thread.
Scratch is therefore capped at 8 KiB. A larger tree keeps its per-level prefix and fuses only the
eligible tail; an arbitrary or over-budget chain retains the complete per-level fallback. Standalone
and epoch execution both reject a plan whose checked required arena extent exceeds the resident
buffer before GPU encoding.

Alternating sustained ReleaseFast A/B used order candidate/baseline/baseline/candidate, two warmups,
and 11 samples per process for 22 samples per lane. All samples matched the CPU Blake2s root
`1c5ba1a931eccec31419ac78acb6250b43b7d25fc97c4c288b7b06c685a9d291` and transcript.

| Metric | Per-level tail | Fused tail | Improvement |
| --- | ---: | ---: | ---: |
| Request median | 0.571 ms | 0.524 ms | 1.09x |
| GPU median | 0.351 ms | 0.292 ms | 1.20x |
| Compute encoders | 23 | 17 | 6 fewer |
| Dispatches | 23 | 17 | 6 fewer |

The fused GPU range of 0.289-0.300 ms does not overlap the baseline range of 0.308-0.370 ms. A
separate counter-enabled A/B reduced the parent stage from 0.201 to 0.120 ms, or 1.67x, and complete
command GPU time from 0.455 to 0.352 ms, or 1.29x. Encoder-interval sum fell from 0.438 to 0.344 ms;
CPU encode time fell from 0.0984 to 0.0906 ms and terminal wait from 0.652 to 0.531 ms.

Tests compare every fused intermediate layer and root with CPU, destroy a prepared plan before epoch
submission to exercise retained Objective-C ownership, cover a 512-parent per-level prefix followed
by a 256-parent fused tail, reject zero parent counts, and reject undersized arenas before FFI. The
bounded production callsite, all 65 Metal tests, source conformance, and API parity pass. This is a
measured commitment-stage improvement; full-proof MHz still comes only from the formal transaction
matrix and not from this isolated fixture.

## Accepted Batched Resident Decommit Readback

Commit `a8968f8` replaces one synchronous selective hash read per Merkle layer with one checked
multi-layer blit and one wait per resident tree. The backend-neutral decommitter first derives the
exact child-index sequence for every layer. Host trees retain the original sequential traversal with
no new planner or allocation. A resident tree passes all layer requests to `Tree.copyHashesBatch`,
which validates request count, shift bounds, layer bounds, index bounds, and total byte arithmetic
in Zig and Objective-C before encoding. Duplicate indices, empty layer requests, and request order
are preserved exactly.

The production resident threshold remains `1 << 24`; forcing smaller trees onto Metal was used only
to expose the synchronization architecture. Under that bounded forced mode, the result was:

| Metric | Wide before | Wide batched | XOR before | XOR batched |
| --- | ---: | ---: | ---: | ---: |
| Selective read commands/proof | 87 | 12 | 98 | 13 |
| Total Metal commands/proof | 123 | 48 | 137 | 52 |
| Selective read wait/proof | 15.658 ms | 2.481 ms | 17.692 ms | 2.429 ms |
| FRI decommit | 16.580 ms | 2.738 ms | 16.630 ms | 2.519 ms |
| Trace decommit | 5.160 ms | 0.571 ms | 7.295 ms | 0.802 ms |
| Complete prove | 36.789 ms | 17.351 ms | 39.005 ms | 17.355 ms |

Normal-policy 15-sample XOR medians remained flat at 5.279 versus 5.274 ms prove time and 5.424
versus 5.417 ms request time. Wide also showed no regression, but its faster same-machine movement
was treated conservatively as system-sensitive rather than attributed to an inactive resident path.
Both forced Wide and XOR proofs retained their exact established SHA-256 values and were accepted
by the pinned Rust Stwo oracle. Direct tests cover duplicate and empty requests plus invalid layer,
index, and shift bounds.

This is resident infrastructure, not evidence that staging a small host trace into Metal is faster.
Even after the readback reduction, forced-resident proofs remain slower than the production CPU
small-tree policy. The result removes the decommit synchronization penalty required before an LDE
or quotient producer can hand an already-resident allocation directly to Merkle commitment.
