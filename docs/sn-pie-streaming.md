# SN PIE persistent Metal proving

Status: implementation design, 2026-07-15  
Audited against commit `f45b8ac` plus the active Metal parity worktree. Line
numbers below identify extraction scopes in that worktree; symbol names are the
stable boundary when later edits move the lines.

This document remains the detailed extraction record for the persistent
session and self-contained proof path. The normative end-to-end architecture,
performance budget, dataflow, and milestone gates are consolidated in
`docs/sn-pie-metal-production-architecture.md`; that document takes precedence
where the plans differ.

The first cold production-boundary smoke is recorded in
`/private/tmp/sn-pie-production-smoke-verified/queue-report.json`: raw SN2
execution/adaptation took 2.023 seconds, the verified Metal proof scope took
13.897 seconds (0.5740 MHz), and total one-shot queue wall was 20.916 seconds
(0.3814 MHz sustained). This validates ingestion and proof delivery, not the
persistent session described below.

## Objective

Run a mixed queue of adapted SN PIE blocks in one process while retaining:

- one `metal.Runtime`, command queue, loaded metallibs, binary archives, and PSOs;
- parsed immutable protocol artifacts and geometry-specific prepared plans;
- one resident arena allocation sized for the largest compatible geometry; and
- immutable preprocessed coefficients/evaluations, tree-0 data, and twiddles on
  device when their content and placement keys match.

Every block still gets a fresh transcript, multiplicities, witness data, roots,
FRI state, decommitment state, proof output, timers, and verifier result. The
session is serial and non-reentrant for the MVP. No block may begin reset while
a previous command buffer is in flight.

The proving rate remains:

```text
adapted Cairo cycles / recorded-witness-start-to-verified-proof seconds / 1e6
```

Pipeline/library preparation is reported separately and must not be hidden in
the proving timer.

## Current one-shot ownership

`src/metal_arena_plan_cli.zig:65-1925` currently owns the whole lifecycle in
`main`. The following state should be split by lifetime.

| Current scope | State | New owner |
| --- | --- | --- |
| `65-83` | allocator, arguments, schedule JSON bytes/value, schedule digest | artifact/geometry entry |
| `84-132` | schedule coverage and witness/feed/relation/fixed/composition bundles | artifact cache |
| `133-164` | adapted `ProverInput`, transcript fixture, input-derived `CairoProofPlan` | block request plus geometry entry |
| `165-603` | staged liveness, logical buffers, full/projected arena plan | geometry entry |
| `652-662` | `PreparedProofBindings` | geometry entry |
| `663-715` | stage counters, roots, proof flags, timer, output sizes | block transaction |
| `716-721` | `metal.Runtime.init/deinit` | session |
| `722-803` | preprocessed/tree-0 restore or construction | persistent device state |
| `804-807` | `ResidentArena` allocation | session arena slot |
| `837-841` | `CairoMemoryTrace` binding graph | geometry entry |
| `844-880`, `931-968` | preprocessed upload/evaluation/tree-0 restore | geometry activation, once per compatible placement |
| `881-906` | execution tables and direct witness seeds from `ProverInput` | block transaction |
| `909-1043` | fixed/feed/AOT/compact/EC-op/interpolation preparation | geometry entry, except EC segment value |
| `1044-1153` | base witness, memory trace, interpolation, commitment execution | block transaction |
| `1154-1209` | transcript and interaction plan preparation | geometry entry |
| `1212-1397` | transcript bootstrap, interaction execution and commitment | block transaction |
| `1398-1424` | composition twiddles, metallib, `CompositionRecipe` preparation | geometry entry |
| `1427-1504` | composition, commitment, transcript and OODS execution | block transaction |
| `1505-1508` | `QuotientRecipe` preparation | geometry entry |
| `1511-1583` | quotient input materialization, execution and parity | block transaction |
| `1584-1603` | FRI twiddle restore and `FriRecipe` preparation | geometry entry |
| `1606-1635` | FRI commit/fold/finalize loop | block transaction |
| `1637-1668` | decommit and proof-assembly preparation | geometry entry |
| `1642-1735` | decommit, assembly, decode, verify, prove timer | block transaction |
| `1737-1925` | diagnostic aggregation and JSON output | CLI/report adapter |

The prepared objects are reusable because their Metal plans contain geometry,
arena offsets, and small descriptor buffers, while execution receives the
current resident arena buffer. This includes the fixed-table and feed batches,
AOT witness batches, compact recipes, interpolation batches, relation recipes,
composition, quotient, FRI, decommit, transcript, commitment, and proof assembly
plans.

