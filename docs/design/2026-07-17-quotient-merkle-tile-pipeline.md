# Quotient-To-Merkle Tile Pipeline

Status: implementation; quotient-to-leaf fusion and bounded inputs accepted

## Performance Hypothesis

```text
Measured bottleneck:
  The clean post-session, post-deterministic-PoW log12x16 CPU diagnostic spends 3.577 ms of a
  6.332292 ms proof in FRI quotient construction and commitment. Main-trace Merkle commitment adds
  1.039 ms, placing quotient plus measured Merkle work at 72.9 percent of proof time. Blake2s rounds
  are the largest non-idle sampled stack, and combined-contribution planning remains separately
  visible.
Current architecture:
  The CPU path constructs complete-column combined contribution coordinate arrays, computes the
  whole four-coordinate quotient column, and only then performs a second full-column pass to hash
  the first FRI Merkle leaves. The API calls this path lazy, but its producer and consumer are
  separated by a complete-domain barrier.
Proposed mechanism:
  Execute bounded row tiles whose worker-local state contains contribution numerators, denominator
  inverses, and a disjoint output range. Write each quotient tile into its retained output planes
  and immediately pass those still-hot rows to a Merkle leaf writer. Build parent layers only after
  all leaf writers join.
Operations and traffic removed:
  First, remove the post-compute full-column leaf pass. Then replace complete-column combined
  contribution coordinates with bounded per-worker numerator tiles. The number of Blake2s hashes
  and field operations is not claimed to change; the expected gain is lower intermediate traffic,
  fewer cold rereads, fewer phase barriers, and bounded working state.
Expected affected stages:
  fri_quotient_plan, fri_quotient_tile_compute_and_leaf,
  fri_first_layer_internal_merkle, fri_quotient_build_and_commit, and complete prove_seconds.
Expected unchanged behavior:
  AIR evaluation, quotient values, leaf order, every Merkle layer and root, transcript order,
  FRI folds, queries, decommitments, proof bytes, verification, and the Metal path until it opts
  into the same commitment capability.
Correctness oracle:
  Exact legacy-path value/layer parity, Zig verification, exact CPU/Metal canonical proof parity,
  and final acceptance by pinned Rust Stwo commit
  a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2.
Success threshold:
  The targeted stage improves outside profiler noise, affected-class geometric-mean prove time
  improves, no checked-in row regresses beyond the performance-program gates, and tiled execution
  reports zero complete-column combined-intermediate bytes and zero post-compute leaf passes.
Rollback condition:
  Any value, leaf, root, transcript, decommitment, or proof-byte difference; an unjoined failure;
  scratch above its explicit budget; hidden fallback; or no measured gain on the wide affected
  rows after the two mechanisms have been evaluated independently.
```

## Measured Basis

The historical profiler evidence is recorded in
`docs/design/2026-07-17-backend-performance-program.md`. The bounded CPU diagnostic used the
functional `log12x16` Native wide-Fibonacci workload and 101 profiled samples. Before row batching,
median proof time was 7.133 ms and FRI quotient construction and commitment consumed 4.015 ms.
Commit `09ed7ef` replaced one CM31 denominator inversion per row with bounded batch inversion. The
same diagnostic then measured 6.293 ms for the proof and 3.388 ms for the quotient stage, reductions
of 11.78 and 15.62 percent respectively.

A fresh clean profile after reusable sessions and deterministic parallel proof of work is stored at
`/private/tmp/stwo-post-pow-profile-a641082-clean/cpu-log12x16.report.json`. It measured total proof
time at 6.332292 ms, FRI quotient construction and commitment at 3.577 ms (56.488 percent),
main-trace Merkle commitment at 1.039 ms (16.408 percent), sampled-value evaluation at 0.443 ms,
main-trace interpolation at 0.304 ms, and proof of work at 0.223 ms. The session reduced measured
main-trace interpolation by 37.45 percent. Quotient plus measured Merkle commitment now accounts for
72.9 percent of the clean proof, so ownership between quotient/LDE producers and commitment remains
the highest-priority CPU architecture boundary after the accepted session change.

