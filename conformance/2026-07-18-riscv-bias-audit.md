# RISC-V release and bias audit

**Date:** 2026-07-18

**Audited commit:** `c072003106123c6dc3879f9acb04cb707c85445a`

**Decision:** **NO-GO** for the Stark-V adapter registry flip and autoresearch
enablement.

This is an independent audit of the RISC-V lane against
[the contribution contract](../CONTRIBUTING.md),
[the upstream ledger](upstream.md), and
[the source-decomposition ledger](decomposition-plan.md). It covers core purity,
frontend layering, RISC-V AIR and public-statement soundness, CLI release gating,
and autoresearch bias controls. It does not certify uncommitted work.

The audited commit contains oracle-aligned standalone semantic evaluators,
public LogUp compensation, relation challenges, and runner access witnesses.
They are useful committed building blocks, but are not release evidence until
integrated into both prover and verifier constraints and exercised by the
release gate.

## Governing requirements

The governing order is explicit: protocol soundness comes first, and the pinned
Rust implementation is the final correctness oracle (`CONTRIBUTING.md:65-75`). A
shared proof path without exact pinned-Rust evidence is blocked
(`CONTRIBUTING.md:193-204`). The RISC-V lane is independently governed by Stark-V
commit `d478f783055aa0d73a93768a433a3c6c31c91d1c`
(`conformance/upstream.md:19-28`).

The intended dependency direction requires frontends to depend on core and
backend-neutral prover interfaces, while concrete backend selection remains at a
boundary (`CONTRIBUTING.md:89-144`). A passing ratchet is not evidence that all
legacy violations have been removed.

## Gate matrix

| Gate | Result | Evidence and interpretation |
| --- | --- | --- |
| BP-1 Core purity | **PASS** | No core-to-frontend or core-to-concrete-backend relative import was found. The checker forbids those edges at `scripts/check_source_conformance.py:66-72,188-204`. |
| BP-2 Frontend layering | **FAIL** | `src/frontends/riscv/prover.zig:42` imports `backends/cpu_scalar`, and `:103-109` constructs the concrete CPU engine inside the frontend. |
| BP-3 Source ratchet | **PASS, debt remains** | `python3 scripts/check_source_conformance.py` passed with 20 explained legacy findings. The release gate invokes it at `build.zig:295-304,314-331`. This proves no unbaselined regression, not clean architecture. |
| AIR-1 Cross-shard state/program LogUp | **PASS for the implemented slice** | Cross-shard state claims and the program ROM bus cancel in `air/interaction_gen.zig:312-346`; the AIR commits opcode and program interaction constraints in `air/component.zig:236-280`. |
| AIR-2 Complete execution semantics | **FAIL** | All non-program infrastructure components are still silent zero constraints (`air/component.zig:1-13,99-104,200-203,289-291`). The prover itself states that memory, range, and per-family semantics are not wired (`prover.zig:1264-1267`). |
| IO-1 Public statement transcript binding | **PASS for transcript order** | `air/public_data.zig:51-80` mixes the public values in a fixed order. |
| IO-2 Public values constrained to execution | **FAIL** | `air/public_data.zig:3-7` explicitly says transcript binding does not prove trace membership. `air/statement.zig:35-37,69-72` allocates interaction columns only for the program infrastructure component. |
| OR-1 Pin consistency | **PASS** | `python3 scripts/check_upstream_pins.py` passed and all RISC-V pin carriers name the ledger commit. |
| OR-2 Reproducible final Rust oracle | **FAIL** | The normal vector gate replays committed Zig trace digests; it does not run Stark-V (`scripts/riscv_trace_vectors.py:512-563`). Live Rust comparison is optional and accepts an operator-supplied executable without a binary/build receipt (`:566-599`). |
| CLI-1 Fail-closed behavior | **PASS** | ELF prove, bench, and artifact verify route through the gated adapter (`src/tools/prove/app.zig:24-44,48-88,163-166`), whose run and verify entry points refuse acceptance (`starkv_adapter.zig:41-65`). |
| CLI-2 Registry release eligibility | **FAIL, correctly closed** | The registry advertises `not_release_gated` with the correct reason (`registry.zig:18-20`). The artifact schema also remains explicitly staged (`src/interop/riscv_artifact.zig:1-16`). |
| AR-1 Board isolation | **PASS** | Workload selection requires exactly one board (`autoresearch/cli/stwo_perf/manifest.py:89-117`); duplicate board ownership is rejected (`:195-217`); judge, frontier, and promotion all carry the board. |
| AR-2 Measurement honesty | **PASS for enabled lanes** | The runner requires the binary and report schema (`runner.py:101-147`), verified samples, and byte-identical repeated proofs (`:184-200`). G2 rejects both locked paths and paths outside the editable set (`:469-490`). |
| AR-3 RISC-V research activation | **FAIL, correctly disabled** | The RISC-V group is disabled with a reason (`autoresearch/MANIFEST.json:72-90`), and has neither a report-producing adapter nor frozen anchors/A/A dispersion (`:6-12`; `autoresearch/ledger/epochs.json:7-12`). |
| AR-4 RISC-V exercise validity | **FAIL** | Both workloads are `small`, the shared holdout mutates flags absent from ELF commands, G3 passes unconditionally while telemetry is pending, and the automation workflows are not installed. |
| DOC-1 Markdown target/anchor integrity | **PASS** | A repository-wide local Markdown target and anchor scan found zero missing Markdown targets and zero missing anchors. |
| DOC-2 Operative documentation hooks | **PASS** | The operative [divergence ledger](divergence-log.md) records active protocol differences, and the decomposition plan names active RISC-V owners. |

