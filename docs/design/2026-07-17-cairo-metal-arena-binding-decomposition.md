# Cairo Metal Arena Binding Decomposition

Status: required, staged behind the active Cairo parity fix

## Decision

`src/integrations/cairo_metal/arena_binding.zig` is not an accepted monolith. At the 2026-07-17
audit it contains 6,960 manually maintained lines, more than eight times the 850-line soft ceiling
in [`CONTRIBUTING.md`](../../CONTRIBUTING.md). It is smaller than the 7,627-line source-conformance
baseline, so the ratchet has started working, but it still combines independent ownership and
change boundaries.

There is no performance or protocol reason for those boundaries to remain in one source file. Zig
module extraction does not require dynamic dispatch, allocation, copies, extra command buffers, or
GPU synchronization. The resident arena is a shared lifetime mechanism, not a reason for one file
to own every proving stage.

This document is the required decomposition plan for the existing baseline entry
`file-size:integrations/cairo_metal/arena_binding.zig`. It is intentionally parallel to, not part
of, the immediate Stwo-Cairo parity change. In particular, the multiplicity-feed code must not be
moved while its runtime geometry is being corrected.

## Audit

The file currently imports frontend statement/witness policy, generic prover mathematics, Metal
runtime and recipe types, transcript diagnostics, code generators, and schedule bindings. Its
top-level regions are:

| Current lines | Approximate size | Responsibility |
| --- | ---: | --- |
| 30-1,161 | 1,132 | Public contracts, proof-wide binding discovery, phase preparation, validation |
| 1,162-1,554 | 393 | Relation component binding and execution |
| 1,555-1,962 | 408 | Execution/preprocessed loading, evaluation, spill, and restore |
| 1,963-2,080 | 118 | Forward and inverse twiddle materialization |
| 2,081-2,437 | 357 | Fixed tables and multiplicity-feed preparation |
| 2,438-2,935 | 498 | Base and preprocessed interpolation |
| 2,936-3,881 | 946 | EC/AOT witness preparation, inputs, and witness DAG execution |
| 3,882-4,771 | 890 | Interaction DAG execution and CPU/GPU diagnostics |
| 4,772-5,208 | 437 | Gathered witness input and composition preparation |
| 5,209-5,754 | 546 | Decommitment pointers, ordering, LDE, and assembly binding |
| 5,755-6,410 | 656 | Streaming commitment, diagnostics, and proof-copy construction |
| 6,411-6,960 | 550 | Fourteen unrelated unit-test groups |

The line count reflects real coupling, not comments or generated tables. The largest individual
ownership violations are:

- `PreparedProofBindings`, 999 lines, mixes a binding index with all phase factories and execution;
- `executeStreamingCommitmentWithMode`, 454 lines, owns LDE, leaf absorption, retained Merkle
  layers, command epochs, debug repair policy, and telemetry;
- `prepareCompositionRecipe`, 384 lines, mixes runtime configuration, library loading, descriptor
  construction, component policy, and recipe construction;
- `executeScheduledWitnessGraph`, 297 lines, and `executeScheduledInteractionGraph`, 267 lines,
  duplicate orchestration shape while hiding different stage invariants;
- `prepareAotWitnessBatchForMode`, 236 lines, combines semantic descriptor projection, address-width
  validation, code generation, library ownership, and Metal recipe construction;
- interaction diagnostics occupy about 530 lines in the execution region and are enabled through
  process-global environment lookups.

The module therefore violates progressive disclosure: a caller looking for proof geometry must
read past commitment execution, and a caller looking for feed geometry inherits composition,
decommitment, filesystem, diagnostics, and field-arithmetic context.

## Invariants

Every extraction must preserve all of these constraints:

1. The pinned Rust Stwo-Cairo revision is the final correctness oracle. Structural equivalence and
   Zig-only tests are necessary but not sufficient for any slice that can affect proof bytes,
   transcript order, claimed-sum order, roots, openings, or verifier input.
2. Schedule lookup is exact. No module may infer a binding from allocation order, physical offset,
   or an SN2-only cardinality.
3. Runtime Cairo geometry remains authenticated by the statement and semantic artifacts. An
   extraction must not introduce fallback geometry or silently substitute fixture dimensions.
4. The four trace-tree roles remain `preprocessed`, `base`, `interaction`, and `composition` in
   canonical Rust order. Commitment degree order and AIR trace-span order remain distinct.