The pre-batching non-idle sample capture reported Blake2s rounds at 232 hits,
`M31.powPMinus2` at 90, circle evaluate-many at 72, `compressParallel4` at 69,
`CirclePointIndex.toPoint` at 42, combined-contribution planning at 29, FFT evaluation at 25, IFFT
at 24, and CPU Merkle commitment at 20. Batch inversion attacks the second entry. It does not alter
the complete-column contribution intermediate or the later leaf reread addressed here.

The source confirms the architectural barrier:

- `LazyQuotientProvider.initForBackend` scans column values and calls
  `buildCombinedContributionPlan`, which allocates four M31 coordinate arrays for each combined
  view and fills them over complete source columns.
- `MerkleProverLifted.commitWithLazyQuotients` calls `provider.computeAll`, waits for the entire
  output, allocates the leaf layer, and calls `hashLazyQuotientLeaves` in a separate pass.
- `CpuBackend.commitLazyMerkle` selects that implementation for every standard CPU first FRI
  layer.
- `FriProver.commitFirstLayerLazy` mixes the root only after the complete tree returns, which is the
  correct transcript barrier and remains unchanged.

The accepted reusable session provides the immediate baseline: its CPU geometric-mean prove-time
gain was 3.70 percent, its formal CPU/Metal matrix was exact, and all six artifacts passed the pinned
Rust verifier. Before implementing this design, preserve binaries from the latest clean accepted
commit and recapture the three-row baseline after all preceding focused increments. Older profiler
numbers diagnose the mechanism; they are not substituted for the new unprofiled baseline.

## Scope

This design changes the CPU construction of the first FRI quotient commitment. It applies to every
frontend that reaches the standard PCS and FRI prover, including Native examples, Cairo traces,
virtual SNOS, SNIP-36 prover-backend fixtures, and SN PIEs. It is not specialized for Fibonacci or
for a particular AIR width.

The initial implementation does not:

- change quotient mathematics, FRI parameters, transcript order, proof of work, or verification;
- change Blake2s, add a new SIMD hash kernel, or claim fewer compression operations;
- add a second thread pool or create threads per tile;
- retain request scratch in `ProverSession` before request-slot ownership is designed;
- change the Metal policy threshold or label the hybrid backend as fully resident;
- fuse internal Merkle levels before leaf ownership and failure behavior are accepted;
- run large SN PIE profiling as the first validation loop.

`compressParallel4`, domain-point reuse, and LDE-to-Merkle ingestion remain separately measurable
follow-on changes. They must not be folded into the first performance commit.

## Current And Target Dataflow

Current CPU first-layer flow:

```text
borrowed trace columns and samples
  |
  +-- full nonzero scan
  |
  +-- complete-column combined coordinate arrays
  |
  +-- quotient workers write complete SecureColumnByCoords
  |
  +-- join every quotient worker
  |
  +-- hash complete SecureColumnByCoords into leaves
  |
  +-- build all parent layers
  |
  `-- return tree -> mix root into transcript
```

Target CPU flow:

```text
borrowed trace columns and compact contribution metadata
  |
  +-- preallocate output, leaves, worker scratch, writers, and work records
  |
  +-- deterministic disjoint worker shards
  |     |
  |     `-- for each bounded tile in ascending shard order
  |           +-- prepare domain points and batch denominator inverses
  |           +-- accumulate contribution numerators in tile-local SoA
  |           +-- write four retained quotient coordinate planes
  |           `-- hash those same rows into the writer's leaf range
  |
  +-- join every worker and resolve errors in shard order
  |
  +-- build parent layers from the completed leaves
  |
  `-- return tree -> mix root into transcript
```

The quotient output index remains the Merkle leaf index. Only the domain point used by quotient
arithmetic is selected through `bitReverseIndex`. A tile writer must never bit-reverse its output
range again.

## Module Boundaries

### `src/prover/pcs/quotient_tile_executor.zig`

This new module owns bounded CPU tile arithmetic and worker orchestration. It is split from
`quotient_row_executor.zig` so the existing row executor does not grow beyond the repository's soft
file-size cap and the compatibility path remains independently testable.

It declares:

