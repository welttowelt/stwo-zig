# Pre-Optimization Conformance and Repository Quality Goal

Status: active optimization-readiness gate; blocking aggressive optimization, not full release signoff
Priority: Native Stwo and Cairo first; RISC-V last
Completion signal: every exit gate is green from a clean checkout plus only manifest-resolved corpora

## 1. Goal

Deliver a coherent, production-shaped Zig implementation of Stwo whose Native Stwo and Cairo
proofs conform to their pinned Rust oracles, whose Metal backend is fail-closed and reusable, and
whose source tree enforces the ownership and quality rules in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md). Only after that state is demonstrated may the project
resume aggressive SIMD, Metal, fusion, residency, or benchmark-throughput work.

This is not a documentation milestone. It is a repository-wide correctness and architecture lock:

```text
pinned source and protocol contracts
    -> Native Stwo parity
    -> complete Cairo semantics and proof interchange
    -> raw PIE-derived, production-admissible Metal proofs
    -> resettable mixed-block streaming
    -> mechanically enforced repository boundaries
    -> clean release and interoperability gates
    -> frozen benchmark baseline
    -> optimization unlocked
```

The final result must be understandable locally, testable without hidden state, and safe to
optimize without questioning whether a faster result changed the statement, proof, backend,
protocol, input, or lifecycle being measured.

## 2. Why This Gate Exists

The repository has working and Rust-accepted Native proofs, verified diagnostic SN PIE proofs,
substantial resident Metal machinery, and several behavior-preserving decompositions. It does not
yet have one production-admissible path from a raw PIE through Cairo execution and semantic
artifact derivation to a proof accepted by the canonical Rust `verify_cairo` oracle. The general
Cairo program matrix is therefore not yet a Zig proving benchmark.

At the same time, the repository still contains large transitional facades and a source-conformance
ratchet with explained legacy debt. Optimizing through those boundaries would harden accidental
ownership, increase the cost of proving correctness, and make performance results difficult to
attribute.

The gate deliberately separates three claims:

1. **Implemented:** source or an API exists.
2. **Conformant:** the applicable Rust oracle accepts the exact artifact and all local gates pass.
3. **Production-admissible:** inputs and artifacts have an authenticated source chain, the selected
   backend cannot silently fall back, and the service lifecycle passes reset and queue tests.

Only the third claim unlocks production Metal performance work. A diagnostic path remains useful
for parity, but it cannot satisfy this goal by being fast.

This goal establishes when aggressive optimization may begin. It does not waive the normative
release-performance gates in `docs/conformance/contract.md`: Phase 6 freezes reproducible G8/G9
baseline evidence, while the Rust-relative speed targets remain post-unlock release requirements.

## 3. Normative Authority

Documents have different scopes. A status note or historical result must not silently override a
contract. Apply the following precedence.

| Authority | Governs | Required use |
| --- | --- | --- |
| [`CONTRIBUTING.md`](../../CONTRIBUTING.md) | Engineering quality, Zig, SIMD, Metal, ownership, testing, benchmarking, review, and file-size rules | Applies to every change |
| [`conformance/contract.md`](../conformance/contract.md) | Native Stwo protocol, API, proof interoperability, release gates, and performance evidence | Defines release conformance |
| [`conformance/upstream.md`](../conformance/upstream.md) | Scope-aware Native and Cairo verifier/prover pin ledger and upgrade procedure | Final Rust authority ledger |
| [`conformance/api-parity.md`](../conformance/api-parity.md) | Public Zig-to-Rust surface mapping | Updated with every affected public API |
| [`conformance/divergence-log.md`](../conformance/divergence-log.md) | Intentional and closed semantic differences | No unrecorded divergence is allowed |
| [`2026-07-17-source-conformance.md`](2026-07-17-source-conformance.md) | Source migration, dependency direction, and the conformance ratchet | Operational structure plan |
| [`2026-07-17-native-backend-suite.md`](2026-07-17-native-backend-suite.md) | Backend-neutral Native proof and oracle matrix | Native backend acceptance evidence |
| [`cairo_program_matrix.json`](../../vectors/cairo/cairo_program_matrix.json) | Exact 27-cell Cairo source, compiler, input, cycle, and identity contract | Machine-readable Cairo acceptance authority |
| [`2026-07-17-cairo-program-matrix.md`](2026-07-17-cairo-program-matrix.md) | Human projection of the Cairo corpus, evidence, and acceptance order | Must remain validated against the manifest |
| [`cairo-zig-adapter.md`](../cairo-zig-adapter.md) | PIE/adapted-input schema and ownership | Cairo ingress boundary |
| [`cairo-zig-prover-entrypoint.md`](../cairo-zig-prover-entrypoint.md) | General Cairo orchestration and canonical `verify_cairo` gate | Cairo proof publication boundary |
| [`sn-pie-metal-production-architecture.md`](../sn-pie-metal-production-architecture.md) | SN PIE Metal production service, source chains, evidence classes, and delivery phases | Authoritative SN Metal architecture |
| [`sn-pie-streaming.md`](../sn-pie-streaming.md) and [`sn-pie-persistent-session.md`](../sn-pie-persistent-session.md) | Reset, queue, and current session protocol details not superseded by the production architecture | Streaming implementation detail |
| [`2026-07-17-metal-shader-library-decomposition.md`](2026-07-17-metal-shader-library-decomposition.md) | Metal source families, stable ABI, one linked metallib, AOT/JIT policy | Shader migration contract |
| [`2026-07-17-cairo-metal-arena-binding-decomposition.md`](2026-07-17-cairo-metal-arena-binding-decomposition.md) | Cairo-Metal phase ownership and stable facade migration | Arena-binding migration contract |
| [`2026-07-17-cairo-arena-schedule-decomposition.md`](2026-07-17-cairo-arena-schedule-decomposition.md) | Pure schedule ownership and runtime geometry | Schedule migration contract |
| [`2026-07-17-backend-performance-program.md`](2026-07-17-backend-performance-program.md) | Profiler-led Native and Cairo optimization after correctness gates | Governs work only after this goal unlocks it |

