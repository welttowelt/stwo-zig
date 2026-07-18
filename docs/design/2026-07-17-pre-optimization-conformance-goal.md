# Pre-Optimization Repository and Backend Readiness Goal

Status: complete; Native optimization baseline unlocked
Priority: repository structure, shared Stwo, Native CPU/Metal backends, then performance engineering
Deferred TODO: all Cairo, SN PIE, streaming, RISC-V, and SNIP-36 implementation work
Completion signal: every optimization-unlock item in Section 11 passes from a clean checkout

## 1. Goal

Make this repository a disciplined, high-performance Zig implementation of Stwo that is safe to
optimize aggressively. The active goal is no longer complete Cairo delivery. It is to establish:

1. a mechanically enforced repository structure that follows
   [`CONTRIBUTING.md`](../../CONTRIBUTING.md);
2. backend-neutral shared Stwo and prover ownership;
3. correct, explicitly named Native CPU and Metal backend capabilities;
4. deterministic Metal build, ABI, shader-library, cache, and lifecycle boundaries;
5. exact Native proof acceptance by the pinned Rust Stwo oracle; and
6. a broad benchmark and profiler system that can measure general performance changes without
   optimizing one fixture or confusing setup, proof, verification, and service time.

The delivery chain is:

```text
engineering contract and pinned Rust authority
    -> mechanically conformant source tree
    -> explicit backend capability and ownership boundaries
    -> deterministic CPU/Metal build and runtime admission
    -> Native Stwo CPU/Metal proof parity
    -> broad immutable benchmark and profiler baseline
    -> aggressive high-performance engineering unlocked
```

This is an optimization-readiness gate, not a claim that every frontend is complete and not full
release signoff. Once it closes, profiler-led SIMD, Metal, fusion, residency, command-graph, memory
layout, and algorithmic work may proceed while correctness and source-conformance checks remain
permanently blocking.

## 2. Scope

### 2.1 Required Now

- repository ownership and progressive disclosure across the shared Stwo core, prover, Native
  examples, CPU/Metal backends, their tests and tools, performance scripts, and `build.zig`;
- shared fields, transcript, PCS, FRI, proof, verifier, backend interfaces, and interop boundaries;
- all six Native Stwo AIR examples through the same CPU/Metal proof transaction;
- bidirectional Native proof interchange with the pinned Rust Stwo oracle;
- CPU scalar and SIMD ownership, capability naming, tests, and benchmark telemetry;
- Metal runtime, shader families, linked core metallib, ABI manifest, pipeline admission, resource
  lifecycle, caching, and device-work telemetry;
- deterministic source-JIT development parity and fail-closed AOT release admission;
- broad benchmark history, delta reports, bounded profiling, and reproducible performance gates;
- local hooks and hosted CI that execute the same checked-in contracts.

### 2.2 Deferred TODO Tracks

Cairo, SN PIE, streaming, RISC-V, SNIP-36, and their dedicated integration/support tools are not
active implementation or decomposition work in this goal. Existing code and evidence are
preserved. The repository-wide source ratchet still forbids new debt or growth beyond each owned
exception, but existing deferred findings do not block Native/backend optimization readiness.

The following do not block the performance-engineering unlock:

- completing all Stwo-Cairo-Zig AIR, witness, interaction, composition, PCS/FRI, and proof semantics;
- executing the complete 27-cell Cairo acceptance matrix;
- producing raw SN1-SN4 proofs through the production Cairo path;
- the 10/100-block SN PIE streaming service gates;
- SNIP-36 proving or benchmarking; and
- RISC-V AIR or Rust-oracle completion beyond shared-backend regression coverage.

Those remain explicit future tracks under:

- [`2026-07-17-cairo-program-matrix.md`](2026-07-17-cairo-program-matrix.md);
- [`cairo-zig-prover-entrypoint.md`](../cairo-zig-prover-entrypoint.md);
- [`sn-pie-metal-production-architecture.md`](../sn-pie-metal-production-architecture.md);
- [`sn-pie-streaming.md`](../sn-pie-streaming.md); and
- [`riscv-rust-parity.md`](../riscv-rust-parity.md).