```zig
pub const DEFAULT_TILE_ROWS: usize = 256;
pub const MAX_TILE_ROWS: usize = 1024;
pub const MAX_SCRATCH_BYTES_PER_WORKER: usize = 8 * 1024 * 1024;

pub const RowRange = struct {
    start: usize,
    end: usize,
};

pub const QuotientTile = struct {
    start: usize,
    coordinates: [qm31.SECURE_EXTENSION_DEGREE][]const M31,
};

pub const ExecutionStats = struct {
    tiled: bool,
    worker_count: usize,
    tile_row_limit: usize,
    tile_count: usize,
    peak_scratch_bytes_per_worker: usize,
    total_scratch_bytes: usize,
    bounded_numerator_tile_bytes_per_worker: usize,
    complete_column_combined_intermediate_bytes: usize,
    post_compute_leaf_pass_count: usize,
};
```

Every coordinate slice in `QuotientTile` has the same nonzero length. It represents the absolute
output range `[start, start + len)`, and it is borrowed only for the duration of `absorb`. The writer
may not retain the slices or access them after returning.

The normative execution entrypoint is:

```zig
pub fn computeAllWithTileSink(
    comptime Sink: type,
    allocator: std.mem.Allocator,
    provider: *quotient_ops.LazyQuotientProvider,
    out_column: *SecureColumnByCoords,
    sink: *Sink,
) !ExecutionStats;
```

`Sink` must declare `pub const Writer` and:

```zig
pub fn prepareWriters(
    self: *Sink,
    allocator: std.mem.Allocator,
    ranges: []const RowRange,
) ![]Writer;

pub fn finishWriters(self: *Sink, allocator: std.mem.Allocator, writers: []Writer) !void;

// Required on Sink.Writer.
pub fn absorb(self: *Writer, tile: QuotientTile) !void;
```

`prepareWriters` validates that ranges are ordered, adjacent, non-overlapping, begin at zero, and
cover the domain exactly. Each returned writer owns one disjoint range and accepts contiguous tiles
in increasing order. `finishWriters` is called only after every worker has joined; it validates that
every writer reached its declared end and consumes the writer array. No sink method is called from
two workers on the same writer.

The executor uses the installed global prover pool. It performs no thread creation and no hot-path
allocation. All ranges, writer values, workspaces, numerator buffers, denominator buffers, and work
records are allocated and validated before the first task is spawned.

### `src/prover/pcs/quotient_ops.zig`

`LazyQuotientProvider` remains the owner of request-local quotient constants, sample batches, and
compact contribution metadata. It continues to borrow committed column values. For tiled CPU mode
it retains the flat borrowed `ColumnEvaluation` descriptors and active-column/range/contribution
metadata; it does not own complete-column `CombinedContributionView` coordinate arrays.

The provider declares an explicit mode:

```zig
pub const InputMode = enum {
    bounded_cpu,
    combined_compatibility,
    raw_backend,
};
```

- `bounded_cpu` uses the new bounded executor.
- `combined_compatibility` preserves the current implementation for controlled A/B, small-shape
  crossover, and rollback.
- `raw_backend` preserves Metal's current `rawQuotientInputs` contract.

Selection is made from backend capability, checked geometry, and a measured crossover policy. It
is never selected by workload name. An environment variable may force a mode only in diagnostic
and test binaries; authoritative reports record the override and do not silently treat it as the
default.

The first implementation preserves the existing nonzero-column classification so compute-to-leaf
fusion can be measured without also changing sparse-column work. The second implementation stage
moves contribution accumulation into bounded numerator tiles and deletes complete-column combined
coordinate allocation from `bounded_cpu`. Moving or eliminating the nonzero scan requires separate
evidence, because sparse Cairo traces may benefit from it.

### `src/prover/vcs_lifted/first_layer_sink.zig`

This new module owns CPU first-layer leaf construction:

```zig
pub fn FirstLayerLeafSink(comptime H: type) type;

// Returned type methods.
pub fn init(allocator: std.mem.Allocator, leaf_count: usize) !Self;
pub fn prepareWriters(self: *Self, allocator: std.mem.Allocator, ranges: []const RowRange) ![]Writer;
pub fn finishWriters(self: *Self, allocator: std.mem.Allocator, writers: []Writer) !void;
pub fn finish(self: *Self, allocator: std.mem.Allocator) !MerkleProverLifted(H);
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void;
```

`init` allocates the final leaf layer from `layerAllocator`. A writer holds only its disjoint leaf
subslice, absolute range, and next expected row. Its `absorb` hashes the four M31 coordinates in
canonical coordinate order with `H.defaultWithInitialState`, `updateLeaf`, and `finalize`. The first
commit uses the existing scalar leaf semantics. Four-way Blake2s changes, if later measured, are a
separate commit against the same writer contract.