Two current couplings must be split during extraction:

1. `CairoProofPlan.fromWitnessSchedule` derives exact `real_rows` from the
   adapted input at `src/frontends/cairo/proof_plan.zig:249-309`. Those row
   extents are part of the geometry key even when padded schedule sizes match.
2. `prepareEcOpWitness` reads the block's EC-op segment address and writes it to
   the arena at `src/frontends/cairo/witness/arena_binding.zig:2639-2645`.
   Prepared EC-op offsets and PSO state belong to geometry; writing
   `segment_start` belongs to `beginBlock`.

## Proposed API

Place the implementation in
`src/frontends/cairo/metal_prover_session.zig`. Keep the CLI as argument/env
translation only.

```zig
pub const ArtifactRef = struct {
    path: []const u8,
    sha256: [32]u8,
};

pub const ArtifactDescriptor = struct {
    schedule: ArtifactRef,
    witness_programs: ArtifactRef,
    multiplicity_feeds: ArtifactRef,
    relation_templates: ArtifactRef,
    fixed_tables: ArtifactRef,
    composition: ArtifactRef,
    composition_metallib: ArtifactRef,
    preprocessed_coefficients: ArtifactRef,
    preprocessed_evaluations: ArtifactRef,
    retained_tree0: ArtifactRef,
    tree0_root: [32]u8,
    pcs: PcsParameters,
};

pub const ParityFixtures = struct {
    transcript: ArtifactRef,
    quotient: ArtifactRef,
};

pub const BlockRequest = struct {
    input: *const cairo_adapter.ProverInput,
    input_sha256: [32]u8,
    adapted_cycles: u64,
    artifacts: *const ArtifactDescriptor,
    parity_fixtures: ?ParityFixtures = null,
};

pub const SessionOptions = struct {
    budget_bytes: u64,
    max_geometry_entries: usize = 4,
    require_verification: bool = true,
};

pub const MetalProverSession = struct {
    pub fn create(
        allocator: std.mem.Allocator,
        options: SessionOptions,
    ) !*MetalProverSession;

    pub fn destroy(self: *MetalProverSession) void;

    /// Serial and non-reentrant. The caller owns request slices until return.
    pub fn prove(self: *MetalProverSession, request: BlockRequest) !BlockResult;

    pub fn pipelineCacheStats(
        self: *const MetalProverSession,
    ) metal_runtime.PipelineCacheStats;
};

pub const BlockResult = struct {
    proof: []u32,
    verified: bool,
    prove_wall_s: f64,
    prove_mhz: f64,
    stage_gpu_ms: StageGpuTimes,
    session: SessionTelemetry,
    pipeline_cache_before: metal_runtime.PipelineCacheStats,
    pipeline_cache_after: metal_runtime.PipelineCacheStats,
    pipeline_cache_delta: metal_runtime.PipelineCacheStats,

    pub fn deinit(self: *BlockResult, allocator: std.mem.Allocator) void;
};
```

`create` returns a stable heap address. Prepared recipes store pointers to the
runtime and `ResidentArena`, so neither owner may move. The session holds a
stable heap-allocated arena slot; growing it replaces only the slot's buffer
after all work completes. Existing prepared recipes continue to dereference the
same slot.

`prove` performs these internal steps:

1. Validate every artifact digest before cache lookup.
2. Derive `ArtifactKey`, exact input row extents, and `GeometryKey`.
3. Reuse or prepare a `GeometryEntry`; grow the arena if required.
4. Activate compatible persistent device state.
5. Snapshot `Runtime.pipelineCacheStats()` and call `beginBlock`.
6. Upload/materialize the adapted input and execute the resident proof graph.
7. Assemble, decode, and cryptographically verify the proof.
8. Stop the prove timer only after verification succeeds.
9. Snapshot cache stats again, copy the compact proof, and return telemetry.
10. On any error, mark the active geometry dirty; the next request must perform
    a full non-persistent reset before reuse.

## Session data model

```zig
const MetalProverSession = struct {
    allocator: std.mem.Allocator,
    options: SessionOptions,
    runtime: metal_runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    arena_capacity_bytes: u64,
    artifact_cache: ArtifactCache,
    geometry_cache: GeometryCache,
    persistent_device_cache: PersistentDeviceCache,
    active_geometry: ?GeometryKey,
    block_ordinal: u64,
    in_flight: bool,
};

const GeometryEntry = struct {
    key: GeometryKey,
    schedule_json: std.json.Parsed(std.json.Value),
    proof_plan: cairo_proof_plan.CairoProofPlan,
    arena_plan: arena_plan.Plan,
    bindings: arena_binding.PreparedProofBindings,
    memory_trace: cairo_memory_trace.CairoMemoryTrace,
    recipes: PreparedProtocolGraph,
    reset_ranges: []const metal_runtime.ArenaClearRange,
    persistent_placement: PersistentPlacementKey,
    required_arena_bytes: u64,
    dirty: bool,
};
```

