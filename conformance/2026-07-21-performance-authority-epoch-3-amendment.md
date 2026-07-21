# Performance authority epoch 3 amendment

**Status:** ACTIVE POLICY; measurement evidence remains uncaptured and therefore
`NO-GO`.

## Purpose

Epoch 2 correctly failed closed when the live autoresearch runner, statistics,
and manifest evolved. Its version-1 protocol remains immutable in Git history;
it is not repinned or relabelled. Epoch 3 replaces the live-file references
with repository-owned immutable snapshots so later board activation, workload
rotation, and control-plane changes cannot rewrite the statistical authority
used by an earlier performance receipt.

The historical baseline receipt at
`conformance/build-monorepo-baseline-v1.json` remains byte-for-byte unchanged.
No measurement is manufactured by this transition.

## Frozen authority

The version-2 protocol pins these epoch-3 snapshots by SHA-256:

- `conformance/performance-authority/epoch-3/runner.py.txt`;
- `conformance/performance-authority/epoch-3/stats.py`; and
- `conformance/performance-authority/epoch-3/MANIFEST.json`.

The statistics adapter imports the pinned snapshot directly. It must not verify
one path and then import the mutable live module under another path. The runner
snapshot is evidence of the complete paired execution policy; the manifest
snapshot is evidence of the exact workload and gate registry at this authority
transition.

## Preserved contracts

This amendment does not change the epoch-2 historical arms, six canonical
Native performance workloads, host roles, proof requirements, budgets, or
Hodges-Lehmann bootstrap policy. It changes only how policy source is frozen
and names a new protocol schema/version.

The broader holistic and RISC-V matrices are governed by their own current
autoresearch activation contracts. They do not become historical epoch-2
measurements by appearing in the live manifest.

## Gate

The active machine authority is
`conformance/build-monorepo-performance-baseline-v2-protocol-v2.json`. The
version-1 protocol remains an immutable record and is validated only from the
revision that owned its original live-file digests.

Epoch-3 performance promotion remains `NO-GO` until a future capture produces
the complete independently validated macOS and Linux evidence required by the
underlying epoch-2 measurement contract.