Existing Cairo conformance work is preserved as future evidence. In particular, the pinned Fib25k
base receipt and exact 30-component, 396-column Zig parity remain valid; they simply no longer gate
the start of general backend optimization.

### 2.3 Work Allowed Before Unlock

- correctness, security, and Rust-oracle differential fixes;
- source decomposition and dependency-boundary repair;
- backend capability, ABI, AOT, cache, and lifecycle closure;
- benchmark/profiler harness correctness and immutable evidence work;
- bounded measurements needed to validate a gate or explain a resource failure; and
- behavior-preserving cleanup with exact regression evidence.

### 2.4 Work Deferred Until Unlock

- benchmark-specific shortcuts or program-name branches;
- arithmetic, SIMD, shader-fusion, command-graph, or memory-layout tuning for throughput;
- performance changes justified only by one microbenchmark;
- headline MHz claims from fallback-ambiguous, fixture-assisted, incomplete, or unverified paths;
- new proof systems, frontends, or unrelated product surface.

A bounded performance change may proceed before unlock only when required to make a correctness or
resource gate executable. It must preserve oracle parity, include before/after evidence, and cannot
be presented as the start of the optimization program.

## 3. Normative Authority

| Authority | Governs | Required use |
| --- | --- | --- |
| [`CONTRIBUTING.md`](../../CONTRIBUTING.md) | Zig/HPC/Metal engineering, ownership, size, testing, benchmarking, and review | Applies to every change |
| [`conformance/contract.md`](../conformance/contract.md) | Shared and Native protocol/API/proof/release contracts | Applicable Native and shared gates remain blocking |
| [`conformance/upstream.md`](../conformance/upstream.md) | Scope-aware Rust revision ledger | Native Stwo pin is the final active correctness oracle |
| [`conformance/api-parity.md`](../conformance/api-parity.md) | Public Zig-to-Rust API mapping | Every changed shared/Native public API has a mapping or divergence |
| [`conformance/divergence-log.md`](../conformance/divergence-log.md) | Intentional semantic differences | No unrecorded divergence is allowed |
| [`2026-07-17-source-conformance.md`](2026-07-17-source-conformance.md) | Target tree, dependency direction, migration, and ratchet | Operational structure plan |
| [`source-baseline.json`](../conformance/source-baseline.json) | Owned transition exceptions, active/deferred tracks, and no-growth caps | Active Native/backend track must be empty; all tracks remain no-growth |
| [`2026-07-17-native-backend-suite.md`](2026-07-17-native-backend-suite.md) | Six-example backend-neutral Native proof matrix | Active proof acceptance suite |
| [`2026-07-17-metal-shader-library-decomposition.md`](2026-07-17-metal-shader-library-decomposition.md) | Shader families, stable ABI, linked metallib, AOT/JIT policy | Active Metal source/build contract |
| [`2026-07-17-metal-backend-peer-review.md`](2026-07-17-metal-backend-peer-review.md) | Architectural peer comparison and command/resource targets | Design input, not correctness authority |
| [`2026-07-17-backend-performance-program.md`](2026-07-17-backend-performance-program.md) | Profiler-led Native and later Cairo optimization | Becomes active after this goal closes |

`docs/README.md` is the authority index. Historical documents and benchmark reports are evidence of
a particular state, not contracts. When documents conflict, correctness/security contracts win,
then the newer scope-specific architecture, then checked-in machine-readable evidence. A status
claim cannot override a failing executable gate.

The upstream ledger already separates Native Stwo and Cairo verifier/prover authorities. This goal
uses the Native Stwo revision for active proof acceptance. Cairo sub-lane receipts remain useful but
cannot broaden the active Native claim.

## 4. Current Baseline

### 4.1 What Is Already Strong

- Native CPU and Metal produce canonical proof artifacts that have been accepted by the pinned Rust
  Stwo oracle across the current six-example real-AIR suite.
