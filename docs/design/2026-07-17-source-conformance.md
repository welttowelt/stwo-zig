# Source Conformance Migration

Status: active

## Purpose

Bring `src/` into conformance with [`CONTRIBUTING.md`](../../CONTRIBUTING.md) without changing
Stwo protocol behavior, proof formats, security parameters, or benchmark semantics. The migration
prioritizes Native Stwo and Cairo. RISC-V-specific restructuring follows only after shared proof
and backend boundaries are stable.

The pinned Rust Stwo revision remains the final correctness oracle throughout the migration.

## Initial Baseline

The first 2026-07-17 inventory found the following conditions. These numbers describe the migration
entry point and are retained to show the direction of travel; they are not a statement about HEAD:

- 258 Zig source files and about 113,000 total source lines;
- 24 tracked Zig files above the 850-line manual-source ceiling;
- a 4,547-line PCS module and several 1,200-2,500-line prover algorithms;
- a 7,627-line Cairo-to-Metal arena binding module;
- CLI, test, artifact, and session implementation files mixed into the `src/` root;
- cross-layer tests under `core` that import `prover` and examples;
- generic prover modules that import concrete CPU and Metal backends;
- direct Cairo-to-Metal and Metal-to-Cairo imports with no integration boundary;
- no general hosted CI workflow, local CI entrypoint, hook installer, or source-conformance linter.

Line count is a signal, not the migration objective. Each extraction must reduce the concepts and
dependency edges a reader needs to understand.

## Progress Checkpoint

The first migration pass has established these boundaries without changing proof formats:

- PCS sampled-value evaluation, column preparation, tree construction, and integration tests now
  live in separate modules instead of a single prover facade.
- Lifted VCS columns, tuning parameters, Merkle layer construction, leaf construction, and tests
  are separate responsibilities. The facade is below the 850-line ceiling.
- Rust-oracle review found and corrected missing lifted Blake2 leaf and node prefixes in the Zig
  scalar, SIMD, and Metal paths; parity tests cover the corrected protocol behavior.
- Rust-generated parity vectors are split into field, PCS/FRI, proof/VCS, and example families
  behind one test root; all 27 oracle tests retain their names and shared schemas have one owner.
- Cairo witness geometry is owned by the proof plan, and Cairo-to-Metal orchestration is under the
  integration layer rather than the frontend.
- The 3,604-line, 90-entry-point Metal shader monolith has an explicit
  [shader-library decomposition plan](2026-07-17-metal-shader-library-decomposition.md). The plan
  preserves one linked core metallib and stable exported ABI while separating shader families and
  replacing source-sentinel codegen coupling.
- Resident arena planning, schedule selection, SN2 decommit geometry, and core FRI geometry have
  independent modules. Metal execution remains outside the pure scheduling layer.
- Arena-plan admission now delegates epoch/address-width policy and schedule coverage/shape checks
  to focused host-only modules. Transcript fixtures, proof-layout derivation, and opt-in diagnostics
  also have focused owners under `tools/metal_arena_plan/`. The one-shot runner consumes the shared
  `stwo` module rather than privately owning a second copy of the Cairo and Metal source graph.
- Metal resource layouts, prepared-plan ownership, destructor bindings, and environment policy now
  live in `backends/metal/runtime/resource_plans.zig`. The runtime facade retains all 31 public
  names while dispatch, allocation, and the Objective-C ABI remain unchanged.
- FRI folding, quotient, transcript, and sparse-opening Objective-C declarations now live in
  `backends/metal/runtime/opening_bindings.zig`. The facade retains its call sites through exact
  private aliases, with shared ABI parameter types checked in the canonical Metal test graph.
- Resident trace materialization and commitment declarations, plus resident buffer and tree
  ownership, now live in `backends/metal/runtime/resident_data.zig`. Selective readback and resource
  lifetime semantics remain available through the runtime facade.
- Cairo resident interaction execution and witness-input seeding have focused owners below
  `integrations/cairo_metal/resident/`; the arena-binding facade retains the stable public names.
- Cairo commitment ordering now has a focused resident owner for canonical AIR reconstruction,
  degree-order projection, tree-purpose collection, and query-value reordering.
