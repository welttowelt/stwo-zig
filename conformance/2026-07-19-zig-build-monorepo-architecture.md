# Zig build-monorepo architecture

Status: **accepted direction; implementation is incremental**

This document defines how stwo-zig becomes a monorepo of explicit build
products instead of one product that happens to contain every frontend and
backend. It complements [CONTRIBUTING.md](../CONTRIBUTING.md),
[decomposition-plan.md](decomposition-plan.md), and the RISC-V release
contracts. The source ownership rules remain authoritative; this document
adds compile-closure and build-graph requirements.

## Problem statement

The repository already separates `core`, generic `prover`, frontends,
backends, and integrations in source. The build graph does not yet express
those boundaries strongly enough:

- `src/stwo.zig` re-exports every frontend, backend, integration, example, and
  tool surface;
- the production CLI directly imports both Native and RISC-V dispatch;
- macOS products link the Metal runtime based on host OS rather than an
  explicit product capability;
- one root build file declares CPU, RISC-V, Cairo, Metal, CUDA, test, benchmark,
  and release-evidence products together; and
- a focused release or performance lane cannot prove mechanically that an
  unrelated frontend or backend is outside its compile and link closure.

Zig gives the developer control over the compilation graph. Product boundaries
must therefore be deliberate data, not an accidental consequence of lazy
analysis.

## Goals

1. A pure Zig CPU/SIMD Stwo prover can build, test, benchmark, and ship without
   importing Cairo, RISC-V, Metal, CUDA, or Objective-C runtime code.
2. Each frontend can be composed with only the backend capabilities it needs.
3. Metal and CUDA are explicit opt-in products. Host OS alone never selects a
   backend or silently broadens a binary.
4. The RISC-V release challenge builds only `RISC-V + CPU/SIMD` and remains
   inside the three-minute gate without compiling unrelated products.
5. The aggregate `stwo-zig` CLI remains available as a compatibility product,
   assembled from the same focused components rather than owning protocol
   logic.
6. CI, benchmarks, profiler runs, and caches identify the exact product and
   capability set they measured.

## Non-goals

- This is not a wholesale source move or package-manager experiment.
- It does not duplicate core, prover, transcript, artifact, or verifier logic.
- It does not resume deferred Cairo conformance work.
- It does not make Metal available on unsupported hosts or permit CPU fallback
  in a device-labelled product.
- It does not require every internal module to become a separately versioned
  external package.

## Product matrix

Every shipped executable or library declares one frontend set and one backend
set. The initial matrix is:

| Product | Frontend | Backend | Intended use |
| --- | --- | --- | --- |
| `stwo-core` | none | none | Fields, transcript, proof types, verifier, protocol laws |
| `stwo-prover` | none | capability contracts | Backend-generic proving algorithms |
| `stwo-native-cpu` | Native examples | CPU scalar/SIMD | Portable proving, CPU benchmarks, Rust parity |
| `stwo-riscv-cpu` | Stark-V RV32IM | CPU scalar/SIMD | ELF execution, proving, release challenge |
| `stwo-cairo-cpu` | Cairo | CPU scalar/SIMD | Deferred Cairo execution/proving lane |
| `stwo-native-metal` | Native examples | Metal | Native Metal performance and parity |
| `stwo-cairo-metal` | Cairo | Metal | SN-PIE proving and resident block service |
| `stwo-riscv-metal` | RISC-V | Metal | Experimental only until independently gated |
| `stwo-zig` | selected released frontends | selected released backends | Compatibility CLI and application registry |

CUDA follows the same composition rule when active. It is never injected into
another product by a global boolean.

## Layered module graph

The intended named Zig modules and dependency direction are:

```text
stwo_core
    ^
    |
stwo_backend_contracts <- stwo_prover
    ^                        ^
    |                        |
stwo_backend_cpu       frontend_{native,riscv,cairo}
    ^                        ^
    +------------+-----------+
                 |
       integration_<frontend>_cpu
                 |
          product CLI / library

stwo_backend_metal and stwo_backend_cuda are sibling implementations of the
backend contracts. They never sit below `stwo_core` or a frontend.
```

Named imports are the enforcement mechanism. A package surface must import
`stwo_core`, `stwo_prover`, or a backend contract explicitly instead of
reaching through the broad `stwo` convenience root. Relative imports remain
valid inside one ownership package, but must not tunnel across package
boundaries.

The broad `src/stwo.zig` root becomes an opt-in SDK facade. Focused products do
not import it.

## Build directory structure

The root `build.zig` becomes a small compatibility dispatcher. Product and
gate ownership lives below `build_support/`:

```text
build_support/
|-- graph/
|   |-- modules.zig          named module construction and capability types
|   |-- identity.zig         source, product, target, and capability identity
|   `-- install.zig          common explicit installation helpers
|-- products/
|   |-- native_cpu.zig
|   |-- riscv_cpu.zig
|   |-- cairo_cpu.zig
|   |-- aggregate_cli.zig
|   `-- interop.zig
|-- backends/
|   |-- metal.zig
|   `-- cuda.zig
|-- gates/
|   |-- native.zig
|   |-- riscv.zig
|   |-- metal.zig
|   `-- release.zig
`-- benchmarks/
    |-- native.zig
    |-- riscv.zig
    `-- metal.zig
```

This is one repository and one source of protocol truth, but several
independently constructible build graphs. If Zig package boundaries later
provide measurable cache or distribution value, focused nested
`build.zig.zon` packages may wrap these graph constructors. Source is not moved
merely to manufacture packages.

