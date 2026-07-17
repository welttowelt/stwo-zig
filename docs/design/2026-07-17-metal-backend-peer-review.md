# Metal Backend Peer Review: ClementWalter/stwo PR #6

Status: real wide-Fibonacci AIR parity and the first resident FRI fold-tree transaction are
delivered; broader constraint and multi-fold acceleration remain in progress

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

The branch's architectural advantages are nevertheless directly relevant. The historical
same-geometry campaign below showed a large commitment-path gap, but it used the former synthetic
Zig AIR and therefore is not an end-to-end peer ranking. Commit `e2658e0` replaces that benchmark
with the real dynamic recurrence AIR: a width-`w` trace now enforces all `w - 2` constraints
`c = a^2 + b^2`, and both proof directions pass the pinned Rust oracle.

Commit `fb4a284` delivers the first direct architectural port: the default single-fold FRI path
folds a resident evaluation, converts its four QM31 coordinate planes, hashes leaves, and builds
the complete next Merkle tree in one command buffer with one wait. The isolated log-17 transaction
drops from three submissions and waits to one and is about 2.1x faster in the latest bounded run.
The conservative production cutoff is a folded output of log 18. At log-19 input, width 8, that
admits one fused epoch and improved the sampled complete proof median by about 2% while preserving
canonical proof bytes. No complete-proof gain is claimed below that boundary.

This result validates the scheduling architecture; it does not reproduce the peer's headline.
Constraint accumulation and the remaining commitment/FRI transactions still dominate the route to
materially higher whole-suite throughput.

## Implementation Status

| Work item | Status | Evidence |
| --- | --- | --- |
| Real dynamic wide-Fibonacci AIR | Delivered | `e2658e0`; width-2 boundary, corruption rejection, and blowup-2 coverage |
| Zig proof accepted by Rust | Delivered | pinned raw-Stwo verifier accepts current CPU and Metal artifacts |
| Rust proof accepted by Zig | Delivered | bidirectional proof exchange and tamper matrix pass |
| Generic pending-tree scheduler | Delivered | `c357673`; backend hook retains the next FRI tree |
| Retained coordinate planes | Delivered | scheduler consumes the exact coordinate storage used by the pending tree |
| Single-fold Metal fold-tree epoch | Delivered | `fb4a284`; one command buffer, one terminal wait, resident private tree |
| Multi-fold packed leaves | Pending | requires explicit next-layer row-packing metadata and oracle coverage |
| Generated Metal AIR accumulation | Pending | current real evaluator is correct but remains scalar/general-path work |
| Complete resident FRI graph | Pending | transcript challenge dependencies still create host-visible round boundaries |

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

### stwo-zig historical geometry campaign

- Head during the historical clean measurement: `84c4d657c30b8f6012dcc6b307837735ac94146a`
- Build: Zig `ReleaseFast`
- Host and protocol: identical to the peer run above
- Workload geometry: identical rows, columns, and PCS parameters
- AIR semantics at that head: not equivalent; the benchmark encoded one synthetic
  constant-composition constraint rather than the peer's 98 recurrence constraints
- Sampling: ten verified warmups and eleven verified timed proofs per lane
- Correctness: Zig CPU and Metal produced byte-identical canonical proofs, passed the Zig verifier,
  and passed the custom oracle built on raw Stwo
- Metal evidence: per-proof dispatch/fallback telemetry is present

That historical oracle intentionally mirrored the synthetic component. Do not promote the timing
tables from that campaign to AIR-equivalent proof-throughput evidence. The replacement real AIR and
corruption-rejection coverage landed in `e2658e0`; it invalidates direct performance comparison with
the older report while retaining the report as commitment-geometry evidence.

Commit `dcfd1d8` separates the lifted Blake protocols: raw Stwo uses 64-byte leaf/node domain
prefixes, while the newer Cairo pin uses explicit plain hashing. The clean CPU and Metal artifact
SHA-256 is `7dc92d7b3dbb0f8d649a9a025f24cb3b343d0cf4d4f980a023da2d87743407e0`;
its canonical proof SHA-256 is
`c693d42dc48a2831a7859e2df49e037ea0bfb0dc559f3b34e2f31557d1724442`. The historical Rust verifier
binary SHA-256 is `cbe4d3f107b261285381cd590dbf4b2f86e52eed337843081bd142969f1c4dac`. The
verifier rebuilt from the current real-AIR source has SHA-256
`4d223c37e85b96f61dccc684f2897c82d2d55f6c50b59616a69cc5cc70d2ccf8`.

