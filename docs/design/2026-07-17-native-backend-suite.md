# Native Backend Proof Suite

Status: complete; six-example real-AIR CPU/Metal correctness matrix accepted

Date: 2026-07-17

## Objective

Run every native Stwo example through one backend-neutral proving transaction and
one fail-closed CPU/Metal benchmark matrix:

- `wide_fibonacci`
- `xor`
- `plonk`
- `state_machine`
- `blake`
- `poseidon`

The suite measures complete proof requests, including input construction, proving,
proof encoding, verification, and request latency. It must preserve exact CPU/Metal
proof parity and use the pinned Rust Stwo implementation as the final correctness
oracle. RISC-V is outside this program.

This is an architectural change, not six copies of the wide Fibonacci runner.

## Accepted scope

Wide Fibonacci, XOR, Plonk, state machine, Blake, and Poseidon expose the shared
`ProverEngine`, reusable-session, prepared-input, and stage-recording transaction.
The formal report-v4 CPU/Metal matrix dispatches all six examples at bounded small
and large geometries through that one transaction.

The latest [committed broad report](../native-proof-backend-benchmark-2026-07-17.md)
contains 12 real-AIR rows across all six registered examples. Every lane produced
ten verified byte-identical measured proofs, every CPU/Metal pair has identical
canonical bytes, and the pinned Rust oracle accepted every artifact. Nine rows
satisfy the ordered timing gate; three remain timing-diagnostic. Timing drift does
not change the accepted exact-proof result.

The bidirectional interoperability and prove-checkpoint tools exercise both Rust
and Zig proof origins, both verifiers, canonical wire equality, and proof,
statement, and mode tampering for all six examples. They pin upstream commit
`a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`; those formats and fixtures remain the
single Native proof contract.

## Repository shape

The target ownership boundaries are:

```text
src/examples/
  common/
    prover_transaction.zig  # Prepared-tree ownership and generic transaction
  <example>.zig             # Public compatibility API and verifier
  <example>/
    input.zig               # Trace preparation and owned prepared input
    proving.zig             # Spec context and component construction, when split

src/bench/native_proof/
  config.zig                # Runtime tagged workload request
  examples.zig              # Closed six-example dispatch registry
  runner.zig                # One generic timed request loop
  report.zig                # Exact versioned report schema

scripts/native_proof_matrix_lib/
  model.py                   # Tagged workload model and bounds
  artifacts.py               # Commands, captures, and oracle invocation
  contract.py                # Exact fail-closed validation
  controller.py              # Alternating CPU/Metal orchestration
```

Files should be split when progressive disclosure would otherwise push them beyond
the repository's source-file guidance. The common transaction owns lifecycle and
ordering only. Trace mathematics and transcript policy remain private to each
example.

## Shared transaction contract

### Prepared trace

Every current example commits exactly two trace trees before the composition tree:
preprocessed tree index 0 and main tree index 1. An empty preprocessed tree remains
an explicit committed tree because the prover relies on that index.

The common module should expose the equivalent of:

```zig
pub const OwnedColumns = struct {
    columns: ?[]ColumnEvaluation,

    pub fn take(self: *OwnedColumns) []ColumnEvaluation;
    pub fn deinit(self: *OwnedColumns, allocator: Allocator) void;
};

pub const PreparedTrace = struct {
    preprocessed: OwnedColumns,
    main: OwnedColumns,
    max_column_log: u32,
    committed_columns: u64,
    committed_cells: u64,

    pub fn deinit(self: *PreparedTrace, allocator: Allocator) void;
};

pub fn PreparedInput(comptime Request: type) type {
    return struct {
        request: Request,
        trace: PreparedTrace,
        pub fn deinit(self: *@This(), allocator: Allocator) void;
    };
}
```

`committed_cells` is the checked sum of every preprocessed and main column length.
It excludes the composition tree and FRI layers. It is computed from actual
prepared columns, then checked against the workload model's derived value.

### Example spec

Each example provides a compile-time spec with this semantic surface:

```zig
pub const Request: type;
pub const Statement: type;
pub const PreparedInput = common.PreparedInput(Request);
pub const ProverContext: type;
pub const max_components: usize;

pub fn validateRequest(request: Request) !void;
pub fn prepareInput(allocator: Allocator, request: Request) !PreparedInput;
pub fn compositionLog(request: Request) !u32;

pub fn initProverContext(
    out: *ProverContext,
    channel: anytype,
    request: Request,
) !void;

pub fn statement(context: *const ProverContext) Statement;
pub fn proverComponents(
    context: *const ProverContext,
    out: []ComponentProver,
) ![]const ComponentProver;
```

`initProverContext` initializes its destination in place. Component adapters borrow
the concrete component, so returning a self-referential context by value is not
allowed. The context remains alive until `Engine.prove` returns.

Static examples mix their statement and initialize their component in this hook.
State machine uses the same hook after both commitments to:

1. Mix `Statement0`.
2. Draw lookup `Elements` from the channel.
3. Derive the public input and claimed sums.
4. Mix the public input and `Statement1`.
5. Initialize the component from the derived statement.

No common code may know these state-machine transcript details.

### Transaction entrypoint

The common entrypoint is conceptually:

```zig
pub fn provePreparedEx(
    comptime Engine: type,
    comptime Spec: type,
    comptime use_session: bool,
    session: if (use_session) *const Engine.Session else void,
    allocator: Allocator,
    pcs_config: PcsConfig,
    prepared: Spec.PreparedInput,
    options: ProveOptions,
) !Output(Spec.Statement, Engine.ExtendedProof);
```

It performs exactly this sequence:

1. Validate the prepared request and required circle log.
2. Initialize `Engine.Channel` and mix the PCS configuration.
3. Initialize a scheme normally or borrow the session's immutable twiddle tower.
4. Move and commit the preprocessed columns.
5. Move and commit the main columns.
6. Initialize `Spec.ProverContext` in place and obtain component views.
7. Transfer the scheme once to `Engine.prove`.
8. Return the context statement and extended proof.

Stable stage scopes cover channel/scheme initialization, each trace-tree commit,
example transcript finalization, and core prove. PCS child stages retain their
existing identifiers.

### Ownership laws

These laws are mandatory and allocation-failure tested:

- A prepared input is consumed on every success or error from a prepared proving
  entrypoint.
- `OwnedColumns.take` clears the source before `Engine.commit` is called.
- `Engine.commit` consumes its column slice on both success and error.
- Unmoved trees are released by `PreparedInput.deinit`; moved trees are never freed
  by it.
- The transaction owns the scheme until immediately before `Engine.prove`.
- `Engine.prove` consumes the scheme on both success and error.
- A borrowed session outlives every scheme made from it. A request never owns or
  mutates the session tower.
- The channel and context live at stable addresses through the proof call.
- The recorder is borrowed and is never stored beyond the request.
- Sequential session reuse is promised. Concurrent reuse is not promised until it
  has a separate race and backend-state audit.

Compatibility `prove` and `proveEx` wrappers prepare input and call this same path.
There must not be a legacy direct-PCS implementation beside the engine path.

### Session geometry

The required session circle log is checked before ownership transfer:

```text
max(
  prepared.max_column_log + fri.log_blowup_factor,
  Spec.compositionLog(request),
  pcs_config.lifting_log_size or 0,
)
```

All six current components use `trace_log_rows + 1` for composition. Arithmetic is
checked; overflow or an undersized session fails before a tree is moved.

## Per-example shape and numerator

The semantic numerator is explicit. Trace-row MHz remains available for geometry,
and committed Mcells/s remains the common bandwidth-normalized measure.

| Example | Preprocessed columns | Main columns | Trace rows | Native unit | Native units | Committed cells |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| Wide Fibonacci | 0 | `sequence_len` | `2^log_n_rows` | `trace_rows` | `rows` | `rows * sequence_len` |
| XOR | 2 | 1 | `2^log_size` | `xor_rows` | `rows` | `3 * rows` |
| Plonk | 4 | 4 | `2^log_n_rows` | `plonk_rows` | `rows` | `8 * rows` |
| State machine | 1 | 2 | `2^log_n_rows` | `state_transitions` | `rows` | `3 * rows` |
| Blake | 0 | `96 * n_rounds` | `2^log_n_rows` | `blake_round_instances` | `rows * n_rounds` | `96 * native_units` |
| Poseidon | 0 | 1264 | `2^(log_n_instances - 3)` | `poseidon_instances` | `2^log_n_instances` | `1264 * rows`, or `158 * native_units` |

