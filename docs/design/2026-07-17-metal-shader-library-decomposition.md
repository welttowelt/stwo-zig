# Metal Shader Library Decomposition

Status: required, behavior-preserving architecture migration

## Decision

`src/backends/metal/kernels.metal` is unjustified monolithic source debt under
[`CONTRIBUTING.md`](../../CONTRIBUTING.md). At the 2026-07-17 audit it contains 3,604 manually
maintained lines and 90 exported compute kernels. It is more than four times the 850-line ceiling
for a cohesive HPC/protocol module and combines cryptographic primitives, Cairo witness logic,
polynomial transforms, commitments, lookup relations, compaction, quotient construction, FRI,
decommitment, and polynomial evaluation.

Kernel fusion does not justify source-file fusion. Kernels may remain fused at the dispatch and
memory-traffic boundary while their translation units, shared headers, ABI declarations, and tests
have independent owners. Metal can compile separate translation units to AIR and link them into one
metallib without adding a runtime library lookup, command buffer, dispatch, synchronization point,
or device transfer.

The current source-conformance checker inventories Zig but does not enforce manually authored MSL.
That is an enforcement gap, not an exemption. The migration must extend the checker to `.metal`
files, add this document as the temporary legacy plan for `kernels.metal`, and remove the exception
when the split is complete.

This work is structural. It must not be mixed with shader fusion, arithmetic changes, launch-shape
tuning, address-width changes, fast-math, or proof-geometry changes.

## Current Audit

The file's current families are:

| Current region | Exported kernels | Responsibility |
| --- | ---: | --- |
| 1-345 | 11 | Blake2s primitives, transcript state/draws, lifted Merkle leaves and parents |
| 346-1,311 | 10 | M31/Felt252 support, Cairo memory/execution traces, EC witness and lookup |
| 1,312-1,888 | 25 | Circle IFFT/RFFT, sparse/wide/fused transforms, fixed lookup, composition support |
| 1,889-2,251 | 6 | CM31/QM31 support, relation accumulation/scans, feed counts, arena clear |
| 2,252-2,475 | 11 | Gather, radix sort, head scan, scatter, and compaction finalization |
| 2,476-2,524 | 3 | Standalone FRI folds and QM31 coordinate conversion |
| 2,525-2,892 | 8 | Quotient rows, numerator/finalization, coefficients, domains, denominators |
| 2,893-3,054 | 4 | Resident FRI fold, packed leaves, and final line |
| 3,055-3,534 | 10 | Query normalization/mapping, sparse openings, trace and FRI assembly |
| 3,535-3,604 | 2 | Polynomial basis and multi-polynomial evaluation |

The family count above treats `stwo_zig_witness_feed_counts` separately from the earlier Cairo
trace region. The exact exported total is 90.

### Migration ledger (2026-07-17)

The audit table records the original monolith. The live migration state is narrower than the
target architecture and must not be described as an AOT shader library yet:

- commit `111d631` added the authoritative 90-export owner map, exact source/runtime export checks,
  initial shared ABI layout assertions, deterministic one-library source amalgamation, `.metal`
  source-conformance enforcement, and the first extracted leaf (`polynomial_eval.metal`);
- the transcript increment moves its four kernels and two private helpers intact into
  `core/transcript.metal`, reducing the legacy file from 3,533 to 3,436 lines while preserving the
  runtime's single source-JIT library and existing dispatches;
- commit `a48d2fe` moved arena clearing into `core/arena_ops.metal`, and commit `5b1f062` established
  guarded `base.metal` and `blake2s.metal` support headers consumed by both the deterministic core
  amalgamation and standalone shader units;
- the field-support increment moves the exact M31, CM31, and QM31 definitions into guarded
  `m31.metal` and `extension_fields.metal` headers. Generated witness kernels consume the same M31
  authority under codegen version 5 rather than scraping M31 arithmetic from `kernels.metal`;
