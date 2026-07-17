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

### Exact peer FRI scheduler

The reusable part of PR #6 is the generic prover hook and pending-tree scheduler, not its ownership
model. `commit_inner_layers()` in `prover/fri.rs` carries a `pending_tree` into the next transcript
round. `fold_line_and_packed_tree()` in `prover/vcs_lifted/ops.rs` is the backend boundary. The Metal
implementation in `backend/metal/fri.rs` encodes the fold and the next tree together, while
`backend/metal/blake2s.rs` hashes four packed secure-field coordinates across four rows directly as
one Blake block.

```text
consume or commit tree_r
  -> mix root_r into the channel
  -> draw alpha_r
  -> backend.fold_line_and_packed_tree(evaluation_r, alpha_r)
       -> fold evaluation_r into evaluation_(r+1)
       -> hash packed leaves_(r+1) directly
       -> build all parent layers_(r+1)
  -> pending_tree = tree_(r+1)
  -> next iteration consumes pending_tree
```

This removes the fold-to-host-to-tree boundary and makes the next commitment ready before the next
channel interaction. It still maps complete tree layers as host-visible `Vec` storage so the Rust
CPU decommitter can consume them later. stwo-zig should adopt the scheduler and typed result
`{ evaluation, tree }`, but retain private/resident tree ownership and selective GPU decommitment.

The peer's tier-2 argument buffers are primarily an AIR constraint and OOD mechanism. They are not
the reason its FRI/Merkle path is fast, and they should not be presented as a prerequisite for the
fold-tree chain.

## Local FRI Call Graphs

### Raw Stwo generic prover

The generic path already has the correct prover-level abstraction boundaries, but independently
submits coordinate conversion, tree construction, and every fold step:

```text
src/prover/fri.zig::commitInnerLayers
  -> secureColumnForMerkle
       -> backends/metal/commit_backend.zig::secureColumnForMerkle
       -> secureColumnFromLine
       -> submit coordinate conversion; wait
  -> B.commitMerkle
       -> backends/metal/commit_backend.zig::commitMerkle
       -> backends/metal/merkle_tree.zig::commit
       -> runtime.commitColumns / stwo_zig_metal_merkle_commit
       -> submit packed leaves and all parents; wait
  -> MC.mixRoot + channel.drawSecureFelt on the host
  -> B.foldLineEvaluationN
       -> runtime.foldFriLine once per fold step
       -> submit and wait for every step
```

`InnerLayerProver` retains the evaluation and tree needed for later queries. The Metal tree already
keeps private resident layers, reads only the 32-byte root during commitment, and batches only the
requested authentication data during decommitment. The missing operation is therefore a generic,
optional backend hook equivalent to the peer hook:

```text
foldLineAndCommitNext(evaluation_r, alpha_r, parameters)
  -> { evaluation_(r+1), resident_tree_(r+1) }
```

Its native implementation must chain AoS QM31 fold output into direct packed leaf hashing and a
private parent chain without a full-layer readback. The generic prover can carry the returned tree
as `pending_tree`; it can continue to mix roots and draw challenges on the host until the channel
also becomes resident.

### Cairo prepared resident prover

The prepared Cairo path is further along because all FRI arrays and trees are planned in one arena,
but it still creates a completion boundary for every operation:

```text
src/metal_arena_plan_cli.zig
  for each round r:
    FriRecipe.commitTree(r)
      -> Runtime.friTreePrepared
      -> packed leaves + parent chain in one command buffer; wait
    copy root_r to host
    TranscriptRecipe.friLayer(root_r)
      -> publishInput(root_r)
      -> transcriptMix; submit and wait
      -> transcriptDrawSecure; submit and wait
      -> copy alpha_r to fri_challenges
    FriRecipe.foldRound(r)
      -> Runtime.friRoundPrepared
      -> resident inverse twiddles + fused fold2/fold3; submit and wait
  FriRecipe.finalize
    -> Runtime.friFinalPrepared; submit and wait
```