Historical documents under `docs/history/` are evidence, not current authority. Benchmark reports
under `vectors/reports/` describe a particular run and never broaden the supported product surface.

### 3.1 Pin Scope Is Explicit

`docs/conformance/upstream.md` is now the single ledger for two independent compatibility lanes:

- Native Stwo uses its pinned upstream Stwo revision.
- Cairo uses a pinned Stwo-Cairo revision, its verifier-compatible Stwo revision, and the clean
  prover-Stwo revision required to compile witness and trace tooling.

Every vector, proof envelope, verifier receipt, benchmark report, and generated semantic artifact
must name the applicable lane, sub-lane role, and exact revisions. A base or interaction trace
receipt from the Cairo prover sub-lane does not establish proof acceptance by the verifier sub-lane,
and acceptance in either Cairo sub-lane does not establish Native parity.

### 3.2 Conflict Rule

When documents disagree:

1. correctness and security contracts override implementation plans;
2. the newer scope-specific normative architecture overrides older design notes;
3. checked-in machine-readable evidence overrides prose status claims;
4. the stricter fail-closed requirement applies until the conflict is corrected in the same
   focused change.

No implementation change may resolve a document conflict implicitly.

### 3.3 Status Reconciliation

Resolved adoption conflicts remain recorded so old reports cannot silently regain authority:

| Prior conflict | Current authority |
| --- | --- |
| Synthetic Wide-Fibonacci rows were treated as the Native baseline | The complete six-example real-AIR matrix in `2026-07-17-native-backend-suite.md` is authoritative; synthetic rows are historical only |
| Native example and Poseidon coverage were described as incomplete | The six examples, including Poseidon, are accepted in the Native suite and recorded complete in `conformance/contract.md` |
| General `proveCairo` was described as a stub | The Cairo matrix and entrypoint now describe the authenticated development boundary and its proof-derived, non-production limitation |
| Native crate roadmap completion was read as general Cairo completion | The roadmap applies to the pinned Native lane; Cairo has its own gates in this document |
| Pin ownership was split across prose files | `conformance/upstream.md` is the checked, scope-aware ledger for Native and both Cairo sub-lanes |
| Cairo Markdown tiers and benchmark catalog defaults disagreed | `vectors/cairo/cairo_program_matrix.json` now defines exactly 27 cells; the catalog consumes it and tests validate the Markdown projection |

The following conflicts remain open:

- dated AOT and session checkpoints predate current core and witness library-admission APIs, so
  source presence must remain distinct from a built, authenticated, production-consumed library;
- volatile line-count and migration-status prose in decomposition documents must be replaced by or
  checked against dated generated inventory evidence.

Every reconciliation must cite the exact code, report, test, or verifier receipt supporting its
replacement claim. Deleting an inconvenient status statement without replacing its evidence is not
closure.

## 4. Scope and Priority

### 4.1 Required Priority

1. Shared field, transcript, PCS, FRI, proof, verifier, backend, and interop foundations.
2. Native Stwo proof conformance across CPU and Metal.
3. General Cairo execution, adaptation, AIR semantics, proof construction, and Rust interchange.
4. SN PIE production admission and mixed-block streaming on Metal.
5. Repository decomposition and enforcement needed to make those paths locally understandable.
6. RISC-V-specific conformance and restructuring after the shared Native/Cairo contracts settle.

RISC-V must not drive a shared abstraction unless the Native Stwo or Cairo implementation also
needs that abstraction. RISC-V benchmark success cannot substitute for Cairo correctness.

### 4.2 Work Allowed Before Unlock

- correctness and security fixes;
- Rust-oracle differential tests and negative cases;
- production source-chain and verifier admission work;
- behavior-preserving source decomposition with exact parity evidence;
- deterministic build, AOT library, ABI, provenance, and lifecycle closure;
- observability needed to prove that a gate is satisfied;
- benchmark-harness correctness, provenance, and immutable delta tracking;
- bounded profiling or measurement required to diagnose a correctness, resource, or gate failure;
- the broad Phase-6 baseline needed to make later optimization deltas trustworthy.