5. FRI round count, decommitment tree geometry, proof-copy order, and transcript ordinals remain
   runtime-derived and fail closed on inconsistent cardinality.
6. Arena bindings retain byte alignment, complete extent, non-aliasing, and active-lifetime checks.
   Narrow 32-bit shader addresses are used only after the entire binding extent is proven to fit.
7. Ownership of prepared Metal recipes remains explicit. Every successful initializer has one
   matching `deinit`, and partial initialization remains protected by `errdefer`.
8. Extraction adds no GPU dispatch, command buffer, wait, host/device copy, allocation, environment
   lookup, or runtime indirection to a proving request.
9. Logging and profiling remain opt-in and cannot alter proof contents or scheduling.
10. The public `arena_binding` symbol names remain available during migration. Internal field
    accesses may move to typed phase views only in a focused compile-checked slice.

## Target Layout

```text
src/integrations/cairo_metal/
|-- arena_binding.zig                 compatibility facade; explicit exports only
|-- resident/
|   |-- mod.zig                       subsystem map and invariants
|   |-- errors.zig                    stable integration error contract
|   |-- session.zig                   phase ordering over prepared typed views
|   |-- proof_bindings.zig            authenticated schedule-to-view projection
|   |-- transcript.zig                transcript recipe and challenge publication
|   |-- relations.zig                 relation binding, execution, claimed sums
|   |-- twiddles.zig                  twiddle-bank layout and materialization
|   |-- preprocessed/
|   |   |-- coefficients.zig          load, canonicalization, and evaluation
|   |   `-- storage.zig               spill/restore and retained-layer files
|   |-- lookups/
|   |   |-- fixed_tables.zig          fixed-table preparation/indexing
|   |   `-- multiplicity_feeds.zig    runtime feed geometry and prepared batch
|   |-- interpolation/
|   |   |-- batches.zig               recorded/native batch ownership
|   |   `-- columns.zig               component and generic circle IFFT mapping
|   |-- witness/
|   |   |-- inputs.zig                CASM, builtin, direct, compact, gathered input
|   |   |-- prepare.zig               EC and AOT recipe construction
|   |   `-- execute.zig               deterministic base-witness DAG execution
|   |-- interaction/
|   |   |-- execute.zig               deterministic interaction DAG execution
|   |   `-- diagnostics.zig           opt-in host/GPU comparison and digests
|   |-- composition/
|   |   |-- config.zig                bounded diagnostic/fusion configuration
|   |   `-- prepare.zig               descriptors and recipe ownership
|   |-- decommit/
|   |   |-- bindings.zig              trace/FRI typed views and pointer tables
|   |   |-- ordering.zig              canonical column/query reordering
|   |   `-- execute.zig               trace LDE and authenticated opening schedule
|   |-- commitment/
|   |   |-- ordering.zig              canonical versus degree-sorted columns
|   |   |-- execute.zig               LDE, leaf absorption, Merkle parent chain
|   |   |-- telemetry.zig             timings and opt-in digest sampling
|   |   `-- benchmark.zig             explicit synchronous benchmark mode
|   |-- quotient.zig                  quotient recipe binding
|   |-- fri.zig                       runtime FRI recipe binding
|   `-- proof_assembly.zig             exact proof-copy layout and recipe
`-- tests are mirrored under src/tests/cairo_metal/
```

`resident/mod.zig` and the final `arena_binding.zig` are maps, not warehouses. Neither contains an
algorithm. The nested layout is warranted because witness generation, interaction construction,
commitments, and openings have separate invariants, test oracles, performance profiles, and rates
of change.

## Symbol Ownership

The following map is normative. A symbol should move with its implementation and tests; forwarding
wrappers are temporary compatibility aids, not final ownership.

### Binding, session, and phase contracts

| Target | Symbols currently in `arena_binding.zig` |
| --- | --- |
| `resident/errors.zig` | `Error` |
| `resident/proof_bindings.zig` | `PreparedProofBindings.initSn2`, `init`, `initInternal`, `deinit`, `validate`, `validateSn2`; `validateDisjointBindings`, `validateDisjointActiveBindings`, `bindingHasActiveTick`; proof-wide typed binding fields |
| `resident/session.zig` | Compatibility methods that order or delegate proving phases; no schedule scanning, Metal encoding, or protocol arithmetic |
| `resident/transcript.zig` | `prepareTranscript`, `restoreCommitmentRoot`, `materializeRelationChallenges`, `restoreRelationChallenges`, `publishInteractionClaim`, `TranscriptBootstrapValidationOptions`, `validateTranscriptBootstrap`, `restoreTranscriptBootstrap` |
| `resident/quotient.zig` | `prepareQuotient` and its `QuotientBindings` view |
| `resident/fri.zig` | `prepareFri`, `runtimeFriGeometry` and its `FriBindings` view |
| `resident/proof_assembly.zig` | `ProofCopy`, `prepareProofAssembly`, `buildProofCopies`, `proofCopyTranscriptOrdinals`, `collectAssembly` |

