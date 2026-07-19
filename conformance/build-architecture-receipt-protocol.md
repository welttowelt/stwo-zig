# Build architecture receipt protocol

Status: **foundation implemented; final release evidence remains NO-GO**

This document specifies the evidence protocol implemented by
`scripts/build_architecture_receipt.py`. It is the BG-15 foundation required by
[the build-monorepo delivery goal](2026-07-19-zig-build-monorepo-delivery-goal.md).
It does not assert that BG-00 through BG-15 have passed.

The allocation and trust policy are versioned in
[`build-architecture-receipt-protocol-v1.json`](build-architecture-receipt-protocol-v1.json).
Changing that manifest changes the protocol digest and invalidates receipts
from the previous allocation.

## Roles

The protocol has three distinct roles:

1. `architecture-linux` produces the Linux host receipt.
2. `architecture-macos` produces the macOS host receipt.
3. `architecture-verify` admits both artifacts and is the only GO authority.

The host producer records facts and derives a host verdict. It does not confer
trust on its own output. The aggregate verifier owns cross-host allocation,
freshness, replay, and release policy.

## Receipt family

Host receipts use `build-monorepo-host-receipt-v1`. Aggregate receipts use
`build-monorepo-receipt-v1`. Both are:

- canonical JSON with sorted object fields and no insignificant whitespace;
- rejected when a JSON object contains duplicate keys;
- bounded to the size and collection limits in the protocol manifest;
- content-addressed with `content_sha256` over every other receipt field; and
- written atomically without replacing an existing receipt.

The host receipt binds:

- repository, clean commit, tree, and dirty-content digest;
- product-schema and protocol-manifest digests;
- protected workflow path, definition digest, ref, and workflow commit;
- repository numeric identity, run ID, attempt, job, and fresh session nonce;
- host role, OS, architecture, and toolchains;
- every BG-00 through BG-14 allocation verdict;
- required product identities and artifact or executable digests;
- exact ordered commands, durations, exit codes, and skipped-test counts; and
- compatibility, oracle, benchmark, closure, performance, memory, and source
  evidence digests.

The aggregate retains those records by host and binds each parent receipt's
wire digest, content digest, and canonical artifact name.

## Local diagnostics

Local production is unsigned by default:

```sh
python3 scripts/build_architecture_receipt.py produce \
  --host-role auto \
  --run-id 1 \
  --run-attempt 1
```

Local receipts are useful for validating schema, product allocation, command
ordering, and missing evidence. They always derive `NO-GO`, even when supplied
evidence claims PASS. The trusted aggregate verifier rejects them.

If no evidence manifest is supplied, the producer writes a diagnostic receipt
with every allocated checkpoint explicitly `NO-GO`. It does not invent product
or command evidence.

## Host evidence input

Gate owners supply one canonical `build-architecture-host-evidence-v1`
manifest. Its top-level fields are:

```json
{
  "checkpoints": {},
  "commands": [],
  "evidence": {},
  "products": [],
  "schema": "build-architecture-host-evidence-v1"
}
```

The producer fills unallocated checkpoints itself. An allocated checkpoint is
PASS-capable only when it has evidence, its required command phase ran, every
command exited zero, and no test was skipped. The host as a whole is PASS-capable
only when every allocated checkpoint, required product, command phase, and
evidence category passes on a clean supported host.

The evidence manifest is a transport boundary, not an authority boundary. CI
must build it from the repository-owned focused gate owners. The protected
workflow controls which manifest and artifacts are uploaded.

## Trusted CI admission

A host receipt may use `github-actions-artifact-v1` only when its environment
matches the repository, numeric repository and owner identities, workflow ref,
run, attempt, and role-specific job pinned by the protocol manifest. Its
artifact name is derived from host role, candidate commit, run, and attempt.

The aggregate verifier must itself run as `architecture-verify` in the same
protected workflow run and attempt. It requires the server-issued 256-bit
session nonce and rejects:

- a local unsigned receipt;
- a stale or future-dated receipt;
- a repeated role, file identity, or content identity;
- a role-swapped or non-canonical receipt path;
- another commit, tree, product schema, protocol, workflow, run, or nonce;
- an unauthorized repository, owner, workflow, producer job, or artifact name;
- dirty source or an OS presented under the wrong host role;
- reordered mandatory phases, skipped tests, missing products, or omitted
  checkpoint evidence; and
- an attempt to replace an existing aggregate receipt.

The workflow must download the named artifacts through GitHub's trusted
artifact channel before invoking the verifier. Receipt fields do not prove how
a file reached disk. Protected workflow ownership, exact artifact selection,
and the verifier's same-run environment check form that external trust boundary.

## Output paths

Host output follows the bounded layout:

```text
zig-out/release-evidence/build-architecture/<commit>/<host>/<run-id>.json
```

A successful aggregate is the only artifact written to:

```text
zig-out/release-evidence/build-architecture/<commit>/receipt.json
```

An incomplete but structurally admitted aggregate is written below
`<commit>/attempts/` with `NO-GO` in its name. It cannot occupy or replace the
final receipt path.

## Build ownership

`build_support/gates/architecture_receipts.zig` owns the two Zig build steps.
The root build needs one dispatcher line inside `build`:

```zig
@import("build_support/gates/architecture_receipts.zig").addGates(b);
```

After that wiring, the intended interfaces are:

```sh
zig build architecture-gate -- \
  --attestation github-actions-artifact \
  --evidence-manifest <host-evidence.json>

zig build architecture-verify -- \
  --candidate <commit> \
  --linux-receipt <linux.json> \
  --macos-receipt <macos.json>
```

The protected workflow supplies `GITHUB_*` identities and
`STWO_ARCHITECTURE_SESSION_NONCE`. No local command may set final GO status.

## Current decision

The protocol foundation and adversarial model tests are not product evidence.
Until the focused owners produce real host manifests and the protected workflow
admits them from one clean commit, the build-monorepo delivery goal remains
**NO-GO**.