All products use checked `u64` arithmetic. `native_mhz` is
`native_units / prove_seconds / 1e6`; request-native MHz uses total request time.
Neither Blake nor Poseidon may be presented as instance throughput using raw trace
rows.

## Runner and workload registry

The CPU and Metal executables retain one shared `main(Engine, backend)`. Runtime
configuration selects a closed `ExampleWorkload` union, then a single switch calls:

```zig
executeExample(Engine, backend, Spec, request)
```

Session construction, warmups, samples, telemetry snapshots, encoding, verification,
statistics, artifact binding, and reporting stay in that one generic body.

The native binary accepts `--example` plus example-specific flags. The Python
controller accepts canonical tagged rows such as:

```text
--workload wide_fibonacci:log_n_rows=12,sequence_len=16
--workload xor:log_size=14,log_step=2,offset=3
--workload plonk:log_n_rows=14
--workload state_machine:log_n_rows=14,initial_0=9,initial_1=3
--workload blake:log_n_rows=10,n_rounds=10
--workload poseidon:log_n_instances=13
```

The controller converts a validated tagged row to explicit native-binary flags.
Legacy `LOG_ROWS:SEQUENCE_LEN` input may temporarily map to wide Fibonacci, but it
is not written into new summaries.

The example registry also owns:

- canonical parameter ordering and descriptor bytes;
- statement-to-artifact conversion;
- semantic numerator derivation;
- trace and cell geometry;
- the verifier dispatch;
- bounded CLI validation.

Move the closed example and statement unions currently private to the interop CLI
into a shared registry or artifact module. Artifact construction must have one
implementation used by the interop CLI and native runner.

## Report schema

This expansion requires report schema version 3. Exact object keys remain enforced.

`workload` contains:

```text
name
descriptor_sha256
parameters                 # exact tagged parameter object
trace_log_rows
trace_rows
committed_trees            # always 2 for this suite
committed_columns
committed_trace_cells
native_unit
native_units
```

Every timed sample contains:

```text
input_seconds
prove_seconds
proof_encode_seconds
verify_seconds
request_seconds
native_mhz
request_native_mhz
trace_row_mhz
request_trace_row_mhz
committed_mcells_per_second
```

The throughput object exposes headline or diagnostic summaries for native MHz,
trace-row MHz, and committed Mcells/s. The ambiguous `row_mhz` name is removed in
version 3. Complete proving and request time remain first-class results.

The descriptor is SHA-256 over the canonical example name, ordered parameters, and
all protocol fields. Zig and Python independently recompute it. A mismatch is a
hard failure.

The session object retains exact configuration, budget, retained twiddle bytes, and
tower build count. Its maximum circle log must cover the workload formula above.

## Matrix and fail-closed behavior

Rows run sequentially with alternating lane order. The controller refuses inherited
profiler variables for headline runs and verifies that benchmark binaries do not
change during the matrix.

A row fails unless:

- every warmup and sample completes;
- every generated proof verifies in Zig;
- every sample within a lane has identical canonical bytes;
- CPU and Metal canonical proof bytes are identical;
- the artifact statement and PCS configuration exactly match the request;
- report rates exactly match the declared numerators and measured seconds;
- descriptor, trace geometry, column count, and cell count match independently
  derived values;
- ReleaseFast, clean complete provenance, thread parallelism, and functional
  protocol requirements hold;
- every Metal request records at least one Metal dispatch and internally consistent
  telemetry;
- the session builds one tower, stays within its byte budget, and covers the
  workload log;
- the pinned Rust oracle accepts the canonical artifact.

CPU fallbacks in a Metal request remain visible. They do not become invisible merely
because another stage dispatched Metal work.

## Pinned Rust final oracle