`PreparedProofBindings` must stop being a flat god object. Its final representation is an owning
aggregate of phase views:

```zig
pub const PreparedProofBindings = struct {
    allocator: std.mem.Allocator,
    commitments: commitment.Bindings,
    composition: composition.Bindings,
    relations: relations.Bindings,
    quotient: quotient.Bindings,
    fri: fri.Bindings,
    transcript: transcript.Bindings,
    decommit: decommit.Bindings,
    proof: proof_assembly.Bindings,
};
```

Each phase owns `bind(schedule, plan, authenticated_geometry)` and `validate()` for its fields.
Cross-phase alias and cardinality checks remain in `proof_bindings.zig`. During migration the
existing methods remain thin delegates so callers do not need a flag day. After all in-repository
field accesses use typed views, removal of flat compatibility fields is a separately reviewed API
change.

### Relations, preprocessing, lookups, and interpolation

| Target | Symbols currently in `arena_binding.zig` |
| --- | --- |
| `resident/relations.zig` | `countFixedRelationTraces`, `relationTraceUsesRowEnabler`, `RelationComponentTelemetry`, `RelationComponentOperation`, `PreparedRelationComponents`, `BoundRelationComponent`, `canonicalClaimedSumBindings`, `validateClaimedSumOrder`, `bindRelationComponent`, `prepareRelationComponentBatch`, `prepareRelations`, `prepareRelationComponents`, `logRelationDiagnostics` |
| `resident/preprocessed/coefficients.zig` | `populateExecutionTables`, `populatePreprocessedCoefficients`, `PreprocessedCoefficientLoad`, `populateUnreconstructedPreprocessedCoefficients`, `PreprocessedCoefficientLoadMode`, `populatePreprocessedCoefficientsMode`, `canonicalizeSimdCoefficientBlocks`, `evaluatePreprocessedCoefficients` |
| `resident/preprocessed/storage.zig` | `spillPreprocessedEvaluations`, `spillRetainedMerkleLayers`, `restoreRetainedMerkleLayers`, `restorePreprocessedEvaluations`, `restoreFixedTablePreprocessedEvaluations` |
| `resident/twiddles.zig` | `populateProtocolTwiddles`, `populateForwardTwiddles`, `populateForwardTwiddleBinding`, `twiddleBankBinding`, `populateNamedInverseTwiddles`, `populateQuotientInverseTwiddles`, `populateTwiddlePair`, `populateInverseTwiddles`, `populateSplitSubdomainInverseTwiddles`, `twiddleBindingForLog`, `twiddleOffsetForLog` |
| `resident/lookups/fixed_tables.zig` | `prepareFixedTableBatch`, `fixedLookupIndex`, `clearFixedMultiplicities`, `multiplicityDestination` |
| `resident/lookups/multiplicity_feeds.zig` | `MultiplicityFeedBatch`, `runtimeFeedRowCount`, `runtimeFeedDestinationColumnBytes`, `recordFeedDestinationWidth`, `aotBindingFitsNarrowAddress`, `recordAotHighBinding`, `prepareMultiplicityFeedBatch` |
| `resident/interpolation/batches.zig` | `RecordedBaseInterpolationBatch`, `FixedBaseTraceOperation`, `NativeBaseInterpolationBatch`, `prepareRecordedBaseInterpolation`, `prepareNativeBaseInterpolation` |
| `resident/interpolation/columns.zig` | `prepareComponentInterpolation`, `prepareComponentInterpolationGroups`, `prepareComponentInterpolationGroupsForPurposes`, `interpolateTraceColumns`, `interpolateAvailablePreprocessedColumns` |

The fixed-table module may call multiplicity destinations through an explicit typed destination
map. It must not reach into feed program encoding. Conversely, feed preparation may consume fixed
table dimensions but may not own fixed-table storage policy.

### Witness and interaction execution