- the circle-support increment moves twiddle indexing, the circle value representation,
  multiplication, and generator exponentiation into guarded `circle.metal`. It is consumed only by
  the core amalgamation, so witness codegen support remains version 6 and its cache identity is
  unchanged;
- the Merkle-support increment moves the commitment and sparse-opening lifted-index mappings into
  guarded `merkle.metal` without merging their existing arithmetic forms. No Blake2s state,
  exported commitment kernel, or decommitment entry point moves with them;
- the Felt252/EC witness-support increment extracts guarded `felt252.metal`, `ec.metal`,
  `witness_abi.metal`, `witness_tables.metal`, and `witness_deductions.metal` headers. Both the
  deterministic core amalgamation and generated witness programs now consume these explicit
  owners; generated witness code no longer embeds or slices `kernels.metal`, and codegen support
  version 6 owns the resulting cache-identity change;
- the legacy file is now 2,729 lines. Its 90 exported entry points, the runtime lookup set, and the
  one-library source-JIT boundary remain unchanged;
- Stage 0 remains incomplete until every argument contract is represented in the manifest, Metal
  reflection validates it, and cold compilation/PSO/library counts are captured;
- Stage 1 remains incomplete: decommit support still belongs to `kernels.metal`; circle, Merkle,
  Felt252, EC, and generated-witness support now have explicit guarded owners;
- AOT AIR compilation/linking and authenticated metallib loading remain Stage 5 work. No current
  source extraction removes runtime compilation or changes warm proving speed.

The next support-header slice is the remaining decommit boundary. Protocol
families must not move ahead of their Stage 1 support-header boundary merely because the source-JIT
amalgamation can resolve helpers by concatenation order.

The problem is wider than file length:

- `runtime.zig` embeds the deterministic manifest amalgamation and `runtime.m` source-JIT compiles
  it for every new core runtime before eagerly resolving the core pipelines;
- generated witness support is now header-owned, versioned, and independent of legacy kernel-name
  placement; the same headers also feed the deterministic core amalgamation;
- decommit helpers still have no explicit public/private shader boundary;
- `runtime.m` repeats string literals for kernel lookup rather than consuming an authoritative ABI
  manifest;
- an edit to one family changes the source identity of every core pipeline and invalidates the
  complete source/library cache identity;
- review cannot isolate a proof-stage change from shared arithmetic or unrelated entry points;
- shared task structs have initial layout assertions, but most kernel argument positions are not yet
  described by a complete versioned host/MSL ABI contract.

## Non-Negotiable Invariants

1. The 90 existing `stwo_zig_*` exported function names and their argument indices, scalar widths,
   signedness, address spaces, access modes, and grid semantics remain unchanged during the split.
2. One linked core metallib remains the runtime boundary. Translation-unit decomposition must not
   create per-stage library loads or pipeline-cache fragmentation.
3. `MTLMathModeSafe` remains in force. The migration does not enable fast math or change integer
   overflow/reduction behavior.
4. M31, CM31, QM31, Felt252, Blake2s, Merkle prefixes, circle-domain conventions, transcript order,
   relation claimed sums, quotient values, FRI layers, and decommitment order remain bit exact.
5. Kernel moves add no dispatch, encoder, command buffer, wait, allocation, host/device copy, or
   threadgroup-memory use.
6. Fused kernels remain fused unless a later profiler-backed change separately justifies a new
   materialization or dispatch boundary.
7. Generated witness/evaluation libraries import a versioned shader support bundle. They do not
   scrape source text by sentinel kernel names.
8. Runtime source-JIT remains an explicit development/fallback lane during migration; production
   converges on an authenticated AOT metallib with no per-request compilation.
9. The source, AIR objects, metallib, ABI manifest, compiler profile, and generated support bundle
   have content-bound identities. A stale cache may not be accepted under a new identity.
10. The pinned Rust Stwo and Stwo-Cairo revisions remain the final proof-correctness oracles.

## Target Layout