The clean report SHA-256 values are
`4bb09ca1b7861772f15fd6ae3365ce6c193f8e6d8d22896619730ddf5efb4387` for CPU and
`f783a158a8757c390b169a803f40e5950bd808f74c3b1712b14e82ffd11ca8bc` for Metal. Reproduce the
campaign with:

```bash
zig build native-proof-bench-cpu native-proof-bench-metal -Doptimize=ReleaseFast
zig-out/bin/native-proof-bench-cpu --example wide_fibonacci --log-n-rows 18 \
  --sequence-len 100 --warmups 10 --samples 11 --protocol functional \
  --proof-artifact-out /private/tmp/clean-wf-l18-cpu.proof.json \
  > /private/tmp/clean-wf-l18-cpu.report.json
zig-out/bin/native-proof-bench-metal --example wide_fibonacci --log-n-rows 18 \
  --sequence-len 100 --warmups 10 --samples 11 --protocol functional \
  --proof-artifact-out /private/tmp/clean-wf-l18-metal.proof.json \
  > /private/tmp/clean-wf-l18-metal.report.json
/private/tmp/stwo-rust-oracle-target/release/stwo-interop-rs --mode verify \
  --artifact /private/tmp/clean-wf-l18-metal.proof.json
```

### Current real-AIR FRI transaction

The current admitted path is intentionally narrower than the peer implementation. It applies only
to the protocol's default `fold_step = 1`, resident input, power-of-two output, and folded output
log size at least 18. All other cases retain the established path. This prevents a fast isolated
kernel from being enabled where complete-proof measurements show no gain.

The low-level log-17 transaction test is below the production threshold so it can exercise bounded
memory and exact stage parity:

| Path | Submissions | Waits | Latest wall time | Result |
| --- | ---: | ---: | ---: | --- |
| Separate fold, coordinate conversion, tree | 3 | 3 | 2.265 ms | CPU root and values match |
| Combined fold-tree epoch | 1 | 1 | 1.079 ms | CPU root and values match; 0.605 ms GPU |

Complete-proof A/B at log-18 input did not show a repeatable improvement, so the fused path remains
disabled there. At log-19 input and width 8, seven-sample medians were:

| Policy | Fused epochs | Proof median | Request median | Relative to disabled |
| --- | ---: | ---: | ---: | ---: |
| Disabled | 0 | 241.612 ms | 258.358 ms | - |
| Folded output log 18 | 1 | 236.934 ms | 253.810 ms | 1.020x proof / 1.018x request |

The production-threshold artifact at `/tmp/stwo-zig-metal-fused-log19-th18.json` has canonical proof
SHA-256 `46d2418f3a03e8aafdf2ab326765e187bd69c904386a11f333163be51472d1b5` and is accepted by the
current pinned Rust verifier. This is bounded admission evidence, not a broad-suite performance
claim; the medians are close enough that future changes must remeasure the complete transaction.

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

## Same-Machine Commitment-Geometry Reproduction

### `2^14 x 100`

The peer branch verifies the same proof hash in both lanes. Its instrumented phase sum is nearly
equal, while the warm official test process favors CPU because Metal setup dominates.

| Implementation | Lane | Measured request/phase time | Trace-row MHz | Result |
| --- | --- | ---: | ---: | --- |
| Peer Rust | optimized CPU | 47.13 ms | 0.348 | verified |
| Peer Rust | Metal hybrid | 47.88 ms | 0.342 | verified, same hash |
| stwo-zig | CPU | 31.87 ms | 0.514 | Zig + pinned Rust verified |
| stwo-zig | Metal hybrid | 38.21 ms | 0.429 | Zig + pinned Rust verified, same bytes |

These are not AIR-equivalent proof times. Their timing boundaries are also close but not exact. The
peer phase sum includes per-proof twiddle
precompute; stwo-zig constructs its session twiddles before request timing. The row is evidence of
fixed-cost behavior, not a ranking.

### `2^18 x 100`

This is the largest shared trace and commitment geometry allowed by the current stwo-zig `2^25`
committed-cell guard. The stwo-zig rows are clean medians after ten verified warmups and across
eleven verified timed proofs. The peer rows remain a bounded instrumented reproduction.

| Implementation | Lane | Proof stage | Full request/phase sum | Direct Metal uplift |
| --- | --- | ---: | ---: | ---: |
| Peer Rust | optimized CPU | 59.55 ms core | 106.91 ms | - |
| Peer Rust | Metal hybrid | 49.68 ms core | 88.53 ms | 1.208x total |
| stwo-zig | CPU | 186.30 ms | 272.41 ms | - |
| stwo-zig | Metal hybrid | 138.76 ms | 224.80 ms | 1.343x proof / 1.212x request |