The matrix accepts `--rust-oracle-bin`. The binary is required for formal evidence.
Its source commit is fixed to `a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`
and its toolchain remains `nightly-2025-07-14` until deliberately updated.
Formal execution additionally requires the exact verifier binary SHA-256
`395c5549f383052e4e37ac29ae77923a5422f51cb310cfc7f9ef1281cd03819a`.
This binary includes the fail-closed outer-versus-embedded PCS configuration
check introduced by `518c77b2`; it is reproducibly built from the pinned
toolchain, lockfile, upstream Stwo revision, and repository-owned oracle wrapper.
This identity includes the real Wide Fibonacci recurrence AIR introduced by
`e2658e0`; reports bound to the earlier `cbe4d3f1...` synthetic-AIR oracle are
retained as historical geometry evidence but are not performance-comparable.
The preceding `4d223c37...` real-AIR binary remains historical evidence but is
not accepted for new formal runs because it predates that boundary check.
An arbitrary executable that exits successfully is rejected before invocation, and
both the binary and canonical artifact are rehashed after verification.

After CPU/Metal byte parity is established, the controller verifies the canonical
row artifact with Rust. The summary records:

- pinned upstream commit;
- Rust toolchain;
- oracle binary path and SHA-256;
- artifact path and SHA-256;
- invocation result and elapsed time.

Missing oracle, commit mismatch, nonzero exit, timeout, or malformed output fails
the row. CPU/Metal equality permits one canonical verification per row; both lane
artifacts still undergo full local schema and digest validation.

Existing `scripts/prove_checkpoints.py` base and blowup-two cases remain the
bidirectional fixture gate. For each migrated example, add a Zig smoke regression
showing exact bytes across:

1. The pre-refactor compatibility proof fixture.
2. The non-session engine path.
3. Two sequential proofs from one session.

The Rust verifier, rather than a permanently blessed Zig digest, is the final
correctness authority.

## Bounds

Formal runs enforce these initial limits:

- at most 12 matrix rows;
- `trace_log_rows` in `[1, 22]`;
- at most `2^25` committed trace cells per row;
- at most `2^30` committed trace cells across all warmup and sample requests;
- at most 10 warmups and 21 measured samples per lane;
- at least 10 warmups for headline evidence; shorter runs are correctness-only;
- at most 21 profiled samples, with 5 preferred for wide-column diagnostics;
- at most 300 seconds cooldown and 3600 seconds per lane request;
- a 256 MiB host twiddle budget unless a separately reviewed profile changes it;
- checked column counts, native units, byte counts, and total-work arithmetic.

Example validation remains stricter: nonzero Blake rounds, Poseidon instances at
least eight, valid XOR step/offset geometry, and valid state-machine field elements.
Bounds are applied before process launch and revalidated in Zig.

## Profiling program

Headline and profiled evidence are never mixed. Start with bounded representative
rows that exercise distinct architecture rather than every size permutation:

| Structural class | Initial profile row | Purpose |
| --- | --- | --- |
| Narrow, two-tree | XOR `log_size=14, log_step=2, offset=3` | Preprocessed/main ownership and small-tree overhead |
| Moderate, two-tree | Plonk `log_n_rows=14` | Balanced interpolation, quotient, and Merkle work |
| Dynamic transcript | State machine `log_n_rows=14` | Post-commit challenge and statement overhead |
| Parameter-wide | Blake `log_n_rows=10, n_rounds=10` | Streaming many columns, about 0.98M cells |
| Very wide | Poseidon `log_n_instances=13` | 1264 columns, about 1.29M cells |
| Existing control | Wide Fibonacci `log_n_rows=14, sequence_len=32` | Continuity with earlier profiles |

Use stage medians first, then Instruments/Metal System Trace and CPU sampling only
on stages with material share. Optimize shared quotient, transform, commitment,
FRI, allocation, and session paths before example-specific trace generation. A
change must be evaluated on at least one narrow and one wide row for both CPU and
Metal, with exact proof parity retained.

## Staged migration

1. **Common transaction.** Implement ownership types and spec contract. Move wide
   Fibonacci onto it with byte-identical compatibility and allocation-failure tests.
2. **XOR vertical slice.** Add prepared input, engine/session APIs, CPU compatibility
   tests, bounded Metal parity, and pinned Rust acceptance. XOR is small but exercises
   a nonempty preprocessed tree and main tree.
3. **Tagged matrix.** Introduce report v3, tagged Zig/Python workloads, exact
   numerator validation, shared artifact construction, and one XOR functional row.
   Make Rust oracle execution mandatory for formal mode.
4. **Plonk.** Migrate the second static two-tree example and add it to the matrix.
5. **State machine.** Validate the in-place dynamic transcript context and statement
   derivation contract.