```text
src/backends/metal/shaders/
|-- manifest.zig                    authoritative units, exports, versions, compile profile
|-- include/
|   |-- base.metal                  Metal stdlib import, namespace, scalar aliases
|   |-- abi_types.metal             shared MSL structs/layout assertions
|   |-- m31.metal                   M31 arithmetic
|   |-- extension_fields.metal      CM31/QM31 arithmetic and load/store helpers
|   |-- blake2s.metal               Blake2s compression and seeded state
|   |-- felt252.metal               Montgomery Felt252 arithmetic
|   |-- ec.metal                    affine/projective EC helpers
|   |-- circle.metal                circle values, powers, twiddle indexing
|   |-- merkle.metal                lifted-index and node/leaf helpers
|   `-- decommit.metal              wide offsets and sparse-opening helpers
|-- core/
|   |-- transcript.metal            4 transcript kernels
|   |-- commitments.metal           7 Blake2s leaf/parent kernels
|   |-- circle_transform.metal      19 dense/sparse/wide/fused transform kernels
|   |-- composition.metal           5 composition-support kernels
|   |-- relation.metal              4 relation kernels
|   |-- compaction.metal            11 compaction kernels
|   |-- quotient.metal              9 quotient/coordinate kernels
|   |-- fri.metal                   6 standalone/resident FRI kernels
|   |-- decommit.metal              10 decommitment kernels
|   |-- polynomial_eval.metal       2 polynomial-evaluation kernels
|   `-- arena_ops.metal             clear-arena kernel
|-- cairo/
|   |-- trace.metal                 gather, execution/memory traces, public memory
|   |-- witness_feed.metal          feed-count kernel
|   |-- fixed_tables.metal          fixed-table lookup kernel
|   `-- ec_op.metal                 Felt252 oracle and 3 EC-op kernels
`-- generated/                      build output only; never hand edited
    |-- core_amalgamated.metal      deterministic source-JIT fallback
    |-- witness_support.metal       deterministic codegen preamble
    |-- shader_abi.zig              generated host ABI table
    `-- stwo_zig_core.metallib      linked AOT library when tools are available