`finish` is legal only after `finishWriters`. It builds parent layers through the existing
`vcs_lifted/layers.zig` `LayerExecutor`, reverses the bottom-up layer list into the canonical tree
layout, and transfers all layer ownership to `MerkleProverLifted(H)`.

### Existing Orchestration

`MerkleProverLifted.commitWithLazyQuotients` in `src/prover/vcs_lifted/prover.zig` becomes thin
orchestration over `FirstLayerLeafSink` and `computeAllWithTileSink`. The compatibility helper that
computes then hashes remains private and test-selectable until crossover acceptance is complete.

`CpuBackend.commitLazyMerkle` in `src/backends/cpu_scalar/mod.zig` retains its public signature and
selects this implementation. `FriProver.commitFirstLayerLazy` in `src/prover/fri.zig` retains
ownership of the output column and mixes the root only after the completed tree returns.

Stage recording is threaded through `proveValuesFromSamplesWithRecorder`, `FriProver.commitLazy`,
and `commitFirstLayerLazy`. This is request-local plumbing, not a global profiler singleton.

## Tile Arithmetic And Layout

Each worker scratch allocation is a single checked backing region partitioned into aligned slices:

```text
domain_points[tile_rows]
denominators[batch_count][tile_rows]
denominator_inverses[batch_count][tile_rows]
numerators[batch_count][4][tile_rows]
```

The byte requirement is calculated with checked multiplication and addition before allocation. The
tile row limit is the minimum of `DEFAULT_TILE_ROWS`, the remaining shard length, and the largest
row count that fits `MAX_SCRATCH_BYTES_PER_WORKER`. A batch geometry that cannot fit one row uses
the compatibility path or returns an explicit budget error according to the selected policy; it
must not allocate above the cap.

Within a tile:

1. Materialize its bit-reversed domain points and prepare all denominator inverses with the accepted
   batch-inversion algorithm.
2. Zero the numerator tensor.
3. Visit active columns in canonical flattened order. For each contribution, lift the source index
   with the existing mixed-log formula and accumulate `base * coefficient` into the corresponding
   batch and coordinate plane.
4. Reconstruct one QM31 numerator per sample batch and row, finalize the quotient using the prepared
   inverse, and write the four coordinates to the retained output planes.
5. Call the worker's leaf writer with slices of those same output planes.

SoA is normative for the numerator scratch because column/contribution accumulation traverses one
coordinate plane at a time and the final row loop has a fixed four-coordinate gather. An AoSoA
alternative requires measured evidence and exact scalar-tail tests. Buffers have stable alignment;
aliasing between input columns, numerator scratch, output planes, and leaves is forbidden.

## Ownership And Lifetime

```text
FriProver.commitFirstLayerLazy
  +-- owns uninitialized SecureColumnByCoords
  +-- borrows LazyQuotientProvider for the call
  `-- owns FirstLayerLeafSink until finish
        |
        +-- pre-dispatch: owns leaf layer and Writer array
        +-- in flight: each worker owns one Writer and scratch region
        `-- post-join: transfers completed layers to MerkleProverLifted

success:
  FirstLayerProver owns SecureColumnByCoords + MerkleProverLifted

failure:
  caller frees SecureColumnByCoords; sink frees partial leaves/layers; provider remains deinit-safe
```

- The provider borrows committed columns and sampled-point/value inputs until every tile worker has
  joined. It never stores a leaf writer or H-specific value.
- The output column is allocated before dispatch. Each worker writes one exclusive row shard in all
  four planes. The first-layer prover takes ownership only after tree construction succeeds.
- Writers are values owned by their worker records. Their leaf slices are disjoint and remain valid
  until the sink finishes or deinitializes.
- A tile and its coordinate slices are ephemeral. `Writer.absorb` may not retain them.
- `MerkleProverLifted` receives the leaf allocation and every parent allocation exactly once.
- The global pool is borrowed and outlives the call. Every spawned task is joined before provider,
  output, sink, writers, or scratch is destroyed.
- No mutable tile state enters `ProverSession`. A later bounded request-slot design may retain
  scratch, but it must preserve exclusive lease ownership and byte accounting.

