# RISC-V release evidence execution

This document defines the hosted execution contract for CP-13 in
[the RISC-V release goal](2026-07-18-riscv-release-goal.md). It separates the
expensive, exhaustive evidence producer from the bounded live consumer without
allowing either path to claim evidence from another candidate.

## Service-level objective

| Path | Purpose | Frequency | Limit |
|---|---|---:|---:|
| Exhaustive producer | Run the complete canonical CP-13 plan and publish an immutable candidate bundle | Once per exact candidate and phase | `90` minute fail-safe timeout |
| Fast release gate | Revalidate the exact bundle, run a fresh cross-shard proof, and independently verify it | Every repeated release decision | Hard `3` minute job timeout |

The fast path does not rebuild Rust, Zig, Stark-V, or stwo-cairo. Local
measurement of its core bundle verification plus a fresh 131,078-step
cross-shard proof and independent verification is `3.60s`. GitHub runner setup,
API calls, artifact transport, and evidence upload remain inside the hard
three-minute job timeout.

The exhaustive producer is not represented as a fast result. A new candidate
SHA, phase change, expired artifact, source-domain change, oracle identity
change, or failed producer requires a new exhaustive run.

## Trust root

Both jobs execute the workflow definition from `refs/heads/main`; they never
execute workflow YAML from the candidate branch. Admission is fail-closed on:

- canonical repository `teddyjfpender/stwo-zig`, numeric ID `1152389958`;
- `workflow_dispatch` at `refs/heads/main`;
- numeric owner ID `92999717` for both actor and triggering actor;
- a full candidate SHA in the canonical repository;
- an explicit `refs/heads/*` source ref whose current head is that SHA; and
- an exact candidate/promoted phase match in the checked-out source.

GitHub currently reports `main` as `.protected=false`. Enabling branch
protection and restricting workflow changes is an administrator hardening TODO.
Until that setting changes, owner dispatch by immutable numeric identity is the
checked trust root. The workflow and this document do not claim that `main` is
protected.

## Producer

Dispatch from the canonical repository, always with `--ref main`:

```sh
candidate_sha=$(git rev-parse HEAD)
candidate_ref=refs/heads/$(git branch --show-current)

gh workflow run ci.yml --ref main \
  -f gate=riscv-produce-candidate \
  -f candidate_sha="$candidate_sha" \
  -f candidate_ref="$candidate_ref"
```

Use `riscv-produce-promoted` only when the exact source has the promoted
registry state. The producer runs this exact ordered plan and rejects omitted,
duplicated, reordered, skipped, or shell-rewritten phases:

1. Zig formatting, upstream pins, and source conformance.
2. Complete phase, structure, core-purity, and frontend-layering contracts.
3. Full Python discovery, with Metal preparation first on Darwin.
4. Exhaustive RISC-V staged CLI evidence.
5. The strict transitive Zig release gate.
6. Fresh pinned Stark-V build-and-compare evidence and receipt validation.
7. Candidate-bound release-evidence validation.

The published artifact is named
`riscv-exhaustive-bundle-<candidate>-<run>-<attempt>`. It binds the candidate
commit and tree, producer workflow commit, dispatch identities, phase, exact
command plan, delegated mutation coverage, source domains, toolchains, oracle
build, executable digest, and every retained file digest. It expires exactly
30 days after creation, matching Actions artifact retention.

The pinned Stark-V helper uses the content-addressed cache contract in
[RISC-V Oracle Build Cache](riscv-oracle-build-cache.md). A valid hit skips only
Rust compilation; the complete Rust/Zig comparison corpus still executes. A
miss builds once, atomically stores the validated executable, and records
`status: miss`. The outer Actions key covers the full shared inner identity,
cache schema, and entry contract. There are no broad restore prefixes.

## Fast consumer

After the exhaustive job succeeds, dispatch the consumer with its numeric run
ID:

```sh
gh workflow run ci.yml --ref main \
  -f gate=riscv-candidate \
  -f candidate_sha="$candidate_sha" \
  -f candidate_ref="$candidate_ref" \
  -f producer_run_id=<producer-run-id>
```

Use `riscv-promoted` for promoted source. The consumer resolves the explicit
producer run and attempt rather than searching for a convenient success. It
requires exactly one successful job named `RISC-V exhaustive release evidence`
and exactly one live, unexpired artifact with the exact candidate/run/attempt
name and a valid SHA-256 transport digest. Failure of an unrelated job in the
same workflow does not invalidate a uniquely successful producer job.

The consumer then:

1. checks out the exact candidate with credentials disabled;
2. reconstructs and validates the producer trust context;
3. downloads only the explicit producer artifact;
4. verifies bundle lifetime, file hashes, complete source domains, command
   plan, coverage matrix, oracle receipt, executable identity, and phase;
5. runs a fresh 131,078-step cross-shard proof with the retained executable;
6. verifies that proof in an independent process; and
7. retains the fast receipt plus artifact transport identity.

The immutable oracle receipt is checked at its recorded creation time because
its bytes are already covered by the unexpired bundle. This permits exact
evidence reuse for the same 30-day lifetime as the artifact without silently
extending either lifetime.

## Concurrency and failure policy

Exhaustive jobs use a per-candidate non-cancelling concurrency group. Fast jobs
use a per-candidate and producer-run non-cancelling group. A newer dispatch
cannot cancel or substitute evidence for an older candidate.

No path fabricates results, falls back to another run, accepts an expired
bundle, accepts a dirty checkout, or promotes the RISC-V autoresearch group.
Autoresearch remains outside this execution contract and disabled until its own
documented gates are satisfied.