The stwo-zig CPU and Metal canonical proof SHA-256 is
`c693d42dc48a2831a7859e2df49e037ea0bfb0dc559f3b34e2f31557d1724442`.
The peer CPU and Metal regression hash is `47b863fcc71b4c8c`. These hashes use different encodings
and are not comparable with each other.

The peer phase sum delivers 2.961 trace-row MHz and about 296 committed Mcells/s. stwo-zig Metal
delivers 1.889 trace-row MHz within its proof timer, 1.166 trace-row MHz over the complete request,
and 188.9 committed Mcells/s. Different timing boundaries are intentionally kept visible. The
2.54x phase-sum ratio is a geometry-level architecture signal, not a peer AIR prover-speed ratio.

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
requested authentication data during decommitment. Commits `c357673` and `fb4a284` add the generic
optional hook and its first Metal implementation:

```text
foldLineAndCommitNext(evaluation_r, alpha_r, parameters)
  -> { evaluation_(r+1), coordinate_planes_(r+1), resident_tree_(r+1) }
```

The native implementation chains AoS QM31 fold output into planar coordinate conversion, ordinary
four-coordinate leaf hashing, and a private parent chain without a full-layer readback. The generic
prover carries both the returned tree and coordinate planes into the next iteration, avoiding a
second materialization. Multi-fold packing is deliberately excluded until its row-packing contract
is explicit. The channel still mixes roots and draws challenges on the host.

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

## Historical Pre-Port Hot Path

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

This telemetry identified the first architectural target. The admitted single-fold transaction now
removes one of these boundaries at sufficiently large layers, but the historical table must not be
used as a current real-AIR profile. A new complete profile is required before selecting the next
whole-proof bottleneck.

## What To Adopt

### 1. Versioned Merkle protocol authority

Delivered in `dcfd1d8`: the lifted Blake protocols are separate and explicit:

- raw Stwo `a8fcf4bd`: 64-byte `leaf` and `node` domain prefixes;
- Cairo Stwo `9d7e3d6`: plain leaf bytes and plain child concatenation.

The selected protocol must be part of the prover engine type/configuration, Metal pipeline key,
artifact manifest, proof statement, verifier adapter, and benchmark report. CPU and Metal must
select the same protocol without global mutable state.

### 2. Resident FRI fold-tree chains

Deliver this in stages so every reduction in host synchronization remains attributable and
oracle-checked.

**Stage A: peer-parity scheduling.** The raw generic single-fold form is delivered: one command
buffer encodes `fold_r -> coordinate planes_(r+1) -> leaves_(r+1) -> all parents_(r+1)`, and the
prover carries the result into the next iteration. The Cairo prepared prover and multi-fold packed
leaf form remain. The Cairo SN2 target is 10 waits for eight rounds: one initial tree, seven
fold-tree pairs, one final fold, and one final polynomial.

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

1. [x] Maintain the raw-Stwo/Cairo protocol split and exact pinned-Rust acceptance gates.
2. [x] Restore the real dynamic wide-Fibonacci AIR and bidirectional Rust proof parity.
3. [x] Land scheduler and transaction telemetry before removing waits.
4. [x] Add the raw generic pending-tree hook and default single-fold Metal transaction.
5. [ ] Generate packed SIMD and Metal constraint evaluators from authenticated AIR semantics.
   The Metal multi-part path can now emit a selected-only source artifact, removing unreferenced
   legacy kernels from fused builds; SIMD generation and production cap selection remain open.
6. [ ] Add multi-fold packed leaf semantics and the corresponding resident transaction.
7. [ ] Add Cairo Stage A fold-tree command epochs and meet the SN2 17-to-10 wait target.
8. [ ] Move transcript mix/draw into admitted resident state and feed challenges directly into folds.
9. [ ] Encode the complete production FRI graph as one epoch while retaining diagnostic checkpoints.
10. [ ] Fuse coefficient zero-extension into the resident RFFT first pass and batch commitments to
their transcript observation boundary.
11. [ ] Move immutable column/GPU-address descriptors into admitted prepared state.
12. [ ] Reprofile real log-18 width-100 and representative SN PIE geometry with Metal System Trace,
GPU counters, and transaction telemetry.
13. [ ] Run 100 verified randomized proofs over admitted raw, Cairo, and SN PIE geometries in one
persistent process and enforce the streaming gates.
14. [ ] Raise the memory guard only for cooled crossover checks justified by the preceding profile.

The first raw scheduling milestone is complete, but elimination of all 19 historical host Merkle
fallbacks is not. The next material gain is expected from general constraint accumulation and the
remaining packed FRI transactions, not from lowering the current single-fold threshold. The peer
log-18 result shows that its architecture supports roughly 3 trace-row MHz at that width on this
machine; it does not prove that copying its kernels alone will produce that result.