## Failure Contract

All size, range, alignment, worker-count, and byte-budget checks occur before dispatch. Arithmetic
overflow is an error, never wrapping allocation geometry.

Once tasks are spawned:

- each work record stores its own optional failure;
- a worker stops its own shard after its first arithmetic or sink error;
- already spawned workers are allowed to finish; no backing allocation is freed early;
- the caller always joins the complete wait group;
- failures are scanned in ascending shard order and the lowest-index failed shard determines the
  returned error, making error selection independent of scheduling;
- no Merkle parent construction or transcript root mix occurs after a worker failure;
- the sink frees partially written leaves, and the caller frees the partial output column;
- the provider and compatibility state remain valid for normal `deinit`.

Production CPU leaf absorption allocates nothing and is expected not to fail after initialization.
The fallible writer interface is retained to test failure propagation and to support later backend
writers. Allocation failure during parent construction frees every completed lower layer. A call to
`finish` before all writers reach their declared ends returns `error.IncompleteLeafLayer`.

Diagnostic mode forcing may return `error.TileScratchBudgetExceeded` instead of falling back. Normal
automatic selection records a compatibility fallback with its reason. A requested tiled mode may
never silently execute the legacy path.

## Telemetry Contract

The outer existing stage `fri_quotient_build_and_commit` remains stable. Profiled diagnostics add
these child stages:

- `fri_quotient_plan`;
- `fri_quotient_tile_compute_and_leaf`;
- `fri_first_layer_internal_merkle`.

The fused stage deliberately has one timer. Per-tile clocks would perturb short proofs and make
concurrent child timings misleading. Kernel attribution comes from the system profiler; logical
work comes from counters aggregated after the join.

`ExecutionStats` is recorded once per proof into stage-profile counters with these exact names:

- `tile_pipeline_selected` (`0` or `1`);
- `worker_count`;
- `tile_row_limit`;
- `tile_count`;
- `peak_scratch_bytes_per_worker`;
- `total_scratch_bytes`;
- `complete_column_combined_intermediate_bytes`;
- `post_compute_leaf_pass_count`.

The stage-profile schema gains optional unsigned counters and increments its schema version in the
same commit as its encoder and Python contract tests. Unprofiled proving does not allocate counter
maps and performs no atomic increment in the tile loop. Worker-local tile counts are summed after
join.

For an accepted tiled sample:

```text
tile_pipeline_selected                   = 1
worker_count                             >= 1
tile_row_limit                           in 1..MAX_TILE_ROWS
tile_count                               >= worker_count
peak_scratch_bytes_per_worker            <= MAX_SCRATCH_BYTES_PER_WORKER
total_scratch_bytes                      <= worker_count * MAX_SCRATCH_BYTES_PER_WORKER
complete_column_combined_intermediate_bytes = 0
post_compute_leaf_pass_count              = 0
```

A compatibility sample records `tile_pipeline_selected = 0`, its measured complete-column combined
bytes, and exactly one post-compute leaf pass. Reports fail closed if a requested tiled diagnostic
violates any invariant or omits its counters.

The expected profiler signature is the disappearance of standalone
`buildCombinedContributionPlan` complete-column coordinate filling after stage three and the
disappearance of standalone `hashLazyQuotientLeaves` after stage two. Blake2s compression work
remains visible; only its wall time may fall through locality and scheduling. If sampled Blake
frames remain but the target stage does not improve, that is evidence for the separate
`compressParallel4` change, not a reason to misattribute a gain to this pipeline.

## Staged Implementation

### 1. Instrument And Preserve The Legacy Path

- Add the three stage boundaries and `ExecutionStats`/profile-counter schema.
- Record actual current complete-column combined-intermediate bytes and one post-compute leaf pass.
- Preserve proof bytes and baseline stage times.
- Commit this as measurement infrastructure only.

### 2. Fuse Quotient Output With Leaf Construction

- Add `FirstLayerLeafSink`, writer partition validation, and the generic tile sink contract.
- Keep the current `CombinedContributionPlan` and accepted batch-inversion arithmetic.
- Emit each completed arithmetic tile directly to its leaf writer.
- Retain a private forced legacy path for exact A/B.
- Accept or reject this commit from the loss of the second pass and measured stage movement alone.

### 3. Replace Complete-Column Combined Coordinates

