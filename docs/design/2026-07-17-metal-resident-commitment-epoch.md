# Metal Resident Commitment Epoch

Status: implementation

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