```

`generated/` is shown to explain artifact ownership; build outputs belong in the Zig cache/install
tree, not in tracked `src/`. If a generated source snapshot is ever checked in for release tooling,
it must carry a generated header, generator command, source-manifest digest, and the generated-file
exception required by `CONTRIBUTING.md`.

No header becomes a general dumping ground. `base.metal` contains only language setup and types
that every translation unit needs. Domain arithmetic stays in the header named for that domain.
Internal helpers and constants live in a `stwo_zig` namespace and are `inline`, `constexpr`, or
otherwise internal-linkage-safe so linking AIR objects cannot create duplicate external symbols.
Only the global `kernel void stwo_zig_*` functions are exported.

## Exact Family Ownership

The move map for exported entry points is normative.

### Transcript and commitments

`core/transcript.metal` owns:

- `stwo_zig_transcript_init_resident`
- `stwo_zig_transcript_mix_resident`
- `stwo_zig_transcript_draw_secure_resident`
- `stwo_zig_transcript_draw_queries_resident`

`core/commitments.metal` owns:

- `stwo_zig_blake2s_leaves`
- `stwo_zig_blake2s_leaf_absorb_resident`
- `stwo_zig_blake2s_leaf_absorb_compact_resident`
- `stwo_zig_blake2s_parents`
- `stwo_zig_blake2s_parents_sparse`
- `stwo_zig_blake2s_parent_tail_sparse`
- `stwo_zig_blake2s_parents_plain_sparse`

Both import `blake2s.metal`; only commitments import `merkle.metal`.

### Cairo trace and EC

`cairo/trace.metal` owns:

- `stwo_zig_witness_input_gather_resident`
- `stwo_zig_execution_table_split_resident`
- `stwo_zig_memory_address_base_trace_resident`
- `stwo_zig_memory_value_base_trace_resident`
- `stwo_zig_memory_rc99_count_resident`
- `stwo_zig_public_memory_seed_resident`

`cairo/witness_feed.metal` owns `stwo_zig_witness_feed_counts`.

`cairo/ec_op.metal` owns:

- `stwo_zig_felt252_oracle`
- `stwo_zig_ec_op_lookup`
- `stwo_zig_ec_op_witness`
- `stwo_zig_ec_op_base_finalize`

The witness support bundle used by generated Cairo programs imports `m31.metal`, `abi_types.metal`,
and only the Felt252/EC helpers required by the authenticated program. It does not include any core
entry kernel.

### Circle and composition

`core/circle_transform.metal` owns:

- `stwo_zig_circle_ifft_first`
- `stwo_zig_circle_ifft_layer`
- `stwo_zig_circle_rfft_layer`
- `stwo_zig_circle_rfft_last`
- `stwo_zig_circle_rescale`
- `stwo_zig_circle_expand_coefficients`
- `stwo_zig_circle_expand_sparse`
- `stwo_zig_circle_copy_sparse`
- `stwo_zig_circle_ifft_first_sparse`
- `stwo_zig_circle_ifft_layer_sparse`
- `stwo_zig_circle_rescale_sparse`
- `stwo_zig_circle_rfft_layer_sparse`
- `stwo_zig_circle_rfft_radix4_sparse`
- `stwo_zig_circle_rfft_last_sparse`
- `stwo_zig_circle_rfft_layer_sparse_wide`
- `stwo_zig_circle_rfft_last_sparse_wide`
- `stwo_zig_circle_ifft_fused_tail`
- `stwo_zig_circle_rfft_fused_tail`
- `stwo_zig_circle_rfft_fused_tail_sparse`

`core/composition.metal` owns:

- `stwo_zig_composition_expand_sparse`
- `stwo_zig_composition_lift_accumulate`
- `stwo_zig_composition_split_coordinates`
- `stwo_zig_composition_random_powers`
- `stwo_zig_composition_ext_params`

`cairo/fixed_tables.metal` owns `stwo_zig_fixed_table_lookup_sparse`.

The circle and composition units share only field/circle headers. Composition must not import
transform entry points or depend on their translation-unit order. Fixed-table lookup imports only
the field/circle support it consumes.

### Relations and compaction

`core/relation.metal` owns:

- `stwo_zig_relation_fused`
- `stwo_zig_relation_block_scan`
- `stwo_zig_relation_scan_blocks`
- `stwo_zig_relation_scan_finalize`

`core/compaction.metal` owns:

- `stwo_zig_compact_gather`
- `stwo_zig_compact_radix_histogram`
- `stwo_zig_compact_radix_prefix`
- `stwo_zig_compact_radix_scatter`
- `stwo_zig_compact_heads`
- `stwo_zig_compact_scan_local`
- `stwo_zig_compact_scan_blocks`
- `stwo_zig_compact_scan_add`
- `stwo_zig_compact_clear_outputs`
- `stwo_zig_compact_scatter`
- `stwo_zig_compact_finalize`

`core/arena_ops.metal` owns `stwo_zig_clear_arena_spans`. Clearing is a resource operation, not a
relation or compaction semantic.

### Quotient and FRI

`core/quotient.metal` owns:

- `stwo_zig_qm31_to_coordinates`
- `stwo_zig_quotient_rows`
- `stwo_zig_quotient_rows_raw`
- `stwo_zig_quotient_numerator_raw`
- `stwo_zig_quotient_finalize`
- `stwo_zig_quotient_coefficients_resident`
- `stwo_zig_quotient_domain_points_resident`
- `stwo_zig_quotient_denominators_resident`
- `stwo_zig_quotient_combine_resident`

`core/fri.metal` owns:

- `stwo_zig_fri_fold_circle`
- `stwo_zig_fri_fold_line`
- `stwo_zig_fri_fold3_resident`
- `stwo_zig_fri_fold2_resident`
- `stwo_zig_fri_packed_leaves_resident`
- `stwo_zig_fri_final_line_resident`

Both import extension-field arithmetic. FRI may import Blake2s helpers for packed leaves but not the
commitment translation unit.

### Decommitment and polynomial evaluation

`core/decommit.metal` owns:

- `stwo_zig_decommit_normalize_queries_resident`
- `stwo_zig_decommit_prepare_fri_queries_resident`
- `stwo_zig_decommit_prepare_trace_queries_resident`
- `stwo_zig_decommit_gather_trace_values_resident`
- `stwo_zig_decommit_gather_fri_values_resident`
- `stwo_zig_decommit_sparse_parent_resident`
- `stwo_zig_decommit_sparse_leaves_resident`
- `stwo_zig_decommit_sparse_leaf_group_resident`
- `stwo_zig_decommit_assemble_trace_resident`
- `stwo_zig_decommit_assemble_fri_resident`

`core/polynomial_eval.metal` owns:

- `stwo_zig_eval_basis`
- `stwo_zig_eval_polynomials`

Decommitment imports wide-offset, Blake2s, field, and Merkle helpers, never commitment or FRI entry
units. Polynomial evaluation imports field/circle helpers only.

## Dependency Direction

The shader graph is acyclic:

```text
base.metal
   |