- The Native benchmark transaction records proof bytes, backend identity, timing, and verification.
- Metal shader families have been substantially decomposed behind stable export names.
- Deterministic core and witness AOT tooling and authenticated session admission exist.
- The source ratchet is green with no new findings.
- Benchmark history and delta tooling preserve previous measurements instead of overwriting them.

These are starting assets, not automatic completion. They must be regenerated from the final clean
tree under the exact contracts below.

### 4.2 Structural Debt Is Explicit

The expanded source checker inventories:

- 531 source files under `src/` across Zig, Metal, Objective-C, and C headers;
- root `build.zig` plus one focused build-support module;
- 97 maintained Python files under `scripts/`; and
- 34 Rust-tool source files under repository-owned `tools/` crates.

Baseline v3 currently contains 20 owned findings under the deferred track:

| Track | Count | Required closure |
| --- | ---: | --- |
| `active_native_backend` | 0 | Keep empty as a blocking optimization gate |
| `deferred_todo` | 20 | Preserve as explicit owned TODOs; no new finding or line-cap growth |

Every exception has an owner, reason, plan, next extraction, and a no-growth line cap where
applicable. The default global check rejects new, stale, or grown debt in either track. The strict
active-track check rejects every remaining Native/backend entry. Optimization unlock requires the
active track to be empty, not the deletion or hurried restructuring of deferred frontend work.

### 4.3 Resolved Active Owners

| Owner | Delivered shape |
| --- | --- |
| `src/backends/metal/runtime.m` | 661-line ABI facade over 15 responsibility-owned implementation includes; compiled object remained byte-identical |
| `src/backends/metal/runtime.zig` | 212-line facade over focused protocol-stage modules; all 104 public signatures preserved |
| `src/backends/metal/kernels.metal` | 824-line compatibility owner with decommitment shaders extracted; all 90 exports preserved in one library |
| `src/tests/metal/backend_test.zig` | 8-line test map over focused protocol-stage suites |
| `build.zig` | 433-line public graph with the complete Metal product graph in typed build support |
| benchmark, profiler, interop, delta, optimization comparison, and Native proof evidence | Thin command owners; heavy benchmark/profile/interop lanes delegate to responsibility packages whose workload catalogs are separate from execution/report controllers |
| `tools/stwo-interop-rs` and `tools/stwo-vector-gen` command roots | 29-line and 59-line roots over explicit schema, codec, proof, and generator modules |

All remaining baseline owners belong to `deferred_todo`. Their existing design documents remain the
future extraction plans, but no Cairo, SN PIE, streaming, RISC-V, or SNIP-36 source work is required
by this goal.

## 5. Target Repository Architecture

```text
src/
|-- stwo.zig                         public library map
|-- std_shims_freestanding.zig       intentional alternate build root
|-- core/                            backend-independent protocol and verifier
|-- backend/                         capability contracts only
|-- prover/                          backend-generic proving algorithms
|-- backends/
|   |-- cpu_scalar/                  scalar implementation and explicit SIMD kernels
|   |-- cuda/                        preserved boundary; implementation out of scope
|   `-- metal/                       runtime, shader families, ABI, AOT, resources
|-- frontends/
|   |-- cairo/                       deferred TODO: Cairo statement/AIR/witness ownership
|   `-- riscv/                       deferred TODO: RISC-V statement/AIR ownership
|-- integrations/
|   `-- cairo_metal/                 deferred TODO: Cairo-to-Metal binding boundary
|-- interop/                         formats and Rust-oracle boundaries
|-- examples/                        Native Stwo AIR examples
|-- bench/                           benchmark execution primitives
|-- tools/                           thin executable/service adapters
`-- tests/                           cross-module integration tests by domain
```

### 5.1 Dependency Direction

```text
core <- backend capability contracts <- prover
  ^                                      ^
  |                                      |
frontends -------------------------------+

backends implement capabilities
integrations/cairo_metal -> frontends/cairo + backends/metal
interop/tests/tools -> public lower-layer APIs
```