### 4.3 Work Deferred Until Unlock

- benchmark-specific shortcuts or program-name branches;
- new arithmetic, SIMD, shader-fusion, command-graph, or memory-layout optimizations;
- performance tuning justified only by a microbenchmark;
- expansion to new proof systems, frontends, or protocols;
- unmeasured refactors unrelated to a named conformance or structure gate;
- headline MHz claims from proof-derived, fixture-assisted, fallback, or incomplete paths.

An urgent optimization may proceed only to fix a release-blocking resource failure, and it must
still preserve oracle parity and be documented as an exception. This is not a general escape hatch.

Rust-relative speed targets are not optimization-unlock conditions. They become blocking release
conditions after this goal establishes trustworthy statements, backends, lifecycles, and evidence.

### 4.4 Backend Classes

Backend identity is a capability contract, not a marketing label:

- `cpu_native` is the current CPU proof capability; it must not be called SIMD until a distinct
  vectorized Cairo capability and telemetry contract exist.
- `metal_hybrid` may use declared CPU stages only in diagnostic or transition evidence. Every
  fallback stage and count is reported, and this class cannot satisfy production Metal admission.
- `metal_resident` means the admitted Metal capability executes all trace, relation, composition,
  commitment, quotient, FRI, opening, and proof-assembly stages assigned to the backend with zero
  backend-fallback counters. Host orchestration and independent verification remain named host work.

Selecting one class and executing another is an error even when the resulting proof verifies.

### 4.5 Separate SNIP-36 Track

SNIP-36 is a separate post-unlock benchmark and possible intermediate workload. It is never an
input adapter for SN1-SN4, never part of their averages or conformance receipts, and never a
substitute for executing and proving raw SN PIEs through the general Cairo path.

## 5. Current Conformance Baseline

This table is a starting audit, not a permanent status record. The evidence must be regenerated at
completion.

| Area | Current position | Required closure |
| --- | --- | --- |
| Native Stwo | Broad CPU/Metal proof artifacts are byte-identical and accepted by the pinned Native Rust oracle | Re-run the full clean, strict, bidirectional, negative, and backend matrix against the recorded pin |
| General Cairo | The pinned Fib25k input has immutable Rust base and diagnostic interaction receipts; one Zig command matches all 30 base components and 396 columns exactly, while interaction materialization and complete proof closure remain open | Match all 30 interaction components, then produce program-agnostic Cairo proofs accepted by pinned `verify_cairo` |
| SN PIE Metal | SN1-SN4 have verified diagnostic evidence; some paths remain prepared-input or proof-derived | Derive all production inputs and semantic artifacts from raw PIE/source inputs and pass the live protocol gate |
| Metal compilation | Source-JIT and partial authenticated AOT infrastructure exist | Build, authenticate, and admit current core and witness metallibs; production must reject JIT and fallback |
| Streaming | Persistent and queue machinery exists around diagnostic artifacts | Pass mixed-input reset, cache-key, verification, bounded-memory, failure, and ordered-publication gates |
| Repository structure | The expanded multi-language ratchet is green with 30 owned legacy findings and no new violations | Remove every baseline exception and close the planned facade splits |
| CI and hooks | Shared CI, hosted workflows, and versioned hooks exist | Make all required conformance gates authoritative and reproducible on their supported platforms |

### 5.1 Initial Red Gate: Closed

At adoption on 2026-07-17, `python3 scripts/check_source_conformance.py` failed because four files
exceeded their checked-in legacy ceilings:

| File | Current lines | Recorded ceiling |
| --- | ---: | ---: |
| `src/backends/metal/runtime.m` | 5,934 | 5,869 |
| `src/backends/metal/runtime.zig` | 3,435 | 3,414 |
| `src/integrations/cairo_metal/arena_binding.zig` | 2,555 | 2,525 |
| `src/metal_arena_plan_cli.zig` | 4,942 | 4,935 |

That immediate gate is closed. Focused responsibility extractions reduced the files to 5,869,
3,410, 2,502, and 4,887 lines respectively without raising a ceiling. The original checker then
reported `16 explained legacy findings, no new violations`.

The ratchet now covers 500 `src` sources, root build ownership, 89 maintained Python files, and 16
repository Rust-tool files. Baseline v3 contains 30 owned findings: 24 oversized files, five
misplaced root sources, and one forbidden dependency. Every entry has a validated owner, reason,
next extraction, plan, and file-size cap where applicable. This permits conformance implementation
to continue; it does not satisfy the final empty-baseline gate.

Every finding remains debt, even when the ratchet explains it. After Native and Cairo/Metal
closure, the only permitted temporary findings are the nine explicitly RISC-V-owned items. The
final optimization unlock still requires an empty baseline: all build, Python, Rust, Metal, test,
and frontend monoliths are decomposed; the four RISC-V root files move under `src/tools/riscv/` or
`src/tests/riscv/`; the four oversized RISC-V frontend files are decomposed; and the RISC-V
frontend no longer imports the concrete CPU backend.