abi_types.metal
   |
m31.metal
   |-----------------------|
extension_fields.metal  felt252.metal  blake2s.metal  circle.metal
                         |                |              |
                      ec.metal         merkle.metal   decommit.metal
   \_________________________ leaf translation units _________________________/
                                      |
                             linked core metallib
                                      |
                        runtime manifest and pipeline plans
```

Rules:

- headers may import only headers to their left or below them in this graph;
- a translation unit may import headers, never another translation unit;
- Cairo shader units do not import frontend Zig code or generated AIR programs;
- generated witness/evaluation programs consume an explicit support-bundle API and never import
  core entry units;
- `runtime.m` consumes the generated ABI table/library and does not decide proof semantics;
- no shader includes a benchmark, profiler, filesystem, environment, or Objective-C policy;
- shared helpers move downward only after at least two owning units genuinely use them.

## Include and Source-Bundle Strategy

Repository includes use quoted, root-relative logical paths such as:

```metal
#include "stwo_zig/extension_fields.metal"
```

An authoritative build tool reads `manifest.zig`, resolves only listed repository headers, rejects
cycles, duplicate logical paths, `..`, absolute paths, and unlisted includes, and emits:

1. the ordered translation-unit list for AOT compilation;
2. a deterministic, line-mapped `core_amalgamated.metal` for source-JIT;
3. the minimal `witness_support.metal` variants used by witness codegen;
4. a generated Zig ABI/export table;
5. a manifest digest over normalized source bytes, include graph, ABI version, compile options, and
   codegen-support version.

The amalgamator expands repository headers once per translation unit, preserves translation-unit
boundaries with generated namespaces/internal linkage, and emits `#line` directives so Metal
compiler errors map to the owning source. It does not concatenate arbitrary filesystem input.

`witness_codegen.zig` replaces `indexOf` sentinel slicing with an import of the generated support
bundle. Programs that do not use deduction receive only the declared M31/table ABI; programs that
do use deduction receive the versioned Felt252/EC support set. This changes generated source
identity, so `codegen_version` increments once when the new bundle becomes authoritative even
though semantic hashes and proof behavior remain unchanged.

## Stable Export and ABI Boundary

`manifest.zig` is the authoritative host-visible contract. For each core kernel it records:

- exact exported function name;
- owning translation unit;
- ordered buffer/byte/scalar arguments and Metal buffer indices;
- MSL scalar width, signedness, address space, access mode, and referenced shared-struct layout;
- threadgroup-memory indices and size rule, if any;
- function constants and specialization values, if any;
- logical grid unit, bounds rule, and required threadgroup constraints;
- minimum core shader ABI version.