## Findings

### P0: the current proof does not establish RV32IM execution

The proof currently constrains the CPU state telescope and program lookup, but
does not constrain the meaning of the executed instruction families, memory
access chains, range checks, or most infrastructure tables. The architectural
facts are visible in three places:

- `src/frontends/riscv/air/component.zig:99-104` exposes only two opcode
  constraints, two program constraints, and one literal-zero silent constraint.
- `src/frontends/riscv/air/component.zig:236-280` implements only state-chain and
  program-bus equations for opcode shards and ROM emission for the program.
- `src/frontends/riscv/prover.zig:1264-1267` records the omitted memory-access,
  range-check, and family-semantic constraints directly.

The committed `air/semantics/` modules do not close this gap. They are imported by
the RISC-V test root (`src/tests/riscv/trace_test.zig:15`), but not by the AIR
component or prover. `air/semantics/base_alu_imm.zig:3-8,19-27` also identifies
two witness columns missing from the current committed layout. Its adversarial
test rejects a known impossible ADDI row (`:230-242`), but no proof-level test
shows the verifier rejecting that semantic forgery.

**Required acceptance evidence:** every enabled opcode family must have committed
witness columns, algebraic semantic constraints, its memory/range/bitwise lookup
terms, and at least one proof-level mutation test that an unconstrained version
would accept and the completed verifier rejects. Unsupported families must fail
before proving; they must not be represented by a silent component.

### P0: public I/O is bound to Fiat-Shamir, not to the execution

The public-data structure and mix order are useful, but transcript commitment only
prevents changing the public object after proof creation. It does not prove that
the register, root, input, or output values equal committed trace values. The
module states this limitation explicitly (`air/public_data.zig:3-7`).

The committed `air/public_logup.zig` and `air/relation_challenges.zig` are a
reasonable verifier-side shape. However, `public_logup.zig:3-6` correctly says its
sum is unusable until the same relation challenges, memory bus, clock model, and
Merkle bus are wired. No call from `prover.zig` currently draws those relations or
adds that public compensation to the aggregate interaction claim. A unit vector
for the standalone sum is necessary but not proof binding.

**Required acceptance evidence:** draw every Stark-V relation in the exact
transcript position on both sides; commit and constrain matching component-side
bus terms; add the public compensation exactly once to the global claim; and add
proof-level mutations for initial/final registers, roots, public input words,
output words, clocks, addresses, and lengths. Every mutation must fail in the
cryptographic verifier, not merely change the transcript.

### P0: the final Rust-oracle gate is historical and operator-asserted

The trace-vector gate rebuilds ELFs and the Zig dumper, then compares the resulting
Zig trace digest with a committed digest (`scripts/riscv_trace_vectors.py:525-545`).
Its success message says the vectors were verified against Stark-V (`:559-562`),
but no Stark-V process runs in that path.

The optional attestation compares only `total_steps`, `final_pc`, and `final_regs`
and trusts the operator's assertion that the supplied dumper was built from the
pin (`:566-596`). The committed vector metadata records the claim but no source
tree digest, build command receipt, executable digest, or clean-tree evidence
(`vectors/riscv_elfs/trace_vectors.json:1-12`). The repository Rust helper is
self-described as a standalone RV32IM executor and has no Stark-V dependency
(`tools/stark-v-trace-dump/Cargo.toml:1-10`). It is a useful differential
implementation, not proof that the actual pinned Stark-V binary was run.

**Required acceptance evidence:** CI or a release-evidence job must check out the
exact Stark-V commit from the ledger, verify a clean source identity, build the
oracle from that checkout, cross-run the full declared equivalence surface, and
record source commit plus executable digest. Any intentional PCS/AIR divergence
must be named in an existing operative divergence ledger and tested at the last
shared semantic boundary.

### P1: frontend ownership remains inverted