## 6. Target Repository Architecture

The target remains the layout in the source-conformance plan:

```text
src/
|-- stwo.zig                         public library map
|-- std_shims_freestanding.zig       intentional alternate build root
|-- core/                            backend-independent protocol and verifier
|-- backend/                         capability contracts only
|-- prover/                          generic proving algorithms
|-- backends/
|   |-- cpu_scalar/                  CPU implementation and SIMD kernels
|   |-- cuda/                        Preserved CUDA boundary; out of current delivery scope
|   `-- metal/                       Metal implementation, runtime, shaders, ABI
|-- frontends/
|   |-- cairo/                       Cairo statement, AIR, witness, proof plan
|   `-- riscv/                       RISC-V statement and AIR, last priority
|-- integrations/
|   `-- cairo_metal/                 the only Cairo/Metal bridge
|-- interop/                         formats, parity, and Rust-oracle boundaries
|-- examples/                        Native Stwo AIR examples
|-- bench/                           benchmark execution primitives
|-- tools/                           thin executable and service adapters
`-- tests/                           cross-module and backend integration tests
```

### 6.1 Dependency Direction

The following edges are mandatory. Completion requires all of them to be mechanically checked;
the current checker covers only a subset of relative Zig imports and must not be represented as
repository-wide enforcement until Phase 5 closes that gap:

```text
core <- backend capability contracts <- prover
  ^                                      ^
  |                                      |
frontends -------------------------------+

backends implement capabilities
integrations/cairo_metal -> frontends/cairo + backends/metal
interop/tests/tools -> public lower-layer APIs
```

- `core` must not know a concrete backend, frontend, CLI, benchmark, or fixture.
- `prover` must depend on capability interfaces, not Metal handles or CPU policy.
- a frontend owns statement and AIR meaning, never device policy.
- a concrete backend must not import Cairo, RISC-V, or example semantics.
- the preserved CUDA backend follows the same concrete-backend dependency rule even though CUDA
  implementation work is out of scope for this goal.
- only `integrations/cairo_metal` may bind Cairo semantics to Metal execution.
- tools and tests may compose lower layers; lower layers may not import them back.
- diagnostics flow through narrow optional sinks and must not control proof behavior.

### 6.2 Module Shape

Each reusable module or package directory must have an explicit public map and private
implementation. Leaf data, fixture, and focused test directories do not need artificial `mod.zig`
files:

- `mod.zig` and `stwo.zig` expose stable concepts, not transitive implementation dumps;
- executable roots parse arguments, construct dependencies, call one owned service, and exit;
- FFI headers and Zig declarations have one ABI owner and compile-time layout checks;
- generated sources identify their generator, schema, inputs, and reproducible command;
- protocol policy, device resource ownership, and benchmark policy live in different modules;
- caches have typed keys, byte/count bounds, explicit invalidation, and tested lifetimes;
- no `utils`, `helpers`, `common`, `misc`, or similar directory may become an ownership substitute.

### 6.3 Progressive Disclosure and Size Ratchet

Apply the limits in `CONTRIBUTING.md` to manually maintained Zig, Metal, Objective-C, C headers,
Python, Rust support code, and `build.zig`:

- approximately 500 lines is the normal review target;
- 850 lines is the soft ceiling for one genuinely cohesive protocol/HPC module;
- larger legacy files may only shrink under a documented decomposition plan;
- an extraction must remove concepts and dependency edges, not create shallow forwarding layers;
- hot kernels may remain fused at runtime while source ownership is split;
- generated code is exempt only when reproducible, marked, and excluded deliberately by the
  conformance checker.

The checker inventories repository-owned manual languages outside build caches, vendor trees, and
authenticated generated outputs. The empty v3 baseline is the optimization-unlock condition;
additional language/dependency analyzers added later join the same ratchet rather than a parallel
waiver ledger.

The following legacy owners require explicit closure:

| Legacy owner | Required destination shape |
| --- | --- |
| `backends/metal/runtime.m` | Objective-C bridge split by library/PSO admission, buffers/resources, command encoding, archives, and lifecycle behind stable ABI headers |
| `backends/metal/runtime.zig` | Zig facade over focused ABI, resource-plan, resident-data, opening, pipeline, and session owners |
| `backends/metal/kernels.metal` | Shared headers and domain shader families linked into one core metallib, with one generated manifest and stable exports |
| `integrations/cairo_metal/arena_binding.zig` | Thin facade over statement, witness, trace, composition, commitment, opening/FRI, verification, and diagnostics phases |
| `metal_arena_plan_cli.zig` | Thin executable rooted in owned `tools/metal_arena_plan/` modules |
| `tests/metal/backend_test.zig` | Focused test families mirroring Metal ABI, resources, dispatch, parity, failure, and lifecycle ownership |
| large Python session/schedule controllers | Importable model, protocol, evidence, process, and CLI modules with unit tests independent of Metal hardware |