- `core` knows no concrete backend, frontend, CLI, benchmark, or fixture.
- `prover` depends on capability contracts, not Metal handles or CPU policy.
- frontends own statement and AIR meaning, never device selection or cache policy.
- concrete backends import no Cairo, RISC-V, or example semantics.
- only `integrations/cairo_metal` joins Cairo meaning to Metal execution.
- tools/tests compose lower layers; lower layers never import tools/tests back.
- diagnostics are optional sinks and never alter proof behavior.
- CUDA obeys the same dependency rule even while its implementation is out of scope.

The checker currently resolves relative Zig imports and repository Metal includes. Phase 1 extends
mechanical enforcement to every robustly parseable edge needed to make these claims true; the docs
must state any remaining parser limitation explicitly.

### 5.2 Module Shape and Progressive Disclosure

- Reusable package directories expose stable concepts through `mod.zig` or the public `stwo.zig`
  map; leaf data/test directories do not get artificial forwarding modules.
- Executable roots parse arguments, construct dependencies, call one service, and exit.
- Approximately 500 lines is the normal review target; 850 is the soft ceiling for a genuinely
  cohesive protocol/HPC module.
- The formal Native evidence command-root set is explicit in
  `scripts/source_conformance_lib/policy.py`: archive, benchmark, profiler, interop, AOT, delta,
  comparison, and Native proof-matrix commands. The source gate caps those roots independently from
  their implementation modules.
- Every active `scripts/*_lib/controller.py` is discovered mechanically, must have a stable command
  facade, and remains subject to the 850-line cohesive-module ceiling. A deep controller is not
  described as a thin entry point merely because both are below a line limit.
- Shared executable command construction lives below controllers in `scripts/interop_cli_lib/`;
  the historical `scripts/interop_cli_command.py` path is a compatibility facade, not an
  implementation dependency.
- A legacy file may only shrink until its exception is removed.
- Extracted modules hide representation, policy, caching, concurrency, or ABI complexity; shallow
  one-function wrappers do not count as decomposition.
- Runtime kernels may remain fused even though their source ownership is split.
- Generated sources declare generator, schema, inputs, and reproducible command.
- `utils`, `helpers`, `common`, and `misc` cannot become ownership substitutes.

## 6. Backend Conformance

### 6.1 Capability Names Are Exact

- `cpu_native`: the Zig CPU proof backend, including compiler-emitted and explicit SIMD hot paths.
- `metal_hybrid`: Metal executes declared stages while every CPU fallback stage/count is reported.
- `metal_resident`: reserved for a measured capability whose declared proving stages remain on the
  device and whose backend-fallback counters are zero.
- `rust_simd_oracle`: the pinned Rust Stwo SIMD correctness/comparison lane.

Do not call `cpu_native` a separate Zig SIMD backend until a distinct capability type and execution
contract exist. Do not call a hybrid path resident. Selecting one capability and executing another
is an error even if the proof verifies.

`metal_hybrid` may pass Native correctness and enter the optimization program under that exact
label. Zero fallback is not an optimization-readiness prerequisite because removing measured
fallbacks is legitimate performance work. Silent, unreported, or statement-dependent fallback is
always forbidden.

### 6.2 CPU/SIMD Contract

- scalar field/protocol semantics remain the correctness reference inside Zig;
- explicit SIMD kernels expose preconditions for alignment, width, tails, aliasing, and scratch;
- dispatch policy is centralized and observable, not scattered through AIR/example code;
- scalar/SIMD differential tests cover boundary lengths, unaligned inputs, tails, and fixed seeds;
- hot code avoids hidden allocation, accidental copies, and allocator-policy leakage;
- benchmark reports distinguish algorithmic work, threads, explicit SIMD, compiler vectorization,
  and total request time.

### 6.3 Metal Build and ABI Contract

1. Domain shader sources compile and link into one deterministic core metallib.
2. One generated manifest binds source digests, compiler/profile, target, exports, argument ABI,
   function constants, and final library digest.
3. Objective-C/C headers and Zig declarations have one owner and compile-time layout checks.
4. Development source-JIT and AOT reflect the same exports and produce exact outputs.
5. Release admission authenticates the metallib and manifest and rejects missing exports, ABI
   drift, mutable identity drift, and implicit source-JIT fallback.