| Target | Symbols currently in `arena_binding.zig` |
| --- | --- |
| `resident/witness/prepare.zig` | `WitnessRecipeRequirements`, `WitnessRecipes`, `prepareEcOpWitness`, `prepareAotWitnessBatch`, `prepareAotInteractionBatch`, `prepareAotWitnessBatchForMode` |
| `resident/witness/inputs.zig` | `populateCasmWitnessInputs`, `populateBuiltinSeedWitnessInputs`, `populateDirectWitnessInput`, `gatheredWitnessRealRows`, `prepareCompactWitnessInput`, `gatherWitnessInput` |
| `resident/witness/execute.zig` | `WitnessEdge`, `WitnessExecutionTelemetry`, `witnessIndex`, `dependenciesReady`, `executeRecordedWitnessGraph`, `executeNativeEcConsumer`, `executeScheduledWitnessGraph` |
| `resident/interaction/execute.zig` | `InteractionExecutionTelemetry`, `executeScheduledInteractionGraph`, `interactionOperation` |
| `resident/interaction/diagnostics.zig` | `logInteractionWriterCpuSample`, `logLookupRelationCpuClaim`, `logComponentInteractionDigests`, `logComponentBaseEvalDigests`, `logInteractionCoefficientDigests`, `logLogicalBindingDigest`, `logCpuColumnLdeDigest` |

Base and interaction execution share the frontend-owned proof-plan DAG and scheduler contracts.
They do not import each other. A later measured refactor may extract a generic scheduler runner only
if it reduces concepts without hiding base-versus-interaction stage policy.

### Composition, decommitment, commitments, and proof output

| Target | Symbols currently in `arena_binding.zig` |
| --- | --- |
| `resident/composition/config.zig` | Parsing and validation now embedded in `prepareCompositionRecipe`: fusion request/cap, source/library selection, component limit, diagnostic component |
| `resident/composition/prepare.zig` | `prepareComposition`, descriptor construction from `prepareCompositionRecipe`, `descriptorWordOffset`, `compositionRandomCoefficientBase`, `compositionComponentLimit` |
| `resident/decommit/bindings.zig` | `DecommitTraceCoefficientBindings`, `DecommitTraceGroupBindings`, `DecommitTraceTreeBindings`, `DecommitFriTreeBindings`, `TraceTreeRole`, `TraceTreeGeometry`, `FriTreeGeometry`, `ProofDecommitGeometry`, `prepareDecommitQueries`, `decommitTraceTree`, `decommitFriTree`, `writeBindingOffsets`, `writeWideWordOffset`, `writeWideBindingOffsets`, `writePreprocessedOffsets`, `collectPreprocessedBindings`, `bindingWords`, `populateTraceRetainedPointers`, `populateFriRetainedPointers`, `populateFriCoordinatePointers`, `populateSparseOffsets` |
| `resident/decommit/ordering.zig` | `reorderTraceQueryValues`, `reorderColumnMajorValues` |
| `resident/decommit/execute.zig` | `executeSn2Decommit`, `executeDecommit`, `executeDecommitTraceLdeGroup` |
| `resident/commitment/ordering.zig` | `collectCommitmentOrder`, `sortCanonicalCommitmentOrder`, `commitmentOrderCopy`, `canonicalTraceTree`, `collectTreePurpose` |
| `resident/commitment/execute.zig` | `CommitmentTelemetry`, `executeCommitment`, `commitmentScratchBytes`, `populateCommitmentTwiddles`, `populateCommitmentInverseTwiddles`, `commitmentTwiddleStorage`, `commitmentTwiddleBinding`, `executeStreamingCommitment`, the LDE/leaf/Merkle algorithm now in `executeStreamingCommitmentWithMode` |
| `resident/commitment/telemetry.zig` | `logCommitSourceDigests`, `logCommitLdeDigests`, `logBindingDigest`, `logCommitStepSamples`, `sampleCommitOutputs` |
| `resident/commitment/benchmark.zig` | `StreamingCommitmentBenchmarkMode`, `executeStreamingCommitmentBenchmark`; benchmark-only synchronous policy |

The debug-only column-repair filesystem block currently embedded in commitment execution is not a
production commitment responsibility. Before `commitment/execute.zig` is accepted, move that block
behind an explicit diagnostic adapter or delete it after its parity investigation. Production
execution must not create `/tmp` files or conditionally rewrite LDE values.

## Dependency Direction

Allowed dependencies are deliberately one-way:

```text
frontends/cairo semantic artifacts and proof plan
                         |
backends/metal arena plan, runtime, protocol recipes
                         |
integrations/cairo_metal/schedule_bindings
                         |
resident leaf modules (lookups, interpolation, witness, interaction,
                       composition, commitment, FRI, decommitment)
                         |
resident/proof_bindings.zig
                         |
resident/session.zig
                         |
arena_binding.zig facade -> tools, tests, benchmarks
```

More precisely:

- leaf modules consume typed `arena_plan.Binding` views and semantic bundles; they never import
  `session.zig`, `proof_bindings.zig`, the facade, a CLI, or a benchmark;
- `proof_bindings.zig` imports binding contracts from leaf modules and projects the authenticated
  schedule into them; it performs no Metal execution;
- `session.zig` imports the prepared views and phase operations and owns request ordering; it does
  not parse JSON schedule entries or process environment variables;
- diagnostic modules may import production types, but production modules receive a nullable/no-op
  diagnostic sink and do not import benchmark policy;
- `commitment/benchmark.zig` imports `commitment/execute.zig`; the production executor never imports
  the benchmark module;
- generic Metal backend code remains unaware of Cairo, and Cairo frontend code remains unaware of
  Metal. This integration layer is the only bridge;
- no module imports `arena_binding.zig` from below it.

To avoid import cycles while preserving methods, phase functions take narrow argument structures
owned by the phase module. Temporary `PreparedProofBindings` methods construct those arguments and
delegate. Passing slices and bindings by value adds no device transfer or heap allocation.

## Staged Migration

Each stage is a focused pure-move commit unless explicitly stated otherwise. Do not mix a move with
kernel fusion, layout tuning, transcript changes, or feed-geometry correction.

### Stage 0: freeze the contract

1. Add source tests that enumerate the facade's current public declarations used by tools, tests,
   and benchmarks.
2. Record a small Fib Cairo proof's Rust-verified transcript checkpoints, four roots, claimed sums,
   FRI roots, proof length, and proof digest.
3. Record a host-only target schedule binding report for runtime geometry and a bounded Metal smoke
   that reaches the same stage before and after each move.

This stage is complete only after the active feed-geometry parity fix lands. Its new regression
test becomes part of the multiplicity-feed module contract.

### Stage 1: diagnostics and storage leaves

1. Extract interaction diagnostics to `interaction/diagnostics.zig`.
2. Extract commitment diagnostics to `commitment/telemetry.zig`.
3. Extract preprocessed spill/restore to `preprocessed/storage.zig`.
4. Extract preprocessed loading/evaluation and twiddles to their leaf modules.

These symbols have narrow dependencies and do not own phase order. Moving them first reduces the
import surface without touching the active feed path.

### Stage 2: lookup and interpolation ownership

1. After feed parity is committed, move `MultiplicityFeedBatch` and all runtime geometry checks as
   one unit to `lookups/multiplicity_feeds.zig`.
2. Move fixed-table preparation separately.
3. Move column interpolation, then its recorded/native owning batches.
4. Replace private cross-region calls with typed destination and interpolation views. Do not add a
   generic `helpers.zig`.

The runtime feed row count and every destination column extent must continue to derive from the
target schedule. Reusing source-SN2 row counts is a test failure.

### Stage 3: witness and interaction DAGs

1. Move input materialization and gathered-input construction.
2. Move EC/AOT recipe preparation with codegen ownership intact.
3. Move base witness execution and its tests.
4. Move interaction execution and its tests.

Keep deterministic scheduler hooks and recipe ownership visible. Do not unify the two graph runners
until a separate design demonstrates a smaller interface and unchanged profiler attribution.

### Stage 4: relations and composition

1. Move the complete relation component binding/operation lifecycle with claimed-sum order tests.
2. Separate composition configuration parsing from recipe construction without changing current
   defaults or environment compatibility.
3. Move composition descriptor construction and its random-coefficient addressing tests.

The relation and composition moves require Rust oracle checkpoints because a binding-order change
can produce plausible but invalid field values.

### Stage 5: commitments and decommitment

1. Extract canonical/degree commitment ordering.
2. Extract the production commitment executor, retaining the exact command-epoch and retained-layer
   behavior. Move benchmark-only synchronous selection afterward.
3. Extract decommit typed views and pointer population, then ordering, then execution.
4. Remove the debug repair filesystem path from production ownership.

The 454-line commitment function should be split by named internal stages, not wrappers:
`prepareLdeGroups`, `encodeLdeAndLeaves`, `planRetainedParents`, `encodeParentChain`, and
`publishRoot`. A single command epoch may span these functions; source decomposition must not split
the GPU epoch or add waits.