- Cairo composition environment policy and evaluator-library selection now have a focused config
  owner, including bounded component-prefix diagnostics used by the Rust-oracle parity loop.
- Metal commitment, compaction, EC-op, and recovery benchmarks live under `src/bench/metal/` and
  consume the public `stwo` module while preserving their installed executable contracts.
- The proof interoperability CLI is split by process lifecycle, argument policy, artifact I/O,
  example dispatch, and benchmark reporting under `src/tools/interop/`. Build and Python harnesses
  share that owned entry point; the 1,186-line root implementation and its compatibility facade are
  removed.
- The persistent Metal prover session is split under `src/tools/metal_prover_session/` by lifecycle,
  state/cache ownership, artifact preparation, verification/publication, protocol tests, and cache
  tests. Its former 2,984-line root implementation is removed.
- `scripts/check_source_conformance.py` provides a blocking ratchet for dependency direction,
  root-source placement, generated-file declarations, and the 850-line ceiling across Zig, Metal,
  and Objective-C source. Oversized exceptions cannot grow beyond their checked-in line budgets,
  and every exception names a repository-local decomposition plan.
- `scripts/ci.py` is the shared local and hosted CI entrypoint. Versioned pre-commit and pre-push
  hooks provide bounded local feedback without running hardware Metal or large SN PIE workloads.

The checked-in enforcement baseline contains 16 explained legacy findings: 1 dependency edge,
10 oversized manually maintained files, and 5 misplaced root sources. Each size exception records
an immutable line budget and a repository-local decomposition plan. New findings, oversized-file
growth, missing plans, and stale baseline entries fail the check. Removing a violation therefore
requires removing its baseline entry in the same change.

## Current Ratchet State

After the Phase-0 restoration on 2026-07-17, HEAD contains 455 Zig files and 128,034 Zig source
lines. Ten manually maintained Zig, Metal, or Objective-C files remain above 850 lines. The source
baseline still contains 16 findings: 10 size exceptions, five misplaced roots, and one forbidden
RISC-V dependency edge.

Four legacy owners had grown past their immutable caps during later Cairo/AOT work. Their focused
protocol-admission, runtime-initialization, and retained-Merkle storage responsibilities have now
been extracted without raising a cap. `python3 scripts/check_source_conformance.py` is green again
and reports no new violations.

This is restored ratchet compliance, not migration completion. Native and Cairo/Metal work must
remove the seven non-RISC-V findings. The final RISC-V phase removes the remaining nine findings,
leaving `docs/conformance/source-baseline.json` empty before the optimization lock can open.

## Invariants

1. `core` contains backend-independent mathematics, protocol types, transcripts, and verification.
2. `backend` defines capabilities without importing a concrete implementation.
3. `prover` depends on capabilities, not backend names or device representations.
4. Frontends define statement, AIR, witness, and proof-plan semantics without Metal handles or
   shader policy.
5. Concrete backends implement capabilities without importing a frontend.
6. A Cairo-Metal integration layer may depend on both Cairo and Metal, but neither side may depend
   back through that layer.
7. Evidence and cross-layer parity harnesses live under `interop` or dedicated tests, never under
   a lower protocol layer.
8. Moves preserve public API names unless an API-parity change is designed and recorded explicitly.
9. Every behavior-affecting slice passes Zig tests and the pinned Rust interoperability gates.

## Target Layout

```text
src/
|-- stwo.zig
|-- std_shims_freestanding.zig  alternate freestanding verifier build root
|-- core/                       protocol, fields, verifier
|-- backend/                    backend capability contracts
|-- prover/                     generic proving algorithms
|-- backends/
|   |-- cpu_scalar/
|   |-- metal/
|   `-- cuda/
|-- frontends/
|   |-- cairo/
|   `-- riscv/
|-- integrations/
|   `-- cairo_metal/            typed bridge; depends on Cairo and Metal
|-- interop/                    wire formats, parity, Rust oracle boundary
|-- examples/                   native Stwo AIR examples
|-- bench/                      benchmark execution primitives
|-- tools/                      executable entry points and operational adapters
`-- tests/                      cross-module integration and backend tests
```

The layout is introduced only where an ownership boundary is ready. Empty scaffolding and shallow
forwarders are not acceptable.