The MVP cache holds at most four geometry entries, enough for the local
`SN_PIE_1..4` queue. Eviction deinitializes prepared plans only; it does not
destroy the runtime, PSO cache, or binary archive state.

## Cache keys

Keys are content-derived. Paths are diagnostics, never identity.

`ArtifactKey` hashes:

- schedule, witness, feed, relation, fixed-table, and composition bytes;
- composition metallib canonical identity and SHA-256;
- preprocessed coefficient/evaluation/tree-0 bytes and declared root; and
- PCS/hash parameters, format versions, and backend ABI version.

`GeometryKey` hashes:

- `ArtifactKey` fields that affect bindings or generated kernel names;
- `arena.Plan.plan_hash`, total bytes, and every binding offset/size;
- canonical component order and every `(real_rows, padded_rows)` pair;
- builtin presence and segment lengths, excluding relocatable begin addresses;
- relation/fixed graph hashes and composition plan/part semantic hashes;
- FRI start log, fold schedule, query count, PoW bits, and blowup; and
- Metal device registry ID, OS build, and metallib identity for prepared-state
  invalidation.

`PersistentStateKey` hashes the preprocessed artifacts, tree-0 root, twiddle
geometry, hash seeds, and PCS parameters. `PersistentPlacementKey` additionally
hashes destination offsets and sizes. Device state may remain in the arena only
on an exact placement hit. A content hit with a placement miss uses a prepared
device-to-device copy from dedicated persistent storage; it must not reread the
spill files or recompute tree 0.

The runtime's library cache remains keyed by canonical metallib path, file size,
and modification time. The PSO cache is keyed by that library identity and
function name. These caches outlive all geometry entries.

## Reset invariants

`beginBlock` is a correctness boundary, not an optional optimization.

1. Assert `in_flight == false`; set it before the first submission and clear it
   only after completion/verification or error cleanup.
2. Clear all non-persistent arena ranges with prepared GPU clear ranges. Do not
   clear the whole multi-gigabyte allocation. A debug mode poisons these ranges
   before clearing to detect read-before-write bugs.
3. Preserve preprocessed coefficients/evaluations, retained tree-0 layers/root,
   and persistent twiddle banks only when `PersistentPlacementKey` matches.
   Otherwise activate them from the device cache.
4. Reset every recipe's `last_tick` to null and every
   `accumulated_gpu_ms` to zero. Reset `FriRecipe.finalized` to false,
   `WitnessFeedBatchRecipe.cleared` to false, and any epoch/recovery state to
   absent.
5. Zero runtime/fixed multiplicities before producers run. The feed batch must
   execute its clear/count protocol once per block, not once per session.
6. Rematerialize execution-table, input/output, multiplicity, Pedersen, Poseidon,
   and compact workspace pointer tables. Arena aliasing makes their previous
   contents invalid even when geometry is unchanged.
7. Overwrite all adapted-input destinations and their padded tails according to
   Cairo padding rules. Rewrite EC-op `segment_start` from this block's input.
8. Initialize the transcript and clear proof-visible transcript input/output
   bindings before publishing roots, claims, samples, or nonces.
9. Zero commitment roots, FRI challenges/layers/final-degree error, decommit
   counts/assembly, and proof output. No result flag or root array survives from
   the previous `BlockTransaction`.
10. Restore stage-local inverse/forward twiddles at their existing consumption
    boundaries when those ranges alias later stages. Session persistence does
    not remove the current quotient/FRI restore requirements.
11. Snapshot pipeline counters before preparation/execution. Block telemetry is
    the checked non-negative delta of monotonic session counters.
12. On failure after any GPU mutation, set `GeometryEntry.dirty = true`. Reuse
    requires a full reset; never return a partial proof or a proving speed.

Prepared recipe types currently expose mutable replay state directly. Add one
`resetForBlock()` method per aggregate graph rather than resetting fields from
the CLI. It must cover all recipe types in
`src/backends/metal/protocol_recipes.zig`, including AOT, circle, fixed-table,
Merkle, EC-op, compact, composition, witness feed, relation, quotient, FRI,
decommit, transcript, and proof assembly.

## Extraction sequence

1. Add `ArtifactDescriptor`, content hashing, and owned `ArtifactCache`. Move
   current bundle reads from CLI lines `77-180` without changing validation.