- Add bounded numerator SoA to `quotient_tile_executor.zig`.
- Keep only compact active-column and contribution metadata in tiled CPU provider state.
- Remove complete-column `CombinedContributionView` construction from tiled mode.
- Preserve the measured compatibility crossover for small or pathological shapes.
- Accept or reject this commit independently from stage two.

### 4. Establish The Crossover Policy

- Sweep domain logs around the observed crossover with narrow, wide, sparse, and dense contribution
  shapes.
- Select by checked domain, active-column, contribution, sample-batch, and scratch geometry.
- Do not select by example, frontend, AIR name, or PIE identity.
- Land policy changes only with before/after evidence and explicit fallback telemetry.

### 5. Generalize Producer-To-Commit Ingestion

- Define the shared leaf-ingestion subset used by LDE column preparation.
- Let CPU circle LDE retain its evaluation output while emitting row tiles to the same leaf layer.
- Preserve mixed-log lifting order and decommitment storage.
- This is a new measured increment because main-trace and composition commitments have different
  producers and column counts.

### 6. Add A Resident Metal Implementation

- Keep the backend entrypoint `commitLazyMerkle` so Metal can implement quotient kernel, leaf hash,
  and parent reductions in one request-owned command epoch.
- Metal uses device-resident output and leaves rather than CPU Writer values, but preserves the same
  range, completion, error, root, and telemetry invariants.
- Integrate with `docs/design/2026-07-17-metal-resident-commitment-epoch.md`: encode-only operations,
  one terminal wait, completed arena-lease transfer, and no host read before completion.
- Do not report Metal benefit until command profiling proves fewer waits/staging bytes and the
  affected matrix improves.

Each numbered stage lands as a focused commit with a clean tree and its own correctness and
performance evidence. Kernel SIMD, point-table caching, and internal-layer fusion are not bundled
into these commits.

## Correctness And Failure Tests

### Arithmetic And Leaf Parity

- Compare every quotient coordinate against the compatibility path for domain logs 3, 6, 10, 12,
  and 14.
- Cover one and many sample batches, one and many contributions per column, repeated batch targets,
  zero columns, zero sampled values, and mixed column logs.
- Compare every leaf, every parent layer, root, opened values, and decommitment against the legacy
  tree, not only the final root.
- Test tile row limits 1, 255, 256, 257, 1023, and 1024, including final tails of each size class.
- Test one worker and every supported deterministic multi-worker partition whose geometry is small
  enough for unit tests.
- Verify output and leaf position ordering explicitly with non-symmetric data so a second bit
  reversal cannot pass accidentally.

### Ownership And Bounds

- Exhaust allocation failure before dispatch for output, leaves, ranges, writers, every worker
  workspace, and parent layers.
- Inject arithmetic failure and fake-writer failure in the first, middle, and final shard; assert
  every task joined and the lowest failed shard's error was returned.
- Reject overlapping, gapped, reversed, out-of-domain, duplicate, and incomplete writer ranges.
- Reject size multiplication/addition overflow and batch geometry that cannot fit one row.
- Assert per-worker and total scratch remain within their reported limits.
- Run leak checks for success, every injected failure, forced compatibility, and forced tiled mode.

### Backend And Proof Gates

- Run `zig build test`, `zig build api-parity`, `zig build source-conformance`, formatting, and the
  benchmark report/Python contract tests.
- Prove and verify Native mixed AIR fixtures in addition to wide Fibonacci: XOR or state machine,
  PLONK, and one Poseidon or Blake compute-heavy fixture once their engine-generic harness entries
  are available.
- Prove one bounded Cairo or virtual-SNOS fixture before any SN PIE escalation.
- Run the formal `log10x8`, `log12x16`, and `log14x32` CPU/Metal matrix with exact proof parity.
- Verify every formal artifact with the pinned Rust Stwo oracle. Rust acceptance is the final
  correctness gate even when Zig verification and CPU/Metal parity already pass.

## Performance Acceptance

Preserve baseline and candidate ReleaseFast binaries. Use identical host, Zig version, protocol,
session geometry, workload descriptors, worker configuration, warmups, sample counts, lane order,
and environment. Alternate before/after order, record median/minimum/maximum/MAD, and cool the host
between wider lanes. Stop when thermal or memory pressure makes samples incomparable.