`kernels.metal` has already been reduced substantially, but its 1,239-line compatibility owner is
still an exception, not the target. The shader-decomposition document remains active until the AOT
and source-JIT lanes consume the same generated export/ABI manifest and the legacy owner is gone or
below the accepted ceiling.

### 6.4 Build, Script, Test, and Documentation Ownership

Repository structure is not limited to `src/`:

- keep `build.zig` in the ratchet and extract stable build-step families under `build/` until the
  root build file is an obvious project map below the normal ceiling;
- keep manually maintained Python controllers and tests in the ratchet; the SN PIE queue,
  arena-schedule, and persistent-session scripts must become thin CLI roots over named packages;
- ratchet repository-owned Rust support tools and split multi-thousand-line parser, codec, and CLI
  owners into deep modules with the same progressive-disclosure rules;
- keep private unit tests beside their module, and put cross-module integration tests only under
  `src/tests/<native|cairo|metal|riscv>/`; no new competing test-root convention is allowed;
- split the oversized Metal backend test by ABI, resource, dispatch, parity, failure, and lifecycle
  responsibility before adding more cases;
- keep `docs/README.md` as the authority index, label superseded evidence explicitly, and split a
  normative document when independent lifecycle, cache, provenance, or performance policies can no
  longer be reviewed locally.

Documentation closure includes every authority named by this goal in `docs/README.md`, explicit
supersession for older resident/GPU designs, and decomposition of the SN production monolith into
separate contract, source-chain, service/runtime, performance, and evidence-history owners behind a
thin index. Volatile line counts and status snapshots must be generated, dated, or automatically
checked for staleness.

Documentation splitting must preserve one clear authority per decision. It must not create several
partially overlapping status ledgers.

## 7. Correctness and Conformance Workstreams

### 7.1 Source and API Lock

1. Keep the consolidated Native and Cairo revision ledger authoritative and reject carrier drift.
2. Regenerate API parity and upstream-surface reports from those exact revisions.
3. Give every public Zig symbol a Rust mapping or an approved divergence record.
4. Remove stale prose status that disagrees with machine-readable reports.
5. Require deterministic vectors to include schema, revision, generator digest, seed, parameters,
   and negative cases.

Exit gate: API, upstream-surface, roadmap, divergence, and source-baseline checks all pass with no
unexplained or high-severity open item.

### 7.2 Native Stwo Lock

For CPU and Metal, exercise the same Native statements, protocol parameters, and exact proof
artifacts:

1. field, circle, FFT, transcript, hash, Merkle/VCS, PCS, quotient, FRI, proof, and verifier vectors;
2. every supported Native AIR example and representative small/medium/large geometries;
3. Zig-generated proof accepted by pinned Rust and Rust-generated proof accepted by Zig;
4. exact proof bytes where the protocol is deterministic, otherwise documented canonical
   interchange;
5. mutation/rejection tests for statement, proof, metadata, transcript, opening, and parameters;
6. explicit backend identity and proof that Metal did real device work when selected.

Exit gate: the strict Native backend suite passes from a clean checkout, and the exact timed or
gated artifacts are the artifacts accepted by Rust.

### 7.3 Complete General Cairo Port

The Zig path must implement the same mathematical statement as pinned Stwo-Cairo, not a simplified
demonstration AIR or an SN-specific geometry:

1. accept raw PIE or a production-authenticated canonical execution artifact;
2. derive the runtime claim, active component dependency closure, trace layout, and public memory;
3. generate witness programs, multiplicity feeds, relations, fixed tables, preprocessed columns,
   and composition evaluators from versioned source inputs;
4. project every base/interaction span, coefficient offset, preprocessed identity, constraint count,
   component order, and maximum log without hand-edited program cases;
5. derive runtime PCS/FRI geometry, tree counts, query openings, and compact proof layout;
6. construct and serialize a complete proof envelope;
7. accept only after local verification and the pinned Rust `verify_cairo` receipt bind the exact
   statement, proof digest, revisions, and protocol;
8. reject proof-derived semantic packs in production admission.

The same authenticated frontend product must feed program-agnostic Zig `cpu_native` and
`metal_resident` capabilities. Backend selection may change execution and storage, but not the
claim, active components, transcript order, protocol, proof schema, or verifier contract. Calling
the CPU lane `zig-cairo-simd` remains forbidden until a separate SIMD capability and telemetry
contract are implemented.

The component-by-component Rust oracle comparison remains the fastest parity loop: compare the
cumulative accumulator, claimed sums, tree roots, transcript state, quotient, FRI layers, queries,
and proof object at the earliest differing boundary. Whole-proof debugging starts only after those
checkpoints match.

Trace receipts and proof receipts are separate evidence classes:

- base and fixed-challenge interaction receipts come from the Cairo prover sub-lane, carry
  `is_proof_transcript=false`, and localize witness or relation differences only;