2. Extract `PreparedGeometry.build` from lines `189-662`. Its result owns the
   parsed schedule, proof/staged plans, arena plan, and proof bindings.
3. Allocate a stable session runtime/arena. Move `Runtime.init` from `720-721`
   and `ResidentArena.initByteLength` from `804-807` into session ownership.
4. Extract preparation calls from `909-1043`, `1154-1209`, `1402-1424`,
   `1505-1508`, `1584-1603`, and `1637-1668` into
   `PreparedProtocolGraph.init`.
5. Split EC-op geometry preparation from its per-input segment write at
   `arena_binding.zig:2639-2645`.
6. Add aggregate `resetForBlock`, prepared reset ranges, and debug poisoning.
7. Move execution from CLI lines `881-906`, `931-968`, `1044-1153`,
   `1212-1397`, `1427-1504`, `1511-1583`, and `1606-1735` into
   `MetalProverSession.prove` without reordering protocol operations.
8. Move lines `1737-1925` into a report adapter. The CLI may run one request;
   a persistent executor runs newline-delimited requests against one session.
9. Replace the Python queue's subprocess-per-block `Executor` behind its
   existing protocol at `scripts/sn_pie_metal_queue.py:93` with a persistent
   executor. Queue selection/adaptation remains unchanged.

## Queue reporting

Call `runtime.pipelineCacheStats()` immediately before block preparation and
after verification. Add these objects to every benchmark report:

```json
{
  "session": {
    "id": "stable-process-id",
    "block_ordinal": 7,
    "geometry_key": "hex",
    "geometry_cache_hit": true,
    "persistent_state_cache_hit": true,
    "arena_reused": true,
    "arena_capacity_bytes": 123
  },
  "pipeline_cache": {
    "before": {},
    "after": {},
    "delta": {
      "library_cache_hits": 0,
      "library_cache_misses": 0,
      "pipeline_cache_hits": 279,
      "binary_archive_hits": 0,
      "binary_archive_misses": 0,
      "direct_compiles": 0,
      "archive_populations": 0,
      "archive_serializations": 0,
      "pipeline_preparation_seconds": 0.001
    }
  }
}
```

`scripts/sn_pie_metal_queue.py:block_record` (`476-560`) should copy the session
and cache objects into each block. `queue_document` (`651-709`) should report
cumulative deltas, geometry/persistent hit rates, arena growth count, first-block
preparation cost, warm preparation cost, and warm proving MHz. Its
`execution_model` must change from subprocess-per-block to one persistent Zig
session. Existing fail-closed proof/timing checks remain unchanged.

## Acceptance criteria

### Ten blocks

- The seeded mixed queue completes all 10 requests in one process and one
  session; every proof is non-empty and cryptographically verified.
- Parity mode matches the SIMD/reference component accumulators, four commitment
  roots, transcript checkpoints, quotient digest, FRI roots, and decoded proof
  fields for every block. Alternating `A/B/A` yields the same verified result for
  both `A` runs when deterministic fixture nonces are enabled.
- Exactly one runtime is created. Arena allocation count is one plus bounded
  growth before the largest encountered geometry; no per-block arena allocation
  is allowed.
- Once a geometry has appeared, its next occurrence reports a geometry cache
  hit and performs no plan or recipe reconstruction.
- With the checked-in warm binary archive, direct compiles, archive misses, and
  archive populations are zero. The first use resolves PSOs from the archive;
  later uses of the same functions report PSO memory-cache hits.
- Preprocessed/tree-0 data is read from disk or computed at most once per
  `PersistentStateKey`. Compatible later blocks report a device-state hit.
- Pipeline counters are monotonic; every block contains before/after/delta and
  the deltas sum exactly to the queue cumulative values.
- Proving MHz uses only verified prove wall time. Preparation, adaptation, and
  queue latency remain separately reported.
- A debug poison/reset run produces the same parity result and reports no
  read-before-write/reset violation.

### One hundred blocks

- The deterministic 100-block mixed queue verifies 100/100 proofs without a
  process restart, fallback, fixture omission, timeout, or null MHz row.
- After all four local geometry keys have appeared, arena capacity, geometry
  cache size, metallib count, and persistent-device-cache size plateau. No
  monotonic per-block RSS or Metal allocated-size growth is allowed; the last 20
  blocks remain within 2% of the post-warm plateau and below the configured
  budget.
- Blocks after warm-up record zero direct compiles, binary archive misses,
  populations, and serializations. Pipeline preparation p95 is reported and is
  less than 1% of warm verified prove p50.