6. Library, PSO, and binary-archive caches have typed content/device/compiler keys, byte/count
   bounds, explicit invalidation, and tested teardown.
7. Runtime/device/queue/library/PSO setup is reusable and never hidden inside proof-only timing.

This active gate concerns only the shared/Native core metallib. Cairo witness-metallib source,
tooling, production admission, and decomposition remain deferred TODO work protected by the global
no-growth ratchet.

### 6.4 Runtime and Resource Contract

- resource ownership is explicit across allocation, command encoding, submission, completion,
  recovery, cache eviction, and shutdown;
- prepared state is keyed by statement/protocol/geometry/library/device identity, not just row count;
- command-buffer boundaries and host/device synchronization are named and measured;
- no use-after-free, cross-request alias, unbounded cache, handle/thread leak, or hidden global
  mutation is accepted;
- errors poison only affected prepared state and never publish partial artifacts;
- backend telemetry proves that a selected Metal path dispatched real device work and reports every
  remaining host stage and fallback.

## 7. Native Stwo Correctness Lock

For all six registered Native AIR examples - Wide Fibonacci, XOR, Plonk, state machine, Blake, and
Poseidon - run representative narrow, dynamic, parameter-wide, and very-wide geometries through the
same backend-neutral proving transaction.

Required evidence:

1. CPU and selected Metal capability consume the same statement and protocol parameters.
2. Every emitted proof verifies in Zig.
3. Zig-generated proofs are accepted by the pinned Rust Stwo verifier.
4. Rust-generated proofs are accepted by Zig under the same schema/configuration.
5. Deterministic proofs are byte-identical across repeated runs and backends where the contract
   requires; otherwise canonical interchange is documented and tested.
6. Statement, proof, metadata, transcript, Merkle, opening, FRI, PoW, and parameter mutations fail.
7. Reports bind the exact proof bytes actually gated or timed, not a regenerated proxy.
8. Metal reports name `metal_hybrid` or `metal_resident`, prove device dispatch, and expose fallback
   counters and host-stage time.

Exit gate: the strict Native suite passes from a clean ReleaseFast checkout in both directions
against the Native pin, with no unresolved divergence and no backend-identity ambiguity.

## 8. Test, CI, and Evidence Architecture

### 8.1 Test Layers

1. pure unit/law tests for fields, schemas, capability plans, cache keys, and state machines;
2. deterministic differential vectors against pinned Rust;
3. scalar/SIMD and CPU/Metal backend differential tests;
4. focused ABI, shader-export, resource, dispatch, failure, and lifecycle integration tests;
5. complete six-example Native proof/interchange tests;
6. bounded macOS Metal compile/link and device correctness tests; and
7. benchmarks/profiles, which never substitute for correctness.

Bug fixes begin with a regression. Random tests use fixed reported seeds. Failure tests cover
malformed lengths, overflow, allocation failure where injectable, ABI mismatch, cache poisoning,
mutation, wrong-backend selection, and partial initialization.

### 8.2 Evidence Contract

Every conformance or performance artifact binds:

- clean repository commit and exact build mode;
- Zig, Rust, Xcode/Metal compiler, OS, and device versions;
- Native oracle revision and applicable protocol/schema;
- input, statement, executable, metallib, manifest, proof, and report digests;
- backend capability, threads/SIMD mode, device dispatch, host stages, and fallback counters;
- warmup/sample order, seeds, environment, and command;
- local and Rust verifier results plus negative-case summary; and
- raw samples and an immutable delta against a named predecessor.

New evidence never overwrites historical raw data. A report with a dirty tree, missing proof
digest, unknown backend identity, failed verification, or ambiguous lifecycle is diagnostic only.

### 8.3 Local and Hosted Gates

Fast pre-commit:

- whitespace and formatting;
- source/dependency/generated-file conformance;
- focused checker tests.

Pre-push and hosted CI:

- full Python tooling tests;
- Zig unit, deep, vector, API parity, upstream-surface, and strict gates;
- Native Rust interoperability in both directions;
- source conformance with zero baseline growth across all tracks and zero active-track findings;
- deterministic Metal generation, compile/link, manifest, ABI, and export checks on macOS;
- documentation links and generated-artifact reproducibility.

Heavy performance and profiler jobs run on labelled Apple hardware with controlled concurrency.
Generic CI still compiles host state machines and schemas. A skipped hardware gate is never
reported as passing.

## 9. Performance Readiness

The unlock baseline must exercise the broad Native suite, not one Fibonacci shape. It includes:

- CPU and Metal lanes for all six examples;
- narrow, dynamic, parameter-wide, and very-wide representatives;
- cold process, backend setup, first proof, warm proof, proof-only, verification, and total request
  timing;
- committed cells/bytes, trace rows, workload-native units, proof bytes, and total wall time;
- device dispatch, command-buffer/wait counts, CPU fallback, peak RSS, Metal allocation, cache hits,
  and cache resident bytes;
- alternating lane order, bounded warmups/samples, thermal/load notes, and verified exact artifacts;
- profiler baselines for CPU hot paths and Metal kernel/command/synchronization hot paths; and
- immutable raw reports plus generated delta/history artifacts.

The baseline does not impose a speed target. It establishes the cost model and measurement system
from which speed work can be judged. Rust-relative targets in `conformance/contract.md` remain later
release gates, not circular prerequisites for beginning optimization.

After unlock, each performance increment must:

1. state a profile-backed hypothesis and affected cost center;
2. preserve exact Native Zig/Rust acceptance and backend identity;
3. measure at least one narrow and one wide case, then run the broad suite before acceptance;
4. report cold, warm, proof-only, request, memory, and fallback deltas;
5. avoid program-specific branches or benchmark-only constants; and
6. keep or improve repository boundaries rather than hiding complexity in a monolith.

## 10. Delivery Sequence

Each increment is a focused commit with its tests and evidence.

### Phase 0: Adopt the Narrowed Goal

- make repository/backend readiness the active optimization lock;
- mark all Cairo, SN PIE, streaming, RISC-V, and SNIP-36 implementation and structural delivery as
  deferred TODO work;
- retain existing Cairo evidence without treating it as an unlock prerequisite.

Exit: documents and formal goal describe one unambiguous scope.

### Phase 1: Empty the Active Native/Backend Track

- decompose the 10 active build, Metal runtime/shader, Metal test, benchmark-tooling, and Native
  Rust-tool owners;
- expand dependency checks where parsing is reliable;
- remove each active-track entry in the same focused commit as its debt;
- leave every deferred-track entry as an explicit owned TODO under the global no-growth ratchet.

Exit: the strict `active_native_backend` check reports zero findings and the full inventory reports
no new, stale, or grown debt.

### Phase 2: Close Backend Build and Ownership

- finish shared/Native Metal shader and ABI decomposition;
- verify deterministic linked core metallib generation and release admission;
- close CPU/SIMD dispatch ownership and differential coverage;
- validate cache, prepared-state, resource, failure, and teardown contracts.

Exit: CPU and Metal capabilities build, admit, execute, identify themselves, and shut down under
their declared contracts without structural exceptions.

### Phase 3: Revalidate Native Correctness

- run the complete six-example CPU/Metal suite;
- run bidirectional Rust interchange and negative cases;
- bind the exact accepted artifacts and backend telemetry into immutable receipts.

Exit: Native CPU and Metal are exact, reproducible foundations for performance work.

### Phase 4: Freeze the Optimization Baseline

- run the broad ReleaseFast benchmark suite;
- collect bounded CPU and Metal profiles;
- record all lifecycle, memory, command, cache, backend, proof, and verifier evidence;
- commit raw reports and deltas against the previous broad baseline.

Exit: a general performance change can be evaluated without reopening correctness, backend
identity, setup attribution, or repository ownership.

## 11. Optimization Unlock Checklist