- transcript, commitment-root, quotient, FRI, opening, and complete-proof checkpoints use the real
  Fiat-Shamir transcript and may not be satisfied by a diagnostic receipt;
- only the canonical verifier sub-lane's exact `verify_cairo` receipt closes proof acceptance.

The canonical acceptance authority is `vectors/cairo/cairo_program_matrix.json`: exactly nine
programs by three declared tiers, or 27 unique statement/geometry cells. Fib25k is the bring-up
checkpoint and is not an ambiguous fourth benchmark tier. For every one of the 27 cells:

1. both `cpu_native` and `metal_resident` construct complete proofs from the same frontend product;
2. backend-neutral checkpoints are exact or canonically equivalent at every declared boundary;
3. the Zig verifier and pinned Rust `verify_cairo` accept each emitted proof;
4. a Rust-produced proof exercises Rust-to-Zig interchange under the same statement and schema; and
5. statement, root, claimed-sum, FRI, opening, metadata, and proof mutations are rejected.

Exit gate: Fib25k succeeds first, then all 27 manifest cells pass both Zig backend lanes and both
interchange directions with exact receipts from their applicable Rust sub-lane.

### 7.4 Production Metal Admission

1. Build the decomposed shader families into one deterministic linked core metallib.
2. Build the current witness code generation into an authenticated witness metallib.
3. Generate one manifest that binds source digests, compiler/profile, exports, argument ABI,
   function constants, and library digest.
4. Compare AOT and explicit development source-JIT reflection and outputs.
5. Admit production only from immutable, content-addressed libraries and semantic artifacts.
6. Reject missing exports, ABI drift, manifest mismatch, mutable-path identity drift, source-JIT,
   any backend fallback, and partial prewarm.
7. Keep source-JIT available only as an explicitly labelled development/parity lane.
8. Reuse the device, queue, libraries, PSOs, immutable artifacts, and geometry-bound state without
   making their caches unbounded or statement-ambiguous.

Exit gate: a `metal_resident` production request performs no runtime source compilation and records
zero backend-fallback counters; all selected pipelines are admitted before proof execution and the
resulting proof passes Rust. Explicitly labelled `metal_hybrid` evidence cannot close this gate.

### 7.5 Raw SN PIE End to End

For each of the four SN PIEs named by a checked-in content-addressed corpus manifest:

```text
raw PIE
  -> execute
  -> adapt
  -> derive claim, component closure, semantic artifacts, and schedule
  -> execute base, interaction, composition, commitment, quotient, FRI, and openings
  -> assemble compact proof
  -> verify in Zig and pinned Rust
  -> atomically publish
```

Production reports must state:

```text
self_contained=true
parity_fixture_used=false
proof_derived_artifact_used=false
provenance_complete=true
protocol_complete=true
```

No transcript, quotient, proof, nonce, decommitment, target-root, or target-accumulator fixture may
be a production input. Diagnostic parity modes must be unambiguously separate and fail production
admission.

The corpus manifest binds each raw PIE's stable identity, byte length, SHA-256 digest, source
revision or acquisition record, license/retention policy, and deterministic acquisition or
regeneration command. The nine Cairo source programs, compiler/profile, compiled artifacts, and
input tiers have an equivalent manifest. Machine-local paths such as `~/Downloads/SN-PIEs` are
resolution hints only and never evidence identities.

Exit gate: SN1-SN4 pass the live protocol and canonical Rust verifier with a complete raw-source
chain, bounded resources, exact backend identity, and no forbidden input.

### 7.6 Streaming and Lifecycle Lock

The prover is a block service, not a one-shot benchmark. One admitted process must:

1. accept a deterministic mixed queue drawn from SN1-SN4 and repeated geometries;
2. bind every cache entry to source, statement, protocol, compiler/device, library, and geometry
   identity rather than only row or component count;
3. reset transcript, proof, command, scratch, error, and publication state between blocks;
4. reuse only immutable or explicitly resettable state;
5. verify every proof independently before ordered atomic publication;
6. poison or evict failed preparation/proof state without poisoning unrelated keys;
7. bound resident bytes, cache entries, object counts, handles, and threads;
8. close cleanly with no growth or early-to-late latency drift beyond the declared threshold.

The canonical queue contract incorporates Sections 19.2 and 19.3 of
`sn-pie-metal-production-architecture.md` and the corresponding streaming contract without
weakening them. It uses seed `20260715` and the checked-in 10/100 sequences, includes A/B/A reset
checks, runs one runtime, performs no warm compile/read/rebuild, enforces the declared p95
preparation bound, reaches the 2% resource plateau, limits late-window drift to 10%, and injects
failures at requests 10, 50, and 90 without corrupting later work.

The 100-block run belongs on an explicitly scheduled, thermally controlled Metal machine; it must
not be hidden in a pre-commit hook or run casually on a developer laptop.

