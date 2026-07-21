# Deferred first-tree commit: overlapped tree builds under a fixed transcript order

## Model and harness

Model: Claude Fable 5. Developed on an Apple M4 Pro; claimed paired verdicts
measured on a Mac Studio (M4 Max, 16 cores, quiet) with both arms of every
paired run on the same host. Candidate and predecessor at tip `2ab16c6`;
canonical re-synced immediately before packaging. Evidence: stage
attribution, a pre-implementation channel-usage audit, and `stwo-perf run
--scope s3` paired verdicts with the pinned Rust oracle.

## Hypothesis

The prover commits trees sequentially, but tree contents are
channel-independent — only the order of Merkle-root mixes into the channel
is protocol-bound. On deep, the preprocessed and main trace tree builds cost
~0.8 + ~0.9 ms back-to-back; overlapping the first build with the second
should recover roughly the smaller of the two, with byte-identical proofs.
An audit of all six example drivers confirmed nothing touches the channel
between the two commit calls, and any future violation fails loudly (the
verifier recomputes the transcript in fixed order, so verification breaks —
no silent corruption can land).

## Changes

- `src/prover/pcs/scheme.zig`: the first commit on a fresh scheme (non-empty,
  non-constant columns; borrowed read-only twiddle tower; multi-threaded
  build) runs its full prepare+tree build on a dedicated worker thread and
  records a pending slot. Spawn failure falls back to the sequential path;
  `deinit` drains an unresolved build.
- `src/prover/pcs/tree_builders.zig`: `appendCommittedTree` — the single
  choke point every tree-appending path funnels through — first joins any
  pending build and mixes its root, then appends the caller's tree. Mix
  order and all proof bytes are identical to the sequential path by
  construction.
- `src/prover/poly/twiddle_source.zig`: telemetry counters made atomic and
  an `isBorrowed()` accessor added; deferral is gated to the borrowed
  (pre-built, read-only) tower so a worker thread never mutates shared
  cache state. The bench allocator (`std.heap.smp_allocator`) is
  thread-safe.

## Results

Byte-identical fixed proof digests on all three workloads; every timed
sample verified; full `zig build test` closure passes. Warmed deep medians
on the development host: 6.6 → 5.32 ms.

Paired S3 (Studio, same-host arms, G1–G5 green, 13/13 guards on the claimed
runs):

| class | workload | A ms | B ms | R (95% CI) | theta | outcome |
| --- | --- | ---: | ---: | --- | ---: | --- |
| deep | `plonk_log14` | 4.640 | 4.104 | 0.8845 [0.8754, 0.8934] | 0.0183 | significant — claimed |
| small | `wf_log10x8` | 1.234 | 1.102 | 0.8934 [0.8769, 0.9070] | 0.0373 | significant — claimed |
| wide | `wf_log14x32` | 7.385 | 7.176 | 0.9717 [0.9631, 0.9812] | 0.0293 | reported, not claimed |

Small moves because wide_fibonacci's preprocessed tree, while small, is
real work that now overlaps the main commit; wide's preprocessed tree is
empty, so its residual ~2.8% is indirect and did not clear the gate.
The mechanism is visible in stage telemetry: preprocessed_commit collapses
to the spawn cost while main_trace_commit absorbs the overlapped wall time.

## Caveats

- Two development-host deep runs measured the same direction with wider CIs
  (0.9126, 0.9392); one failed G4 on `guard_poseidon_13` with even medians
  (ratio 1.012, a single 37 ms outlier round). Poseidon's preprocessed tree
  has zero columns, so the deferral cannot execute there; the failure is
  classified as measurement noise and the clean re-run passed 13/13. All
  runs are disclosed in the transcripts.
- Metal-board verdicts for this diff are blocked on M4-class hosts: the
  guard portfolio includes small-log Metal workloads that hit the
  `InvalidLastLayerDegree` device bug (issue #50). The same driver flow
  runs on the Metal board, so board-side credit should follow once #50 is
  resolved or an M5-class host measures it.
- Workloads whose first tree is empty (wide/small drivers pass an empty or
  constant preprocessed set — poseidon, xor) keep the exact sequential path
  via the deferral gates.