The manifest generates the lookup-name table used by `runtime.m`; handwritten duplicate kernel
name lists are removed after parity. Shared host/MSL structures receive compile-time size,
alignment, and field-offset assertions on the Zig/Objective-C side plus generated MSL definitions.
Metal pipeline reflection on supported hardware verifies argument indices/types against the
manifest. The library acceptance test compares `MTLLibrary.functionNames` with the complete expected
90-name set and rejects a missing, duplicate, or unexpected core export.

The initial version is `core_shader_abi = 1`. Moving code does not bump it. Renaming an entry point,
changing a signature or shared layout, adding a function constant, or changing grid semantics is a
separate ABI proposal and version bump. Internal helper names and translation-unit ownership are
not ABI.

Generated witness kernels retain their existing semantic names. Their support-bundle version is a
separate cache dimension from the core ABI because those programs are compiled into separate,
content-addressed libraries.

## Metallib Build and Runtime Selection

### Deterministic source build

`zig build metal-shader-source` runs on every host and produces the deterministic amalgamation,
witness support variants, ABI table, and manifest digest. It requires no Apple offline compiler.
Tests compare a second generation byte for byte and verify that changing any included header changes
the digest.

### AOT build

On a supported macOS builder with `xcrun metal` and `xcrun metallib`:

1. compile each listed leaf translation unit independently to AIR with one pinned SDK, language
   version, deployment target, `MTLMathModeSafe`-equivalent options, and include root;
2. link all AIR objects in manifest order into one `stwo_zig_core.metallib`;
3. inspect the linked library and validate the 90-name export/ABI manifest;
4. hash the final metallib and bind it to the source-manifest digest, compiler/SDK profile, ABI
   version, target family policy, and build revision;
5. install or embed the metallib as an immutable build artifact.

AIR objects are build cache entries, not repository artifacts. A change to one family recompiles
that unit and any unit whose included header changed, then relinks the single library.

### Runtime policy

The migration initially keeps the current amalgamated source-JIT path so pure source moves can be
proven behavior-neutral. In the next focused step, `Runtime.init` accepts a core-library artifact:

- production/release builds load the authenticated embedded or installed metallib;
- development builds may explicitly select the generated source-JIT bundle;
- tests exercise both lanes when the host supports them;
- no production request silently falls from metallib to source-JIT;
- missing or mismatched ABI/source identities fail before pipeline preparation.

The linked library remains one `id<MTLLibrary>`. Pipeline plans and dispatch sites therefore do not
change merely because source ownership changed.

## Compile and Cache Implications

The current source split will change the full source digest once and cause an intentional cold
cache transition. Old pipeline/binary-archive entries must not be copied or aliased into the new
namespace.

Core cache identity is:

```text
core shader ABI version
+ final metallib SHA-256 (or amalgamated source SHA-256 for explicit JIT)
+ normalized compiler/SDK profile
+ device registry/family and OS build where Metal requires them
+ exact function name and specialization constants
```

Generated witness/evaluation identity is:

```text
semantic program hash and mode
+ generated source SHA-256
+ witness/eval codegen version
+ support-bundle digest
+ compiler profile and device/OS cache dimensions
```

Consequences:

- the first post-migration run is labeled cold and is not compared with a warm pre-migration run;
- one core library digest prevents per-family cache explosion;
- source decomposition improves offline incremental compilation but does not promise a faster GPU
  kernel or warm proof;
- production setup resolves and caches required PSOs once per runtime/device plan, never per block;
- binary archive population/serialization is bounded and occurs outside measured proof execution;
- warm streaming tests require zero source compiles, zero unexpected direct pipeline compiles, and
  stable library/PSO counts;
- any compiler flag or support-header change invalidates the correct dependent identities.

## Per-File Size Targets

These are ownership budgets, not permission to split a coherent kernel body:

| File class | Target | Hard review threshold |
| --- | ---: | ---: |
| Base/ABI header | 80-200 lines | 300 |
| Arithmetic/domain header | 150-350 lines | 500 |
| Routine kernel translation unit | 150-400 lines | 500 |
| Circle, quotient, or decommit HPC unit | 350-650 lines | 850 |
| Manifest/generator Zig module | 250-500 lines | 650 |
| Generated amalgamation | generated only | must not be hand edited |

No new manually maintained `.metal` file receives a baseline exception. A fused kernel longer than
the normal kernel guidance stays together only with the required traffic, dispatch, occupancy,
register, and threadgroup-memory evidence.

## Staged Migration

Each stage is a focused commit or short stack and preserves all exported names.

### Stage 0: make the current ABI executable

1. Add the 90-entry manifest from current signatures and runtime lookup names.
2. Add host shared-struct size/alignment/offset assertions.
3. Add a Metal export/reflection test and a source test that fails when `runtime.m` lookup names
   differ from the manifest.
4. Extend source conformance to `.metal` and add the temporary `kernels.metal` exception pointing
   to this document.
5. Capture source-JIT cold compile, eager PSO preparation, warm cache, and core library counts.

No source moves occur until this gate is green.

### Stage 1: extract shared headers without changing one translation unit

1. Move base, M31, extension-field, Blake2s, circle, Felt252, EC, Merkle, and decommit helpers into
   the include graph.
2. Replace the original helper bodies with includes while `kernels.metal` remains the only core
   translation unit.
3. Generate witness support from headers and remove sentinel slicing.
4. Increment the witness codegen-support version and invalidate only the correct generated-library
   cache namespace.

This stage proves include semantics and generated-program parity before AIR linking is introduced.

### Stage 2: move low-coupling leaf units

Move, one family per commit:

1. polynomial evaluation;
2. arena clear;
3. transcript;
4. commitments;
5. Cairo trace and witness feed;
6. Cairo EC.

For the source-JIT lane, the amalgamator still presents one deterministic library source. For AOT,
compile the moved units to AIR but continue comparing the linked library with the monolithic lane.

### Stage 3: move transform and lookup units

1. circle transforms;
2. composition support;
3. relation scans;
4. compaction.

Fused transform kernels move intact. Do not refactor their threadgroup state or barriers during the
move.

### Stage 4: move quotient, FRI, and decommitment

Move quotient, then FRI, then decommitment with stage-level scalar/SIMD and Rust transcript
checkpoints after each commit. These are protocol-critical and must not be reviewed as one bulk
diff.

At the end of this stage `kernels.metal` is deleted, not retained as a broad include facade.

### Stage 5: make the linked metallib authoritative

1. Add the deterministic AIR/link build and immutable metallib manifest.
2. Load one authenticated core metallib in production.
3. Retain source-JIT only behind an explicit development/test selection.
4. Prewarm required core PSOs in prepared runtime state and assert zero warm compiles.
5. Namespace caches by the complete identities above and test stale/tampered artifacts.

### Stage 6: remove legacy debt

1. Remove the `kernels.metal` source-conformance exception.
2. Require all manually maintained shader files to pass size and include-direction checks.
3. Record cold AOT load/PSO preparation and warm streaming evidence.
4. Update architecture and performance reports with the new library identity; do not present a
   pure source split as a proving-speed improvement.

## Exact Verification Gates

### Structural and compile gates

Every stage runs:

```bash
zig build fmt
python3 scripts/check_source_conformance.py
zig build test
zig build api-parity
```

The new shader build gate must additionally:

- generate source/support/ABI artifacts twice and compare bytes;
- reject include cycles, path escape, duplicate exports, missing manifest exports, and extra linked
  exports;
- compile every translation unit independently in safe and optimized profiles;
- link one metallib and resolve all 90 pipelines;
- compile the source amalgamation with `newLibraryWithSource`;
- compare AOT and source-JIT reflection against the same ABI manifest;
- compile representative generated witness programs both with and without deduction support.