Exit gate: the machine-readable canonical validator accepts 10/10 and 100/100 proofs in order, every
proof passes Rust, and no process restart, runtime compilation, warm artifact read/rebuild, fallback,
resource leak, cache-identity collision, reset failure, or failure-recovery violation occurs.

## 8. Testing and Evidence Architecture

### 8.1 Test Layers

The test tree must mirror ownership and keep expensive hardware work explicit:

1. pure unit and law tests for fields, plans, schemas, keys, and state machines;
2. deterministic differential vectors against pinned Rust;
3. focused integration tests for frontend, backend, FFI, and interoperability boundaries;
4. bounded Metal correctness tests with exact CPU/Rust comparison;
5. complete Native and Cairo end-to-end proof tests;
6. raw SN PIE and streaming acceptance tests on declared hardware;
7. benchmarks and profiles, which never substitute for a correctness layer.

Bug fixes begin with a failing regression. Every reusable abstraction states and tests its laws.
Randomized tests use fixed, reported seeds. Failure-path tests cover malformed lengths, overflow,
allocation failure where injectable, ABI mismatch, cache poisoning, mutation, and wrong-backend
selection.

### 8.2 Evidence Requirements

Every conformance report must bind:

- repository commit and clean-tree state;
- Zig, Rust, Cairo, Xcode/Metal compiler, OS, and device versions;
- exact Native or Cairo lane and sub-lane oracle revisions and their roles;
- input, artifact, executable, metallib, manifest, statement, and proof digests;
- corpus-manifest identity and the manifest-resolved path or regeneration receipt;
- protocol parameters, component/trace geometry, backend identity, and fallback counters;
- ordered verifier results and negative-case results;
- command, environment, build mode, seeds, and schema version.

Evidence is immutable. A new run creates a new report and a delta against a named predecessor; it
does not overwrite historical raw data.

## 9. CI, Hooks, and Enforcement

The existing `scripts/ci.py`, hosted CI, source-conformance checker, and versioned hooks are the
foundation. Completion requires the same contracts to be authoritative rather than a parallel set
of ad hoc commands.

### 9.1 Fast Local Gate

Pre-commit remains bounded:

- staged diff whitespace checks;
- Zig formatting;
- source/dependency/generated-file conformance;
- focused checker tests.

It must not compile runtime Metal libraries, prove large PIEs, or run performance samples.

### 9.2 Pre-Push and Hosted Gate

Pre-push and hosted CI must cover:

- all Python tooling tests;
- Zig unit, deep, API-parity, upstream-surface, vector, and strict release gates;
- Rust interoperability for both explicitly pinned lanes;
- multi-language source conformance with zero baseline growth and validated exception ownership;
- deterministic Metal source generation plus compile/link and ABI/export validation on macOS;
- documentation links, generated-artifact reproducibility, and clean output checks.

Heavy raw PIE, 100-block streaming, and performance regression jobs run on labelled Apple hardware
with controlled concurrency and published evidence. Generic CI must still compile the path and
exercise host-only state machines and schemas.

### 9.3 Baseline Policy

- A new finding fails immediately.
- An existing exception may shrink but never grow.
- Removing debt requires removing its baseline entry in the same commit.
- An exception requires a repository-local plan, owner, reason, current cap, and next extraction.
- CI cannot update a baseline automatically.
- No bypassed hook or skipped hardware job may be represented as a passing release gate.

## 10. Delivery Sequence

Each increment is a focused commit with the relevant tests and status update.

### Phase 0: Freeze Authority and Restore the Ratchet

- adopt this goal as the optimization lock;
- retain consolidated pin ownership and reconcile stale status claims;
- extract enough responsibility from the four over-budget files to make source conformance green;
- forbid further legacy-budget growth.

Exit: documentation authority is unambiguous and the fast local gate passes.

### Phase 1: Revalidate Shared and Native Conformance

- run the complete shared-vector and Native backend matrix;
- close public API, proof-format, and negative-case gaps;
- bind the exact accepted artifacts to both local and Rust verifier receipts.

Exit: Native CPU and Metal are conformant foundations for Cairo work.

### Phase 2: Close General Cairo Semantics

- use per-component oracle parity to complete claim, AIR, witness, relation, fixed-table,
  composition, transcript, PCS/FRI, and proof interchange;
- remove demonstration and SN-specific assumptions from the general entrypoint;
- advance through the exact 27-cell Cairo manifest in both backend lanes and interchange directions.

Exit: all 27 cells have real `cpu_native` and `metal_resident` Zig proofs accepted by Zig and Rust,
plus Rust-produced proofs accepted by Zig and the complete negative matrix.

### Phase 3: Close Production Metal Inputs and Compilation

- finish shader/ABI decomposition needed for deterministic AOT;
- build and admit core and witness metallibs;
- replace mutable-path and proof-derived inputs with authenticated immutable sources;
- make production mode fail closed.

Exit: a production request has no JIT, fallback, mutable artifact, or proof-derived dependency.

### Phase 4: Close Raw SN PIE and Streaming

