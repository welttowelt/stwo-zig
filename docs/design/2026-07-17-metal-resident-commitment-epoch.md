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
