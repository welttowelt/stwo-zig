# Cairo Program Matrix

Status: accepted benchmark and implementation plan, 2026-07-17.

## Purpose

Native AIR examples measure shared Stwo primitives, but they do not replace real Cairo programs.
The Cairo performance suite must vary both program behavior and input size so that work on one
component or one trace shape cannot masquerade as a general backend improvement.

The suite has two distinct roles:

1. Rust `stwo-cairo` SIMD and Metal runs are the correctness and performance reference.
2. Zig SIMD and Metal runs measure this repository only after a complete Cairo proof is accepted
   by the pinned Rust verifier.

Reference rows and Zig rows must never share an ambiguous `Metal` or `SIMD` label.

## Soundness boundary

The current general Zig Cairo path is incomplete:

- `frontends/cairo/prover.zig::proveCairo` is a stub that returns `ProvingFailed`.
- `frontends/cairo/prove_trace.zig` commits `pc`, `ap`, and `fp` under a constant demonstration
  AIR. It is not a sound Cairo execution proof and is excluded from this matrix.
- the resident Cairo Metal path has sound SN2 machinery, but its semantic artifacts and compact
  proof geometry are still SN2-shaped;
- general `STWZCPI` ingestion is implemented and is an input-parity gate, not a proof result.

Consequently, the existing Cairo Fib table is explicitly a Rust `stwo-cairo` reference table.
No Zig Cairo MHz may be published until the full witness, AIR, PCS, FRI, and proof interchange
passes the pinned Rust `verify_cairo` oracle.

## Program corpus

The canonical Cairo 0 corpus is compiled with Cairo `0.14.0.1` and `--proof_mode`.
Every program reads `program_input['iterations']`, but the parameter has different domain meaning.

| Program | Input meaning | Primary stress |
| :--- | :--- | :--- |
| `fib` | recursive iterations | control flow, opcode transitions |
| `sha2` | input bytes | memory, bitwise and range-check work |
| `sha2-chain` | chained 32-byte hashes | repeated SHA-256 arithmetic |
| `sha3` | input bytes | Keccak builtin and memory traffic |
| `sha3-chain` | chained hashes | repeated Keccak state transitions |
| `blake-precompile` | input bytes | Blake builtin throughput |
| `blake-chain-precompile` | chained operations | repeated Blake builtin transitions |
| `mat_mul` | matrix dimension | cubic arithmetic and memory growth |
| `ec` | secp256k1 doublings | large-integer and EC component pressure |

The compiled JSON files total about 42 MiB and are build artifacts. Reports bind their hashes, but
the files are not source-controlled.

## Geometry tiers

These sizes were executed through the canonical Rust VM and adapter on 2026-07-17. The cycle
counts select roughly increasing small, medium, and large traces without paying for a full proof
during suite planning. They are geometry evidence only.

| Program | Small input / cycles | Medium input / cycles | Large input / cycles |
| :--- | ---: | ---: | ---: |
| `fib` | 4,096 / 28,688 | 32,768 / 229,392 | 131,072 / 917,520 |
| `sha2` | 512 / 29,235 | 4,096 / 160,491 | 16,384 / 605,445 |
| `sha2-chain` | 128 / 45,970 | 512 / 183,442 | 2,048 / 733,330 |
| `sha3` | 256 / 19,433 | 4,096 / 217,337 | 16,384 / 814,193 |
| `sha3-chain` | 4 / 37,835 | 32 / 212,354 | 128 / 831,170 |
| `blake-precompile` | 8,192 / 21,695 | 65,536 / 172,223 | 262,144 / 688,319 |
| `blake-chain-precompile` | 128 / 20,856 | 1,024 / 166,008 | 4,096 / 663,672 |
| `mat_mul` | 8 / 13,523 | 24 / 304,643 | 32 / 705,179 |
| `ec` | 256 / 59,938 | 1,024 / 239,650 | 4,096 / 958,498 |

Larger saturation tiers may be added after the large tier is stable. They must not replace these
tiers or silently change a program's input semantics.

## Evidence contract

Every timed row records:

- program source, Cairo compiler, compiled JSON, benchmark binary, repository, and dependency
  hashes;
- exact backend identity: `rust-cairo-simd`, `rust-cairo-metal`, `zig-cairo-simd`, or
  `zig-cairo-metal`;