- prove SN1-SN4 from their raw source chain;
- integrate the runtime-geometry proof envelope with the persistent service;
- pass the canonical seeded 10-block and controlled 100-block mixed queues, A/B/A reset, failure
  injection, warm-path prohibition, drift, and resource bounds.

Exit: the Metal service can receive blocks, prove, verify, publish, reset, and continue.

### Phase 5: Finish Structural Debt and Enforcement

Behavior-preserving decompositions run alongside Phases 1-4 whenever they reduce the boundary being
changed. This final phase removes residual exceptions, misplaced roots, cycles, shallow facades,
and stale plans, then makes every applicable gate blocking.

The enforcement inventory covers manual Zig, MSL, Objective-C/C headers, Python, Rust support code,
and `build.zig`, plus the dependency and generated-file rules applicable to each ownership layer.
Every transition exception has a validated owner, reason, cap, and next extraction before the final
baseline reaches zero. Documentation authorities are indexed and the oversized SN architecture is
split by independent policy ownership.

Exit: the target tree and dependency rules are mechanically true, not aspirational.

### Phase 6: Freeze the Optimization Baseline

- run the broad Native and Cairo CPU/Metal benchmark suites from clean ReleaseFast builds;
- record cold, resident, proof-only, total request, verification, and sustained queue timing;
- preserve raw samples, profiler baselines, environment, digests, and immutable delta files;
- publish known fallback and residency classifications without marketing labels.

Exit: subsequent performance changes have a trustworthy, broad, reproducible comparator.

## 11. Optimization Unlock Checklist

Aggressive optimization begins only when all boxes are checked:

- [x] One scope-aware upstream pin ledger governs Native and both Cairo sub-lanes.
- [ ] API parity, upstream surface, roadmap, divergence, and source-conformance checks pass.
- [x] The source-conformance ratchet inventories `src`, build ownership, maintained Python, and
      repository Rust tools with validated no-growth exception metadata.
- [ ] The source-conformance baseline is empty and no manual legacy file exceeds the normal policy
      ceiling.
- [ ] Native CPU and Metal exact artifacts pass Zig and pinned Rust acceptance.
- [ ] Rust-to-Zig and Zig-to-Rust proof interchange and negative cases pass.
- [ ] The general Cairo proof path is complete and program-agnostic.
- [ ] All 27 canonical Cairo cells pass `cpu_native` and `metal_resident`, Zig/Rust acceptance in
      both directions, and the complete tamper matrix.
- [ ] Current core and witness AOT metallibs pass export, ABI, manifest, and parity gates.
- [ ] Production `metal_resident` rejects source-JIT, every fallback, partial admission, and mutable
      identity drift; all backend-fallback counters are zero.
- [ ] Content-addressed SN PIE and Cairo corpus manifests resolve every external input used by a gate.
- [ ] SN1-SN4 prove from complete raw source chains without parity or proof-derived inputs.
- [ ] Every SN proof verifies in Zig and the canonical Rust `verify_cairo` oracle.
- [ ] The canonical seed-`20260715` 10/100 queues pass A/B/A reset, failure injection, warm-path,
      drift, resource, verification, and publication gates.
- [ ] Cache, memory, handle, thread, and artifact growth remain within declared bounds.
- [ ] Local and hosted CI invoke the same checked-in gate definitions.
- [ ] The repository is clean apart from inputs resolved through checked-in corpus manifests, and all
      generated artifacts are reproducible.
- [ ] A broad, immutable pre-optimization benchmark and profile baseline is committed.

Any unchecked item keeps the optimization lock closed.

## 12. Definition of Done

This goal is complete when a reviewer can start from a clean checkout plus only external inputs
resolved and authenticated through checked-in corpus manifests, without private knowledge or
anonymous untracked artifacts, and establish all of the following:

1. what is being proved and which Native or Cairo lane/sub-lane revisions define each correctness
   checkpoint and final acceptance;
2. where each protocol, frontend, backend, integration, interop, and service responsibility lives;
3. that Native CPU and Metal prove the same accepted statement;
4. that general Cairo and all four SN PIEs produce complete proofs accepted by pinned Rust;
5. that production inputs are raw or canonically generated rather than proof-derived;
6. that `metal_resident` admission is deterministic, AOT, fail-closed, and has zero backend fallback;
7. that a mixed queue can prove, verify, publish, reset, and continue with bounded resources;
8. that source size, dependency direction, API parity, generated artifacts, and tests are enforced;
9. that every performance number names its lifecycle, backend, proof, verifier, and provenance;
10. that the next optimization can be judged by a broad delta without reopening correctness or
    repository-ownership questions.

At that point, [`2026-07-17-backend-performance-program.md`](2026-07-17-backend-performance-program.md)
moves from normative-but-blocked to active execution. Optimization then proceeds from profiles and
cost models across the broad Native and Cairo suites, with the same oracle and repository gates
remaining permanently blocking. The Rust-relative performance targets in the release contract are
then pursued and remain release gates; they were not silently converted into readiness gates here.