- Warm repeated geometries perform zero artifact disk reads, zero preprocessed
  host uploads, zero tree-0 recomputations, and zero recipe rebuilds.
- Report p50/p95 verified proving MHz per PIE, aggregate proving MHz, sustained
  queue MHz, p50/p95 end-to-end latency, adaptation cost, cache hit rates, arena
  growth, peak RSS, and peak footprint.
- Warm proving p50 for the last 50 blocks is no more than 10% slower than blocks
  11-50 for the same PIE, preventing hidden state accumulation.
- Failure injection at blocks 10, 50, and 90 proves fail-closed cleanup: the
  injected block emits no MHz/proof, marks the geometry dirty, and a fresh test
  queue can reset and reproduce the next block's reference result.

## Self-contained proof path

`MetalProverSession.prove(request)` treats `BlockRequest.parity_fixtures` as
optional, non-production diagnostics. A production request must not read either
reference file or reference environment variable. The current dependencies
fall into these groups.

**Derivable statement bootstrap.** `restoreTranscriptBootstrap` currently
copies transcript ordinals 1, 2, and 10-16 from
`STWO_ZIG_SN2_TRANSCRIPT_REFERENCE`. Ordinal 3/tree 0 and ordinal 20/tree 1 are
already commitment-produced and only checked. Replace the copy with canonical
serialization of the request channel salt and PCS configuration,
`CairoProofPlan` component claims/log sizes, and adapted-PIE public data. Keep
`bootstrapThroughBase()` unchanged. `STWO_ZIG_SN2_TRANSCRIPT_BOOTSTRAP` is the
same external-file fallback and is not a production dependency.

**Forced values with self-derived APIs.** A reference `interaction_nonce`
selects `interactionPowAndLookupNonce`; production calls
`interactionPowAndLookup()`. A reference `query_nonce` selects
`queryPowAndPositionsNonce`; production calls `queryPowAndPositions()`, stores
the returned nonce, and consumes its resident query positions. Different valid
nonces may change proof bytes without changing SIMD semantics.

**Derivable partial-mode fallback.** Quotient-without-OODS currently loads input
25 from the transcript fixture. A self-contained full proof always runs
`cairo_oods.populate`, followed by `compositionAndOods()` and
`oodsAndQuotient()`. Quotient-only mode must derive input 25 or reject the
request; it must not restore it from a fixture.

**Assertions only.** All `expectInputWords` and `expectOutputWords` checks are
optional parity assertions. This covers interaction claim/root, tree 2/3 roots,
OODS payload and draws, eight FRI roots, final coefficients, nonce words,
`STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2`, and the bootstrap checks for roots
3 and 20. Run them only when `parity_fixtures != null`.

**Quotient oracle only.** `cairo_quotient_inputs.populate` already materializes
sample points, first linear terms, and partials. `validateReferenceFixture`
never writes the arena; its payload checks and final quotient digest are parity
assertions. Make validation optional, execute quotient after
`populateQuotientInverseTwiddles`, and replace `QuotientParityRequired` with an
execution/completion gate.

**FRI oracle only.** `friLayer` publishes each computed root and draws each
folding challenge; `lastLayer` publishes final coefficients. Fixture comparisons
and `FriParityRequired` are diagnostics. Decommitment must instead require
completed, degree-valid FRI state.

Remove production dependencies in this order:

1. Add the canonical statement serializer and prove its ordinals match the
   fixtures in parity tests.
2. Use self-grinding `interactionPowAndLookup()`.
3. Require OODS population before quotient.
4. Make quotient reference validation/digest optional and gate on execution.
5. Run the existing FRI transcript without fixture comparisons and gate on
   final-degree validity.
6. Self-grind with `queryPowAndPositions()`.
7. Make benchmark/queue reference paths optional and expose them only through
   `BlockRequest.parity_fixtures`.

The first self-contained acceptance gate runs with both reference files absent
and `parity_fixtures = null`: one direct SN PIE proof must assemble and verify,
then the SN1-4 corpus must do so. The proof and same statement/claim must pass
both the resident verifier and Rust SIMD verifier. Statement serialization,
PCS/FRI configuration, Fiat-Shamir ordering, OODS shape, quotient semantics,
FRI degree check, PoW validity, and query count/positions must match SIMD.

Byte equality is required only in optional parity mode with reference nonces
forced. Production self-grinding may choose different valid nonces. Unit gates
compare derived bootstrap/OODS/quotient/FRI inputs with fixtures in parity tests
and reject tampered statements/proofs. The full-proof benchmark must not require
either CLI reference argument or set either reference environment variable.