For the SN2 fixture with `R = 8`, `FriRecipe` alone currently performs 17 compute waits: eight tree
waits, eight fold waits, and one final-polynomial wait. Including transcript work and the last-layer
mix, the FRI region has approximately 34 host-visible completion boundaries. The arena data is
already resident; synchronization, not data dependency, is forcing the round trips.

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

Deliver this in stages so every reduction in host synchronization remains attributable and
oracle-checked.

**Stage A: peer-parity scheduling.** Extend `command_epoch.zig` and the prepared runtime so one
command buffer encodes `fold_r -> direct packed leaves_(r+1) -> all parents_(r+1)`. Keep the initial
tree, final fold, and final polynomial explicit. The Cairo SN2 target is 10 waits for eight rounds:
one initial tree, seven fold-tree pairs, one final fold, and one final polynomial. Add the same
optional `{ evaluation, tree }` hook to the raw generic backend and carry a pending tree through
`commitInnerLayers()`.

**Stage B: resident channel boundary.** Encode transcript root absorption and secure challenge
drawing into the same ordered command epoch. Feed the resident challenge directly to the next fold;
copy roots and challenges only after completion for proof reporting and oracle diagnostics.

**Stage C: complete resident FRI graph.** In production mode, encode
`tree_0 -> mix/draw/fold/tree -> ... -> final fold -> final polynomial -> last-layer mix` into one
command buffer and wait once. Preserve a diagnostic/reference mode that observes every root,
challenge, evaluation, and tree layer for parity localization.

At every stage, keep four QM31 coordinates resident, hash packed coordinate leaves directly, and
avoid a packed-leaf materialization or host tree. Command-buffer completion is the synchronization
primitive; do not insert CPU waits between encoders on the same ordered queue.

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

## Buffer Ownership And Synchronization Contract

The performance architecture depends on explicit ownership; a fused shader without this contract
will merely move waits around.

- The admitted arena owns evaluation, challenge, packed-leaf scratch, tree-layer, root, and final
  polynomial bindings through proof construction and decommitment.
- Prepared plan objects own immutable geometry, offsets, kernel variants, transcript parameters,
  and retained native plan handles. They do not own per-proof values.
- A command epoch owns the active command buffer and retains every referenced plan and buffer until
  completion. Encoders in an epoch rely on ordered-queue dependencies rather than host waits.
- A transcript operation may consume a root only after its producing encoder in the same epoch. A
  fold may consume a challenge only after the draw encoder. The staged host-channel path may read a
  root only after the fold-tree command buffer completes.
- Production commitment never exposes full tree layers to the host. Root reporting is 32 bytes per
  tree; decommitment transfers only requested witnesses and authentication nodes.
- Arena and plan reuse is mandatory across a streaming queue. No proof may mutate geometry-level
  state or retain aliases after its epoch completes.

## Correctness And Decommitment Gates

Optimization is admitted only after the smallest relevant oracle gate passes. The Rust Stwo pin is
the final authority for raw proofs; the corresponding Stwo-Cairo Rust pin is the final authority for
Cairo proofs.

1. Check fold2 and fold3 outputs for boundary sizes and large resident sizes, for both plain and
   64-byte-prefixed lifted Blake protocol selections.
2. Compare direct packed leaf digests, every parent layer, and every root with CPU and the applicable
   Rust oracle before removing diagnostic readbacks.
3. For every FRI round, compare the root, drawn challenge, folded evaluations, and final polynomial
   coefficients. A cumulative per-component oracle remains the fastest mismatch-localization loop.
4. Preserve `DecommitQueryRecipe.executeFriRound` semantics. Compare query positions, sampled
   witnesses, sibling nodes, and final decommitment assembly, not only the committed root.
