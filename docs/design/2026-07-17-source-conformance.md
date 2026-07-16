# Source Conformance Migration

Status: active

## Purpose

Bring `src/` into conformance with [`CONTRIBUTING.md`](../../CONTRIBUTING.md) without changing
Stwo protocol behavior, proof formats, security parameters, or benchmark semantics. The migration
prioritizes Native Stwo and Cairo. RISC-V-specific restructuring follows only after shared proof
and backend boundaries are stable.

The pinned Rust Stwo revision remains the final correctness oracle throughout the migration.

## Baseline

The 2026-07-17 inventory found:

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
- no manually maintained file exceeds 850 lines without a documented, reviewed exception;
- Native Stwo and Cairo ownership boundaries match the target responsibilities;
- public APIs pass the parity ledger and pinned Rust oracle gates;
- the same checked-in CI entrypoint passes locally and in hosted CI;
- hook installation and bypass behavior are documented and tested;
- lint and conformance checks are blocking with no unexplained baseline debt;
- full release, interoperability, and tamper gates pass from a clean checkout.