6. **Blake and Poseidon.** Migrate the wide-column cases with cell bounds, streaming
   telemetry, and bounded profiler evidence.
7. **Suite closure.** Run all six examples in alternating CPU/Metal order, accept
   every canonical artifact in pinned Rust, and publish the first cross-suite profile.

Each step is a focused commit. Bulk conversion before the XOR vertical slice passes
all gates is explicitly rejected.

## Acceptance criteria

The design is complete when:

- no example proving wrapper directly names `CpuBackend` or initializes the PCS;
- all six examples expose prepared, engine, and session proving entrypoints;
- compatibility wrappers use the common transaction exclusively;
- allocation-failure tests prove the ownership laws;
- sequential session proofs build one tower and preserve exact bytes;
- one runner and one report path serve both backends and all examples;
- report v3 uses correct semantic and geometric numerators;
- the Python controller validates all schemas, rates, bounds, telemetry, and parity
  fail closed;
- every formal matrix artifact is accepted by pinned Rust Stwo;
- bounded profiles cover narrow, dynamic, parameter-wide, and very-wide shapes;
- clean unprofiled CPU/Metal results include total prove time, total request time,
  native MHz, trace-row MHz, and committed Mcells/s;
- no RISC-V code or benchmark is coupled to this suite.

For migration-only changes, an unchanged workload median regressing by more than 5%
in two clean alternating 21-sample A/B repetitions blocks acceptance unless the
regression is explained and explicitly approved. Correctness, oracle acceptance,
and fail-closed evidence are never traded for throughput.

## Accepted XOR vertical slice

Commit `ec288e7` moves XOR onto the same backend-neutral transaction as wide
Fibonacci. It owns its prepared preprocessed and main trees explicitly, exposes
engine and reusable-session entrypoints, checks the required twiddle circle log,
and keeps the XOR transcript and component construction inside the example spec.
Compatibility, prepared-engine, and two sequential session proofs are byte
identical. Allocation-failure and malformed-geometry tests cover the ownership
contract, and one reused session constructs exactly one twiddle tower.

The exact committed smoke artifact is 7,796 bytes with SHA-256
`0b5ca7fb7ceeb110f996dec508b939ac5eb4239526a5f244de21a25e93180504`.
It was generated from clean commit `ec288e7` for `log_size=5`, `log_step=2`, and
`offset=3`, then accepted by the pinned Rust Stwo oracle at
`a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`. The next suite stage is report
version 3 and one tagged runner/matrix path shared by wide Fibonacci and XOR.

## Accepted Tagged Matrix

Commit `47bc615` implements report schema 3 and aggregate matrix protocol 3. A
closed tagged workload registry dispatches Wide Fibonacci and XOR through one
generic prepared-input/session/prove/encode/verify loop on CPU or Metal. Zig and
Python independently derive and test canonical descriptor hashes, exact geometry,
workload-native units, trace-row units, and committed-cell numerators. Legacy Wide
Fibonacci CLI syntax remains a temporary compatibility surface.

The Python controller recomputes the sampling contract, evidence class, all eight
headline requirements, throughput summaries, request-phase enclosure, Metal
pipeline warmth, proof fingerprints, artifact statements, and CPU/Metal parity.
Formal mode requires the exact pinned Rust binary hash above. Atomic artifact
publication, locks, subprocess failures/timeouts/output bounds, telemetry
cardinality, dirty provenance, cold measured pipelines, artifact mutation, and
formal exit behavior have focused regression tests.

A clean detached ReleaseFast matrix at `0b2eb10` used the functional protocol, one
warmup, five samples per lane, alternating lane order, and a 0.25-second bounded
cooldown. Both rows satisfied the original report contract, but are now historical
correctness evidence because the accepted sustained contract requires ten warmups:

| Workload | CPU prove (ms) | CPU native MHz | CPU request (ms) | Metal prove (ms) | Metal native MHz | Metal request (ms) | Metal/CPU prove |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wide Fibonacci `log10x8` | 3.483625 | 0.293947 | 3.764916 | 6.083750 | 0.168317 | 6.243125 | 0.573x |
| XOR `log10/step2/off3` | 4.142583 | 0.247189 | 4.441167 | 8.024709 | 0.127606 | 8.220208 | 0.516x |