### Kernel-family parity gates

| Family | Exact parity requirement |
| --- | --- |
| M31/CM31/QM31 | scalar Zig differential vectors including zero, modulus edges, inverses, and random fixed-seed inputs |
| Felt252/EC | Rust/Zig canonical limb vectors, affine/projective edge cases, EC trace and lookup columns |
| Blake2s/transcript | digest vectors, seeded leaf/node prefixes, transcript states and every draw/checkpoint |
| Circle transforms | coefficient/evaluation round trips at boundary logs, sparse/wide tails, CPU/SIMD exact values |
| Cairo trace/witness | per-component columns, subcomponent inputs, multiplicities, cumulative accumulator after every component |
| Relations/composition | per-instance claimed sums, descriptor order, random powers, component accumulator checkpoints |
| Compaction | keys, heads, prefix scans, counts, output order over zero/one/tail/duplicate-heavy cases |
| Quotient | sampled points, denominators, partials, numerator coordinates, finalized tile |
| FRI | every folded layer, roots, retained evaluations, final coefficients and degree check |
| Decommitment | normalized/mapped queries, sparse hashes, trace/FRI opening order, exact assembly bytes |
| Polynomial evaluation | basis and polynomial outputs versus scalar Zig over boundary degrees/batches |

Metal tests run on supported hardware with:

```bash
zig build metal-test -Doptimize=ReleaseFast
zig build cairo-streaming-commitment-test -Doptimize=ReleaseFast
```

The AOT and source-JIT lanes run the identical vectors and must produce identical logical outputs,
roots, transcript checkpoints, proof bytes, and verifier results.

### Final proof gates

For Native Stwo, run the repository vector/interoperability gates:

```bash
zig build vectors
zig build interop
zig build prove-checkpoints
```

For Cairo, require:

1. the bounded Fib Cairo artifact through both Metal library lanes;
2. one non-Fib Cairo program with a distinct builtin/constraint shape;
3. one wide, large SN PIE through the same production proving path;
4. exact per-component cumulative oracle checkpoints during localization;
5. final proof acceptance by the pinned Rust Stwo-Cairo `verify_cairo` adapter;
6. tampered statement, root, claimed sum, FRI layer, opening, and proof-byte rejection.

The canonical Rust adapter gate is:

```bash
cargo test --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml
```

Rust verification is mandatory even when AOT and JIT produce identical Zig proof bytes. Agreement
between two Metal library forms is not an independent correctness oracle.

### Runtime and cache gates

A pure move is accepted only when before/after counters show:

- identical dispatch, encoder, command-buffer, wait, and host/device-copy counts;
- identical resident/scratch high-water and no new allocation in a warm proof;
- one core library per runtime/device plan;
- zero warm source-library compiles and zero unexpected direct PSO compiles;
- stable PSO count for the admitted workload;
- one intentional cold cache transition, followed by cache hits under the new content identity;
- no silent AOT-to-JIT fallback;
- complete proof/request timing within the established noise band.

The split itself has no MHz claim. Any later shader optimization begins from a fresh post-migration
profile and lands separately.

## Completion Criteria

The shader-library migration is complete only when:

- `kernels.metal` is removed;
- all 90 current entry points have one manifest owner and unchanged ABI version 2 signatures;
- no manually maintained MSL file exceeds 850 lines or has a transferred legacy exception;
- witness codegen no longer slices implementation source by sentinel strings;
- source-JIT and one linked AOT metallib pass the same export/reflection and family parity gates;
- production loads the authenticated AOT library and performs zero warm source compilation;
- Native Stwo proofs pass vectors, interoperability, and pinned Rust verification;
- Fib, non-Fib Cairo, and wide SN PIE proofs pass component checkpoints and pinned Rust
  `verify_cairo`;
- cache, command, dispatch, synchronization, allocation, and memory counters show no structural
  regression;
- source conformance enforces MSL size/include rules and the legacy exception is removed.