### Stage 6: disaggregate proof bindings

1. Give each phase a `Bindings` type and `bind`/`validate` functions.
2. Change `PreparedProofBindings` to own those phase views.
3. Move cross-phase invariants into `proof_bindings.zig`.
4. Reduce existing methods to compatibility delegates in `session.zig`.
5. Update in-repository callers from flat field access to named phase views.

This is the only intentionally cross-file structural stage and should be submitted as a short
stack: phase views, projection, caller migration, compatibility cleanup.

### Stage 7: facade and tests

1. Make `arena_binding.zig` an explicit facade below 250 lines.
2. Make `resident/mod.zig` an explicit map below 150 lines.
3. Move embedded tests to mirrored `src/tests/cairo_metal/` modules or keep focused leaf tests next
   to their private implementation when private invariants require it.
4. Remove `file-size:integrations/cairo_metal/arena_binding.zig` from
   `docs/conformance/source-baseline.json` only when the facade and every new manually maintained
   module are within their reviewed limits.

## Size Budgets

The target is not a spray of forwarding files. Each leaf must hide a meaningful invariant and stay
within these budgets:

| Module class | Budget |
| --- | ---: |
| Facade or `mod.zig` | 250 lines |
| Binding projection/session | 650 lines |
| Routine leaf | 500 lines |
| Stateful Metal execution leaf | 650 lines |
| Cohesive commitment/decommit HPC leaf | 850 lines |
| Focused test module | 500 lines |

No new module receives a baseline exception as part of this migration. If an extraction cannot fit
its budget, split it by ownership before moving it; do not transfer the legacy exception to a new
path.

## Verification Gates

Every move runs the narrowest relevant tests plus the shared structural gates:

```bash
zig build fmt
python3 scripts/check_source_conformance.py
zig build test
zig build api-parity
```

Stage-specific requirements are:

| Area | Required focused evidence |
| --- | --- |
| Binding projection | exact target schedule report, missing/duplicate/alias/cardinality negatives |
| Feed/fixed tables | runtime-row geometry test, destination extent test, narrow-address overflow test |
| Interpolation | scalar/circle evaluation parity across logs and component group boundaries |
| Witness/interaction | deterministic DAG order, dependency failure, component accumulator checkpoint parity |
| Relations/composition | claimed-sum order, descriptor/random-power addressing, per-component Rust oracle checkpoints |
| Commitment | all four Rust-equal roots, retained-layer parity, no added command/wait/copy counters |
| FRI/decommitment | runtime 7- and 8-round geometry, query/order parity, opening tamper rejection |
| Proof assembly | exact proof length/digest and pinned Rust `verify_cairo` acceptance |

For any move at or below commitments, transcript, FRI, decommitment, or proof assembly, the final
gate is:

```bash
cargo test --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml
```

The focused Fib artifact is the fast oracle loop. Before removing the legacy baseline, also run one
non-Fib Cairo program and one large/wide SN PIE through the same production path. Metal hardware
gates remain serial and bounded; pure source moves do not justify a large thermal benchmark.

## Performance Acceptance

A source split is expected to be performance-neutral. For stages that encode Metal work, compare
before and after with identical binaries/workloads and require:

- identical proof digest and pinned Rust verification;
- identical command-buffer, encoder, dispatch, wait, allocation, and host/device-copy counts;
- no new runtime compilation or environment lookup;
- complete prove/request time movement within the established noise band;
- unchanged peak resident arena bytes and no new retained allocation.

Do not attribute a speed improvement to a pure move. Any later optimization starts in a separate
commit from a fresh profile so its mechanism and regression surface remain reviewable.

## Completion Criteria

The decomposition is complete only when:

- `arena_binding.zig` is a facade below 250 lines;
- no new manually maintained module exceeds its budget or needs a baseline exception;
- every symbol in the ownership map has one implementation owner;
- the dependency direction is mechanically accepted by source conformance;
- production modules do not contain benchmark policy or debug filesystem repair paths;
- all flat proof-binding callers use named phase views or documented compatibility accessors;
- focused Zig tests, full Zig tests, API parity, and pinned Rust `verify_cairo` pass;
- a non-Fib Cairo program and a wide SN PIE verify through the same path;
- Metal structural counters show no extraction-induced dispatch, copy, wait, allocation, or memory
  regression;
- the legacy source-conformance baseline entry is removed.