`std_shims_freestanding.zig` is an intentional build root rather than misplaced implementation
code. It contains only the declarations needed to establish the freestanding verifier's Zig module
boundary; moving it below a directory changes relative import ownership and makes the verifier pull
the hosted source graph. Keep algorithms and reusable declarations out of this file.

## Migration Sequence

### 1. Native Stwo boundaries

- Move cross-layer parity harnesses out of `core` into `interop/parity`.
- Separate test-only dependencies from public `core` surfaces.
- Remove concrete backend imports from generic prover algorithms by passing capabilities or moving
  default-CPU convenience entry points to the CPU backend boundary.
- Decompose PCS by stable responsibility: scheme state, tree construction, sampled values,
  decommitment, quotient integration, and focused tests.
- Decompose core/prover FRI and VCS modules along commit, fold, decommit, and verification phases.
- Keep field arithmetic and proof/transcript order unchanged, with Rust-bound vectors covering each
  extraction.

### 2. Cairo boundaries

- Separate statement binding, input adaptation, trace geometry, witness construction, proof plans,
  and resident execution.
- Replace raw Metal types in Cairo modules with backend-neutral plans, typed offsets, and validated
  witness/evaluation programs.
- Move Cairo-specific Metal orchestration and code generation into `integrations/cairo_metal`.
- Decompose arena binding by ownership class and proving stage; the arena remains a lifetime
  mechanism rather than a shared policy container.
- Split resident verification, quotient preparation, and statement bootstrap into focused stages
  with component-level parity tests.

### 3. Shared source hygiene

- Move executable roots to `src/tools/<domain>/` and integration tests to `src/tests/<domain>/`.
- Keep `mod.zig` files as explicit public maps, not implementation warehouses.
- Add module docs to ownership boundaries and remove broad convenience exports that leak
  representation.
- Extend source conformance to manually maintained `.metal` files and enforce shader include
  direction, exported-symbol ownership, generated-file markers, and the 850-line ceiling. Follow
  the staged [Metal shader plan](2026-07-17-metal-shader-library-decomposition.md); do not turn a
  source split into new runtime libraries, dispatches, or cache dimensions.
- Record temporary size exceptions with owners and next extraction boundaries.

### 4. RISC-V

Apply the same frontend split after shared prover and backend APIs settle. RISC-V must not drive a
shared abstraction unless Native Stwo or Cairo also needs it.

### 5. Enforcement and delivery

- Add a repository conformance checker for forbidden dependency edges, naming, file-size budgets,
  root-source allowlists, generated-file markers, and required documentation.
- Introduce checks in advisory mode first, with a checked-in baseline for legacy findings.
- Add a single local CI command used by both developers and hosted CI.
- Add fast pre-commit and broader pre-push hooks plus an idempotent hook installer.
- Add hosted CI for formatting, unit tests, dependency conformance, Python tooling tests, vectors,
  API parity, and Rust interoperability. Keep hardware Metal performance jobs separate and clearly
  labeled because generic hosted runners cannot establish Apple GPU performance.
- Promote advisory checks to blocking only after the corresponding migration phase is complete.

## Verification Per Slice

Every structural slice must provide:

1. `zig fmt --check` on all affected Zig files;
2. focused tests for the moved modules;
3. `zig build test` and the relevant deep/backend test;
4. API-parity and forbidden-dependency checks;
5. bidirectional Rust/Zig interop when a proof, transcript, field, PCS, FRI, or public surface can
   change;
6. benchmark comparison only when runtime code changes;
7. `git diff --check` and no generated or build artifacts in the commit.

Pure moves may use equivalent compile and vector gates, but do not inherit correctness merely from
having no intended semantic change.

## Completion Criteria

The migration is complete only when:

- all dependency invariants are mechanically enforced;
- no manually maintained Zig, Metal, or Objective-C file exceeds 850 lines;
- `docs/conformance/source-baseline.json` has no legacy findings;
- Native Stwo and Cairo ownership boundaries match the target responsibilities;
- public APIs pass the parity ledger and pinned Rust oracle gates;
- the same checked-in CI entrypoint passes locally and in hosted CI;
- hook installation and bypass behavior are documented and tested;
- lint and conformance checks are blocking with no unexplained baseline debt;
- full release, interoperability, and tamper gates pass from a clean checkout.
