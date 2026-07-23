# Sanitized research transcript: RISC-V deferred first-tree enablement

Model: Claude Fable 5, with CODEX ANVIL independent review.

## Attribution and hypothesis

The RISC-V worker-count sweep showed saturation after eight workers and a large
serial-equivalent floor. Lock attribution falsified a mutex-contention theory:
almost all waiting samples were workers parked at pool entry. Source inspection
then showed why the already-promoted deferred-first-tree path did not execute:
RISC-V creates an owned twiddle source, while the gate admitted only borrowed
twiddles. The predicted recoverable window was the overlap between the first
preprocessed commitment tree and locked witness generation.

## Implementation and critique

The first implementation serialized the owned twiddle cache and added
channel-less resolution for root observers. Review ACKed the success-path
root-mix ordering and owned-cache synchronization but NACKed one allocator
failure path: a failed tree-list append could leave a stale joined-thread state.
The fix clears pending state, frees the tree and slot, and is covered by a
failing-allocator test. The focused re-review then ACKed the mechanism.

Rejected alternatives included removing generic locks, which profile evidence
showed below 0.3% of samples, and broad memmove deletion, which was sized below
the live significance gate.

## Validation

Before final measurement, the candidate was rebased onto upstream main
`799efe87a9eccd6ae9a2e19c815e82bfbf1d4198`. Native CPU, Native Metal, and
RISC-V closures passed. Independent RISC-V proof comparison normalized the
known implementation-commit metadata field and found the proof body,
statement, and transcript identical.

The authoritative quiet-Studio S3 then bound candidate
`fe8d8303034915e1689ec33c986be2cbe6ae1f4c` to that predecessor. It produced
portfolio ratio 0.950958 with 95% CI [0.948479, 0.952669], seven of seven
workload CI uppers below 1.0, G1-G5 green, proof-byte ratio 1.0, and stable
mechanism telemetry. An earlier stale-pair battery was explicitly rejected and
never entered this package.