The bounded loop is:

1. Unit and component parity on small mixed geometries.
2. One profiled `log12x16` diagnostic sufficient to confirm the expected stack and counter changes.
3. Unprofiled Native small/medium/wide A/B with at least five post-warmup samples; use the longer
   established sampling protocol only when dispersion requires it.
4. One bounded log14 diagnostic if the medium profile does not exercise the complete-column path.
5. The clean formal CPU/Metal matrix and pinned-Rust checks.
6. One bounded Cairo fixture after Native acceptance; large SN PIE and streaming queues only after
   the shared stage is stable.

An implementation stage is accepted only when:

- the targeted fused quotient/first-layer stage improves outside profiler noise;
- the affected workload median does not regress by more than 2 percent;
- no checked-in matrix row regresses by more than 5 percent without an explicit accepted tradeoff;
- the affected-class geometric-mean prove time improves;
- exact proof bytes and every oracle gate pass;
- peak live and scratch bytes remain within the explicit budget;
- cold setup, warm proof, and sustained queue measurements remain separate.

If compute-to-leaf fusion alone does not improve a wide affected row, retain the sink contract only
if it is performance-neutral and required by a separately accepted resident backend; otherwise
revert that mechanism. If bounded numerator tiles improve wide traces but regress small shapes,
retain both implementations behind the measured shape policy. No benchmark-specific exception is
accepted.

## Generalization Across The Suite

The contract is placed below frontend and AIR selection. Native Fibonacci, XOR, state machine,
PLONK, Poseidon, Blake, Cairo, virtual SNOS, SNIP-36, and SN PIE proving all construct a first FRI
quotient through the same PCS path when using the standard engine. Their row counts, widths,
sample-batch counts, and sparsity influence only the shape policy and reported work, never semantic
selection by name.

For CPU, the immediate value is a bounded cache-oriented stage program and a stable place to add
later measured SIMD leaf hashing. For Cairo and block proving, complete-column combined intermediates
grow with width, so bounded scratch also controls peak memory and makes repeated requests suitable
for future request slots. For Native narrow traces, the compatibility crossover prevents fixed tile
overhead from dominating.

For Metal, `commitLazyMerkle` already represents the correct high-level transaction: produce a
retained quotient column and a Merkle tree before the transcript root barrier. The later resident
implementation replaces CPU writers with arena ranges and encode-only kernels, but the lifetime and
failure rules remain the same. A command epoch may submit only after all offsets and capacities are
validated; it waits once, transfers its completed arena lease to the first-layer prover, and exposes
the root only after success.

This architecture therefore advances the whole prover rather than one benchmark. It joins a common
producer and consumer at their ownership boundary, keeps the mathematical protocol unchanged, and
leaves both CPU SIMD and Metal residency as backend-specific implementations of one measured
commitment transaction.

## Accepted Leaf-Fusion Evidence

Commit `7301925` implements stages 1 and 2 without yet replacing the complete-column combined
coordinates. Quotient workers emit completed 256-row output views to worker-local first-layer
writers before those cache lines cool. The leaf sink owns one preallocated layer, validates an
ordered disjoint worker partition, and transfers the layer only after every writer covers its exact
range. Internal Merkle layers retain their existing executor and transcript boundary. A forced
legacy mode remains available for exact component A/B tests.

Allocation-failure checks cover the sink and owned-leaf tree builder. The tree builder reserves list
capacity before allocating each layer, so an append failure cannot strand an unowned layer. Tests
compare all four quotient coordinates, every Merkle layer, and the root across standard, fused, and
legacy construction. Tiled telemetry reports zero post-compute leaf passes while explicitly
reporting that complete-column combined intermediates still remain for the next stage.

A reversed-order ReleaseFast `log12x16` profile used three warmups and 11 samples. Two repetitions
measured quotient-stage reductions from 3.957 to 3.313 ms and from 3.762 to 3.413 ms, or 19.4 and
10.2 percent. Profiled whole-proof gains were 8.5 and 4.2 percent. A separate five-warmup,
21-sample unprofiled repetition improved from 6.124 to 5.708 ms and from 6.333 to 5.705 ms, or 7.29
and 11.01 percent. Every sample emitted the deterministic canonical digest.

The longer 101-sample three-row A/B then measured:

| Workload | Legacy prove (ms) | Fused prove (ms) | Fused row MHz | Gain |
| --- | ---: | ---: | ---: | ---: |
| `log10x8` | 2.039208 | 1.879833 | 0.544729 | 8.48% |
| `log12x16` | 6.079459 | 5.610291 | 0.730087 | 8.36% |
| `log14x32` | 15.397833 | 15.013750 | 1.091266 | 2.56% |

The geometric-mean prove-time gain is 6.43 percent. The clean formal CPU/Metal matrix remained
headline-eligible with one session tower per lane and exact backend parity. The pinned Rust Stwo
verifier accepted all six artifacts. Removing complete-column combined coordinates is the next
separately measured stage; its acceptance must preserve this leaf-fusion baseline.

## Accepted Bounded-Input Evidence

Commit `9a56af9` implements stage 3. The CPU provider now retains compact borrowed column views and
contribution ranges, accumulates `[sample_batch][secure_coordinate][tile_row]` numerator planes in
bounded worker-local SoA scratch, and passes each completed 256-row tile into the accepted
first-layer writer. It does not construct complete-column combined-coordinate arrays for the
bounded path. The raw backend contract is unchanged, and the compatibility implementation remains
directly selectable for parity and crossover measurements.

The automatic policy is based only on lifting geometry: lifting logs below 13 retain the
compatibility path, while lifting logs 13 and above select bounded inputs. It does not inspect the
example, frontend, AIR, or PIE identity. A richer active-column/contribution policy remains stage 4
work and requires a broader shape sweep before it can replace this measured boundary.

The exact component fixture reports 8,192 bytes of numerator planes and 18,432 bytes of total peak
scratch per worker, with zero complete-column combined-coordinate bytes and zero post-compute leaf
passes. The compatibility path reports 40,960 bytes of worker scratch plus 131,584 bytes of
complete-column coordinates, or 172,544 bytes of retained working state. The bounded path therefore
reduces that fixture's retained working state by 89.32 percent.

An immutable `653cccd` ReleaseFast binary and the candidate were compared with identical Native
wide-Fibonacci descriptors. The small row explicitly exercised compatibility mode; the medium and
wide rows exercised bounded mode.

| Workload | Input mode | Before prove (ms) | After prove (ms) | After row MHz | Change |
| --- | --- | ---: | ---: | ---: | ---: |
| `log10x8` | compatibility | 1.854917 | 1.878083 | 0.545237 | -1.25% |
| `log12x16` | bounded | 5.597292 | 5.341125 | 0.766880 | +4.58% |
| `log14x32` | bounded | 15.069250 | 12.634583 | 1.296758 | +16.16% |

The small compatibility movement remains inside the 2 percent affected-row gate. A separate
profiled `log12x16` A/B reduced the quotient stage from 3.367 to 2.881 ms, or 14.43 percent, and
reduced complete profiled proof time from 6.339459 to 5.811958 ms, or 8.32 percent.

Every repeated candidate artifact was byte deterministic and matched the immutable baseline:

| Workload | Proof bytes | Canonical proof SHA-256 |
| --- | ---: | --- |
| `log10x8` | 23,569 | `1beb388cda4e2941e5a65c11653d78de3116ae95a686538105312c29ff9f6f0c` |
| `log12x16` | 32,853 | `2e5d5b3847d3231073f9bcf5a6e89da2b2c8f847f52d73b7de5aa2899598e6e8` |
| `log14x32` | 44,225 | `9446656c07382cdc196304883693b51afe9603bfd149a602c8757db4bed4bbec` |

Tests compare every quotient coordinate, every Merkle layer and root, forced compatibility output,
and repeated worker output. Allocation-failure injection covers partial bounded-provider state and
worker scratch. The medium candidate artifact was accepted by the pinned Rust Stwo verifier at
`a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`; Zig tests, API parity, source conformance, formatting,
and diff checks also passed.

One attempted inner-loop change hoisted numerator-plane slices outside the row loop. It improved a
single unprofiled pair by roughly 0.8 percent, but reversed profiled medians regressed the quotient
stage from 2.700 to 2.713 ms and the complete proof from 5.343 to 5.429 ms. It was reverted. The
next CPU change must start from a fresh profile of `9a56af9`; this stage does not justify speculative
inner-loop rewrites.