- [x] The Native and Cairo Rust authorities are separated in one checked pin ledger.
- [x] Source conformance inventories `src`, build ownership, maintained Python, and Rust tools with
      owned no-growth exception metadata.
- [x] The `active_native_backend` source track is empty; the global inventory has no new, stale, or
      grown findings.
- [x] No manually maintained source in the active Native/backend scope exceeds the repository
      ceiling without a checked generated-file exemption.
- [x] The active Native/backend target tree and statically resolvable Zig, Metal, Python, build,
      Cargo, and Rust dependency direction are mechanically true.
- [x] Active build owners, Native command/test roots, and Native Rust command roots are thin; every
      formal Native evidence executable root is explicit and independently capped; complex
      benchmark/profile/interop roots are 17-line facades over compartmentalized controllers that
      remain mechanically capped at the repository's 850-line soft ceiling.
- [x] Metal shader families and runtime responsibilities are compartmentalized behind stable ABI.
- [x] The deterministic shared/Native core metallib passes manifest, export, ABI, AOT/JIT parity,
      authentication, cache, and release-admission gates.
- [x] CPU scalar/SIMD dispatch has exact capability ownership and differential tests.
- [x] CPU and selected Metal capability pass the complete six-example Native suite in Zig.
- [x] Zig-to-Rust and Rust-to-Zig Native proof interchange and the negative matrix pass.
- [x] Metal evidence proves device work and reports an exact `metal_hybrid` or `metal_resident`
      identity with all host stages and fallback counters.
- [x] Resource, cache, failure, teardown, and repeated-request tests show bounded ownership.
- [x] Local hooks and hosted CI invoke the same checked-in gate definitions.
- [x] A clean broad Native CPU/Metal benchmark and profiler baseline, raw samples, and delta history
      are committed.
- [x] The working tree is clean and all generated build/evidence artifacts are reproducible.

Local acceptance is bound to implementation revision `44a81457`:

- the 12-row matrix report is
  `vectors/reports/benchmark_history/runs/2026-07-18-004844-matrix-v5-44a81457/report.json`
  (SHA-256 `3e3cf347fe958b822558e7c614b5f11317187f321d412fbd4a834d551b81d78b`; relocated by the
  history layout-v2 migration, bytes unchanged);
  its raw 72-file tree is bundle
  `8904754e1be42115f1c14ab86c4f41c646b26a37ce52a1782b58f4c6f7a4fea5`, and its comparable
  immutable delta is `935452a7f710c885cff681fa6f374c23e9136d1df179adbfa13412491e02ecbd`;
- the six-workload profile manifest is
  `vectors/reports/native_profile_baseline_44a81457/manifest.json`, SHA-256
  `c22fcae00416385a8ca3d5b0535c4650bb3d0c1e074de5103f65eed5b77c5d32`;
- the bidirectional report is `vectors/reports/native_e2e_interop_44a81457.json`, SHA-256
  `b15dd288b2f902604078711fe8d8d0164c906b9244f6ecb88c9b3aef46fe8b72`, and its 216-artifact
  receipt is `c4f548c05829d36f4925763d5387e6711f06511c19acd2334d71c9d3460f5338`; and
- the protected performance extraction playbook remains byte-identical at SHA-256
  `6fe794bce344b9615a10030ef4cd72c068af8865989ecd384a1c7d75cc34c449`.

Final hosted and device acceptance is bound to implementation revision
`e8ec9c043c4ff87b1f1696015f939dc7321dce78`:

- annotated tag `aot-evidence-e8ec9c04` triggered
  [workflow run `29627343666`](https://github.com/teddyjfpender/stwo-zig/actions/runs/29627343666);
  the `Metal AOT reproducible build` job `88034235188` and `Release gate` job `88034235190`
  both passed at that exact commit;
- the hosted release job ran the same `python3 scripts/ci.py` entry point as
  `.githooks/pre-push`, passed all 383 maintained Python tests, reported zero active Native source
  findings, passed all 616 Zig tests, then passed the interop, benchmark-smoke, and profile-smoke
  stages; the strict workflow-dispatch lane remains a later release-signoff option rather than an
  optimization-unlock prerequisite;
- hosted interop artifact `8424440768`, digest
  `5d5e71ff2c24c40e73a4f77ef84585f6dbf6e24611a92b7ca1cb398d4a0ba03d`, records 12/12
  bidirectional proof exchanges and 204/204 negative cases across all six Native examples; its
  216-artifact receipt is `644d003224593b525d1241b0f06431b2b27b415da30e88d35969bc688b87225f`;
- hosted Metal artifact `8424302732`, digest
  `bda5ee45474317e5451e09915a7b495e4df652012ae83f0c19980ed682f62b3b`, contains two
  independently compiled, byte-identical five-file bundles plus its build receipt and checksum;
- build receipt `fe87513de81d32b156b5e04895073d63d68b3d9ddf204e722e8f8664ee7b7939`
  binds ReleaseSafe, Xcode 15.4, SDK 14.5, Metal 3.1 safe math, warnings-as-errors, core shader ABI
  2, 78 unique exports, 78 ordered ABI entries, and no function constants; both bundles retain the
  exact metallib digest `900ee9a69412e6d11da7e473c6840329a329087a68375d5f6396905acf612b50`;
- device receipt `08a23fe3d47b3e96b31984782ad782d4bdd736ba3c377a559cd24d8002657d57`
  binds the hosted parent receipt and exact commit, reprobes both bundles on an Apple M5 Max, and
  passes all ten device checks, including authenticated admission, exact export/function-constant
  identity, and AOT/JIT transcript-output parity; the remaining kernels are authenticated by
  manifest ABI, export, and Metal function-type checks rather than overstated as dispatched parity;
  and
- the durable 14-file chain is stored under
  `vectors/reports/metal_core_aot_history/08a23fe3d47b3e96b31984782ad782d4bdd736ba3c377a559cd24d8002657d57/`.

The accepted implementation tag is intentionally the authority for executable acceptance. This
subsequent preservation commit adds only its immutable generated artifacts and this status record,
so it does not create a circular requirement for a receipt that authenticates itself. Focused
receipt validation, source conformance, checksums, and a clean final tree close the preservation
step.

The profiler baseline is complete for optimization admission. One non-blocking granularity TODO is
explicit: streaming CPU commitment leaf hashing occurs in the parent `main_trace_commit` timer,
while batch preparation and tree finalization have child stages. A future accumulated-stage scope
should coalesce discontiguous leaf hashing and finalization without changing proof semantics.

Every optimization-unlock item is now checked. Deferred Cairo, SN PIE, streaming, RISC-V, and
SNIP-36 semantic or structural items remain explicit TODOs and cannot be reintroduced implicitly
through a status report.

## 12. Definition of Done

A reviewer can start from a clean checkout and establish without private knowledge:

1. where every active shared protocol, backend, interop, build, performance-tool, and test
   responsibility lives;
2. that source size, generated-file policy, dependency direction, and exception ownership are
   mechanically enforced with an empty active Native/backend track and a no-growth deferred track;
3. that CPU scalar/SIMD and Metal capabilities are explicit and cannot silently select another
   execution path;
4. that the shared/Native Metal library and ABI are deterministic, authenticated, reusable, and
   fail closed in release admission;
5. that all six Native examples produce proofs accepted by Zig and the pinned Rust Stwo oracle in
   both interchange directions;
6. that caches, resources, commands, failures, and shutdown have bounded, tested lifecycles;
7. that every benchmark number names its workload, lifecycle, backend, proof, verifier, memory, and
   fallback state;
8. that broad raw benchmark/profile evidence and deltas can detect general regressions; and
9. that the next optimization can be reviewed as a performance change rather than a combined
   correctness, architecture, and benchmarking experiment.

With this goal complete,
[`2026-07-17-backend-performance-program.md`](2026-07-17-backend-performance-program.md) becomes the
active execution plan. The Rust oracle, source checker, backend identity, broad suite, and evidence
contracts remain permanently blocking while performance is driven upward.