- requested input, emitted Cairo cycles, active component set, tree column counts, FRI geometry,
  and protocol parameters;
- execution, adaptation, cold proof, warm proof, verification, serialization, and direct
  launch-to-exit wall time;
- cycle MHz for proof latency and sustained verified queue throughput;
- proof byte length and digest, plus the pinned Rust verifier result;
- ordered samples, warmups, machine state, compiler mode, parallelism, and backend telemetry.

Headline results require a clean, reproducible provenance chain, byte-identical repeated proofs,
all requested proofs verified, and no early-to-late prove-time drift above the repository limit.
Dirty external binaries may be used for diagnostics, never headline evidence.

The full matrix is strictly sequential on a single machine. Large unified-memory runs have a
cooldown and memory-pressure gate. Profiling runs and performance runs are separate processes.

## Service measurements

Each backend is measured at three lifecycle levels:

1. **Cold latency:** create the backend and prove one input.
2. **Resident latency:** reuse immutable, geometry-keyed state and prove the same input again.
3. **Sustained queue:** select deterministic random indices from a declared program/input queue,
   prove every request in one resident service, verify every proof, and divide total emitted Cairo
   cycles by launch-to-verified-exit wall time.

The queue includes multiple programs and geometries. A cache keyed only by row count or component
count fails the suite; its key must authenticate program, claim, protocol, semantic artifacts, and
device pipeline compatibility.

## General Zig Cairo critical path

### 1. Runtime claim

The diagnostic MVP may consume the canonical Rust claim JSON. Production derives the same claim
from `STWZCPI`. The implementation is differentially tested against Rust
`cairo_claim_generator.rs`, `CairoComponents::new`, and the canonical claim types.

### 2. Projected semantic pack

Build the active dependency closure and project:

- recorded witness programs (`STWZWIT`);
- multiplicity feeds (`STWZFED`);
- relations (`STWZREL`);
- fixed tables (`STWZFIX`); and
- composition programs (`STWZEVA`).

Projection remaps every base and interaction span, preprocessed index, random-coefficient offset,
constraint count, maximum log, and semantic hash. Changing row logs without projecting the active
component set is rejected.

### 3. Runtime schedule

Generate the resident buffer schedule from the projected columns and exact PCS/FRI geometry.
Calculate the number of FRI rounds from the final degree. Do not clone SN2 buffer counts or fixed
round arrays.

### 4. Optional recipes

Prepare only recipes required by the active dependency closure. Verify-instruction compaction,
Pedersen, Poseidon, EC, and fixed-table writers are optional per program, never unconditional
SN2 setup work.

### 5. Dynamic proof geometry

Replace `Sn2Counts`, fixed tree arrays, and `initSn2`/`validateSn2` APIs with authenticated runtime
geometry. Trace groups, tree columns, FRI commitments, query openings, and decommitment records
come from the projected statement.

### 6. Verifier interchange

Generalize the compact Cairo proof format and its Zig/Rust codecs. The format authenticates runtime
trace and FRI counts and reconstructs the canonical Rust proof object. Local Zig verification is
necessary but not sufficient; pinned `verify_cairo` is final.

### 7. Acceptance sequence

1. Fib25k: 30 active AIR components, 10 recorded witness components, trace trees
   `[105, 396, 324, 8]`, and seven FRI commitments.
2. All three Fib geometry tiers.
3. SHA2 chain, matrix multiplication, and EC large tiers.
4. The complete nine-program, three-tier matrix.
5. Mixed-program sustained queues.

The implementation remains program-agnostic throughout. Program-specific prover branches or
hand-edited AIR constraints are not accepted.

## Current gates

- Nine canonical sources compile with Cairo `0.14.0.1`.
- Two repeated Rust SIMD smoke proofs per program pass `verify_cairo` and are byte-identical.
- A Rust Metal SHA2-chain smoke proof passes the same gate; its 22.710-second first proof and
  0.792-second warm proof demonstrate why cold and resident results must stay separate.
- Zig decodes the nine smoke `STWZCPI` files and exactly reproduces every Rust emitted cycle count.
- SN2 composition retargeting rejects Fib because its active component set differs; no invalid
  projected artifact is written.

These are readiness and correctness gates. They are not Zig Cairo proving-speed results.