`src/frontends/riscv/prover.zig:42` imports the concrete scalar backend and
`:103-109` creates `CpuProverEngine`. This is explicitly baselined in
`conformance/source-baseline.json:5-10`, so source conformance passes by design.
The same file remains 2,355 lines against the 850-line manual ceiling; other
baselined RISC-V files remain at 935, 1,043, and 974 lines. Their budgets and
required extractions are recorded at `conformance/source-baseline.json:13-46`.

**Required acceptance evidence:** move backend selection into the CLI/integration
boundary, leave the frontend expressed against a prover-engine capability, split
proof planning from orchestration, then shrink the baseline entries in the same
commit. The source checker is a no-regression ratchet
(`scripts/check_source_conformance.py:138-209`), not a waiver of these boundaries.

### P1: the RISC-V autoresearch board is staged, not exercisable

The board isolation work prevents a second workload family from contaminating the
native score. That part is structurally sound: the board is mandatory, the judge
revalidates it (`autoresearch/bots/judge_action.py:74-109`), frontier rows are
board-scoped (`autoresearch/cli/stwo_perf/frontier.py:55-66`), and promotion uses
the board-specific head (`autoresearch/bots/promote_action.py:141-145`).

Four blockers remain before enabling the RISC-V group:

1. `riscv_proof_v1` has no producer because the adapter always fails closed.
2. The group has two small workloads and no wide or deep workload
   (`autoresearch/MANIFEST.json:79-90`).
3. The holdout generator rewrites `--log-n-rows` and `--sequence-len`
   (`runner.py:293-314`), but RISC-V commands contain neither flag. A judged
   RISC-V holdout is therefore the base command under a different name, not a
   hidden workload.
4. G3 is unconditional even while its own detail says telemetry is pending
   (`runner.py:515-520`). This cannot act as an independent mechanism-binding
   gate.

Additionally, `autoresearch/workflows/judge.yml:1` says it must be copied into
`.github/workflows/`, while that directory contains only `ci.yml` and
`benchmark-pages.yml`. The installation and branch-protection contract is
documented at `autoresearch/README.md:146-168`, but is not active in the repository.
Anchors and A/A dispersion are null, so G5 correctly prevents judged promotion.

RISC-V frontend paths are also absent from the editable set
(`autoresearch/MANIFEST.json:14-29`). This is the correct conservative policy
while the statement is changing. Once soundness freezes, either deliberately keep
the board limited to shared core/backend optimizations, or add narrowly scoped
RISC-V implementation paths at an appropriate rung. Do not make the whole
frontend editable.

## Registry-flip checklist

The registry may move the Stark-V adapter from deferred to release-gated only when
all of the following are simultaneously true:

- every accepted RV32IM family has proof-integrated semantic constraints and
  lookup buses; unsupported operations fail closed;
- cross-shard claims close for state, program, memory, range, bitwise, Merkle, and
  any other enabled Stark-V relation;
- public register, root, input, output, address, length, and clock values are
  constrained to those committed relations;
- prover and verifier use an identical, byte-traced Fiat-Shamir sequence;
- adversarial proof-level mutations fail for every public boundary and each
  enabled semantic family;
- a clean checkout of the pinned Stark-V oracle passes the declared equivalence
  suite with reproducible build and binary provenance;
- the CLI emits a validated `riscv_proof_v1` report, publishes artifacts
  atomically, and cryptographically verifies them rather than only validating
  their JSON shape;
- the registry, artifact release status, README, and deferred diagnostics flip in
  the same reviewed commit;
- the standard and strict release gates pass from a clean tree.

Only after that flip should the RISC-V autoresearch group be enabled. Its own
activation additionally requires representative small/wide/deep workloads, a
RISC-V-specific held-out workload generator, real G3 telemetry, installed judge
and promotion workflows, branch protection, frozen per-class anchors, and measured
per-class A/A dispersion on the designated judge host.

## Validation record

The following checks passed on the audited commit:

```text
python3 scripts/check_source_conformance.py
  20 explained legacy findings; no new violations
python3 scripts/check_upstream_pins.py
  all Native, Stark-V, and Cairo pin carriers match
python3 -m unittest discover -s autoresearch/tests -p 'test_*.py'
  104 tests passed
zig fmt --check build.zig src tools
zig build test-riscv -Doptimize=ReleaseFast
zig build test-riscv-prover -Doptimize=ReleaseFast
python3 scripts/riscv_trace_vectors.py
zig build stwo-zig -Doptimize=ReleaseFast
```

The built CLI listed the Stark-V adapter as deferred. An ELF benchmark invocation
exited nonzero with the pending-release-gate diagnostic. That is the correct
visible behavior for the current soundness state.

The successful RISC-V prove/verify roundtrips demonstrate internal consistency of
the implemented constraint slice. They do not override AIR omissions or replace
the final pinned-Rust oracle, per `CONTRIBUTING.md:67-75,201-204`.