CPU and Metal emitted the same canonical artifact in every sample:

| Workload | Proof bytes | Canonical proof SHA-256 |
| --- | ---: | --- |
| Wide Fibonacci | 23,569 | `1beb388cda4e2941e5a65c11653d78de3116ae95a686538105312c29ff9f6f0c` |
| XOR | 23,505 | `574b4d698125fb6049e6c5f87293f5c755c4029b28cf2a6839d49af1f720831f` |

The pinned Rust Stwo oracle accepted both exact CPU/Metal-identical artifacts.
The CPU and Metal benchmark binary hashes were
`30f2e147cee56fdaa980dc5674ef1a10e11c7332e32eb3f83abb7e3097fa6648`
and `b12f77cc1faaaa046c1ade2fd627c505420732eea1c7f72f5066a58b8537170e`.
The matrix establishes a trustworthy complete-proof baseline, not a Metal win:
these bounded rows still favor CPU materially, so the next Metal work must target
measured complete-transaction residency and fallback boundaries.

The first complete-transaction Metal profile explains that gap. Wide and XOR spend
only 0.874 and 1.118 ms per proof in actual GPU execution, but 4.233 and 4.391 ms in
command waits. Each records 13 CPU small-Merkle fallbacks and no resident or streaming
Merkle commit; FRI quotient construction/commitment is the dominant stage. LDE is
already batched into one Wide command and two XOR commands. The next Metal gate is
therefore a controlled resident-small-tree crossover and producer-to-commit residency,
not speculative LDE or leaf-kernel work.

## Accepted Plonk and sustained baseline

Commit `1280ed3` moves Plonk onto the backend-neutral prepared-input and reusable-session
transaction. Its four preprocessed and four main columns are owned and consumed through the same
laws as Wide Fibonacci and XOR. Compatibility, prepared-engine, sequential-session, and extended
proof entrypoints retain exact proof bytes. Commit `77ec02a` adds tagged Plonk geometry, descriptor,
CLI dispatch, artifact construction, controller validation, and the ten-warmup headline minimum.
Commit `541d1cc` additionally fails a benchmark request if the prover returns a statement different
from the requested statement before proof encoding or artifact publication.

A clean detached ReleaseFast matrix at `541d1cc` used the functional protocol, ten warmups, five
samples per lane, alternating lane order, and a one-second cooldown. All three rows were
headline-eligible with no blockers:

| Workload | CPU prove (ms) | CPU native MHz | CPU request (ms) | Metal prove (ms) | Metal native MHz | Metal request (ms) | Metal/CPU prove |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wide Fibonacci `log10x8` | 1.935792 | 0.528982 | 2.109166 | 5.737333 | 0.178480 | 5.899958 | 0.337x |
| XOR `log10/step2/off3` | 2.705125 | 0.378541 | 2.886166 | 5.090667 | 0.201152 | 5.237125 | 0.531x |
| Plonk `log10` | 2.797875 | 0.365992 | 3.010958 | 7.549375 | 0.135640 | 7.751042 | 0.371x |

Every measured proof verified locally, every sample within each lane was byte-identical, and CPU
and Metal emitted the same canonical proof for each workload. The pinned Rust Stwo oracle accepted
all three artifacts:

| Workload | Proof bytes | Canonical proof SHA-256 |
| --- | ---: | --- |
| Wide Fibonacci | 23,569 | `1beb388cda4e2941e5a65c11653d78de3116ae95a686538105312c29ff9f6f0c` |
| XOR | 23,505 | `574b4d698125fb6049e6c5f87293f5c755c4029b28cf2a6839d49af1f720831f` |
| Plonk | 26,642 | `72eff9606d8c6fd374c7ba5364212fba5dc80db092c9abd3d8f8c471344b2f4f` |

The CPU and Metal binary SHA-256 values were
`bc4555baad27568a72797b57618925f9d1f0f34ebd6c989d2089fe85a3f2366f` and
`90b35d5e798aba04193e9fa9e0555dab09373a9d08f8f3508c0b807bb855b092`.
The complete summary is retained outside the repository at
`/private/tmp/stwo-formal-results-541d1cc/summary.json`. These values are the authoritative bounded
suite baseline; they do not claim that the current hybrid Metal transaction is faster than CPU.