## Capability declaration

Product construction accepts a typed capability set. It must not infer product
semantics from the host:

```zig
const Product = struct {
    frontend: enum { none, native, riscv, cairo, aggregate },
    backend: enum { none, cpu, metal, cuda },
    role: enum { library, cli, benchmark, test, gate },
};
```

The actual implementation may use separate types when that produces a deeper
interface. The invariants are mandatory:

- invalid pairs fail during build-graph construction;
- Metal linkage is requested only by a Metal product;
- a backend-labelled command never falls back to another backend;
- the application registry is generated from the compiled product manifest;
- help and accepted flags expose only compiled capabilities; and
- a product identity digest binds source commit/tree, target, optimization,
  frontend set, backend set, CPU features, and protocol feature flags.

## Focused RISC-V release product

The first required slice is `stwo-zig-riscv-cpu`. Its compile closure is:

```text
core + backend contracts + generic prover + CPU scalar/SIMD
     + RISC-V frontend + RISC-V/CPU integration
     + RISC-V artifact codec + focused CLI shell
```

It excludes:

- `src/frontends/cairo/` and all Cairo integrations;
- `src/backends/metal/`, Metal Objective-C sources, frameworks, and shaders;
- `src/backends/cuda/` and CUDA libraries;
- Native example AIR dispatch and Native benchmark products; and
- Metal/Cairo operational tools.

The promotion challenge builds this exact product with `ReleaseFast`, embeds
the exact candidate commit and dirty state, hashes the resulting executable,
and records product identity in the challenge receipt. The reusable exhaustive
anchor supplies the pinned Rust oracle and independent verifier. No aggregate
CLI build is allowed on this critical path.

## Tests and mechanical enforcement

Every focused product needs four classes of evidence:

1. **Build closure:** a clean build succeeds on its supported target while
   unavailable SDKs and unrelated backend libraries are absent.
2. **Import closure:** a source-conformance rule rejects forbidden named or
   relative imports for that product's owned roots.
3. **Visible capability:** `--help` and the machine-readable registry contain
   exactly the product's compiled frontend/backend set.
4. **Behavior:** the focused binary proves and an independently selected
   verifier accepts; unsupported frontend/backend requests fail before output.

Linux CI must build `stwo-native-cpu`, `stwo-riscv-cpu`, and their focused test
graphs without Metal. macOS Metal CI builds focused Metal products separately;
passing a CPU job does not count as compiling or testing Metal. Cairo products
remain disabled with an explicit reason until their conformance lane resumes.

Source conformance must eventually enforce a matrix like:

| Owner | Forbidden dependencies |
| --- | --- |
| `core` | prover, frontends, integrations, concrete backends |
| generic `prover` | frontends, integrations, Metal/CUDA runtime policy |
| CPU backend | frontends, Metal, CUDA |
| RISC-V frontend | Cairo, concrete Metal/CUDA runtime |
| RISC-V/CPU integration | Cairo, Metal, CUDA |
| Metal backend | frontend policy and Cairo statement types |
| focused product shell | every frontend/backend outside its manifest |

## Cache and benchmark identity

Build and benchmark caches are per product. A cache key that says only
`ReleaseFast` is incomplete. At minimum it binds:

- product schema and product name;
- source commit/tree and dirty state;
- Zig version, target triple, CPU model/features, and optimization mode;
- frontend and backend capability manifests;
- linked runtime/SDK identity where applicable; and
- generated shader/archive semantic identities for Metal products.

Benchmark rows carry the same product identity. CPU/SIMD and Metal numbers are
never emitted by one ambiguous aggregate binary without recording which
compiled path ran.

## Migration sequence

1. **RISC-V CPU product:** extract the focused product descriptor and CLI
   composition; use it in the fast promotion challenge.
2. **Graph factory:** centralize named core/prover/backend modules and product
   identity without moving protocol code.
3. **Native CPU product:** move Native dispatch and CPU benchmarks onto the
   focused graph; retain output parity with the aggregate CLI.
4. **Metal products:** move linkage and tools under explicit Metal graph
   constructors; delete host-OS-driven linkage from non-Metal products.
5. **Frontend products:** isolate Cairo and RISC-V test/CLI graphs; keep Cairo
   disabled until its own oracle gates return.
6. **Thin root:** reduce `build.zig` to options, product selection, and calls to
   focused graph owners; split release/benchmark gates by their actual scope.
7. **Facade cleanup:** make `src/stwo.zig` an opt-in SDK facade and migrate
   focused products to named imports.

Each slice is behavior-preserving, independently reviewable, and must shrink
rather than grow the source-conformance debt ledger.

## Acceptance checklist

- [ ] `stwo-zig-riscv-cpu` builds and runs without Metal/Cairo linkage.
- [ ] The RISC-V fast challenge uses only that product.
- [ ] `stwo-native-cpu` has its own build, test, and benchmark graph.
- [ ] Metal products are opt-in and are the only products linking Metal.
- [ ] Cairo, RISC-V, and Native product registries expose only compiled lanes.
- [ ] Import-closure checks enforce the layer matrix.
- [ ] Product identity is present in proof, benchmark, cache, and gate receipts.
- [ ] Aggregate CLI output remains compatible for released applications.
- [ ] Pinned Rust Stwo/Stark-V evidence remains the final correctness oracle.