5. Require deterministic canonical proof-byte equality between Zig SIMD and Metal when they select
   the same protocol and serialization, successful Zig verification, and successful pinned Rust
   verification. Different protocol versions are never compared by proof hash.
6. Run the raw interop matrix through `scripts/e2e_interop.py`; run the Cairo matrix through the
   pinned Rust Stwo-Cairo verifier before publishing performance.

The diagnostic path may expose intermediate layers solely for parity work. Production telemetry
must prove that those readbacks and their staging allocations are absent.

## Telemetry Acceptance

Every proof report must expose `command_buffers`, `wait_count`, `intermediate_wait_count`,
`compute_encoders`, `dispatches`, `gpu_ms`, `wall_ms`, `root_readback_bytes`,
`full_layer_readback_bytes`, CPU fallback count, and pipeline-compile count. Counters must be split
by transaction so a lower total cannot conceal a new FRI or commitment regression.

The staged acceptance targets are:

| Gate | Required result |
| --- | --- |
| Cairo peer-parity FRI | `R + 2` waits; SN2 `R = 8` therefore reports 10 |
| Complete resident FRI | one command buffer, one completion wait, zero intermediate waits |
| Tree residency | zero full-layer host readback; roots and queried authentication data only |
| Warm streaming | zero direct source compile after admitted pipelines and geometry are warm |
| Correctness | 100/100 interleaved proofs pass Zig and pinned Rust verification |
| Sustained latency | final-quartile p50 no worse than 5% above first-quartile p50 |
| Large-trace FRI | at least 15% lower FRI wall time on raw wide Fibonacci and SN PIE geometry |
| Whole proof | at least 3% lower wall time with no p95 regression in any benchmark class |

Performance gates are directional admission floors, not the end target. Report trace-row MHz,
committed-cell throughput, full request wall time, peak resident bytes, and cold versus warm timing.
Use a cooled single sample for very large geometries and a randomized persistent queue for sustained
measurements.

## What Not To Copy

- A manual AIR-specific MSL string as the general compiler interface.
- `TypeId`-based specialization inside a nominal CPU backend as the long-term backend boundary.
- Host-visible `Vec` storage for every FRI tree layer; keep the local resident tree and sparse GPU
  decommit path.
- Per-thread FRI point construction and Fermat inversion where resident inverse twiddles and the
  existing fused fold2/fold3 path already remove that work.
- Bindless argument buffers as an explanation for FRI/Merkle speedups where the peer does not use
  them for that path.
- The peer `air_shape` result as a Metal column benchmark; its `SimdBackend` does not route through
  the Metal lane.
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
3. Land the telemetry schema above before changing scheduling so each removed wait is measurable.
4. Add the raw generic `{ evaluation, tree }` backend hook and pending-tree scheduler with CPU,
   Metal, decommitment, and Rust-oracle tests.
5. Add Cairo Stage A fold-tree command epochs and meet the SN2 17-to-10 wait target.
6. Move transcript mix/draw into admitted resident state and feed challenges directly into folds.
7. Encode the complete production FRI graph as one epoch while retaining diagnostic checkpoints.
8. Fuse coefficient zero-extension into the resident RFFT first pass and batch commitments to their
   transcript observation boundary.
9. Move immutable column/GPU-address descriptors into admitted prepared state.
10. Profile log-18 width-100 and representative SN PIE geometry with Metal System Trace, GPU
    counters, and transaction telemetry.
11. Run 100 verified randomized proofs over admitted raw, Cairo, and SN PIE geometries in one
    persistent process and enforce the streaming gates.
12. Only then raise the memory guard for a cooled, one-sample log-19 or log-20 crossover check.

The first performance milestone is not a target MHz chosen in isolation. It is elimination of the
19 host Merkle fallbacks while preserving canonical proof bytes and pinned Rust verification. The
peer log-18 result shows that this architecture can support roughly 3 trace-row MHz at this width
on this machine; it does not prove that copying its kernels alone will produce that result.
