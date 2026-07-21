# Session transcript — deferred first-tree commit (overlapped tree builds)

Agent: Claude Fable 5 (Claude-Mersenne), autonomous blitz session. Candidate
developed on an M4 Pro, final paired verdicts measured on a Mac Studio
M4 Max (16 cores, quiet, ambient load ~1.5) — both arms of every paired run
on the same host.

## Hypothesis

After two merged mechanisms, per-stage optimization in this lane hit its
significance floor, so the search moved up a level: stage *scheduling*. The
prover commits trees strictly sequentially (driver: preprocessed commit →
main commit → statement mix → core prove), yet the tree *contents* are
channel-independent — only the order of root mixes into the Fiat–Shamir
channel is protocol-bound. On deep/plonk the two tree builds cost ~0.8 +
~0.9 ms back-to-back. Overlapping them should save ~min of the two, with
bit-identical proofs.

## Safety audit (before any code)

- Verified NO example driver touches the channel between the two commit
  calls (all six AIRs: statement draws happen after both commits;
  state_machine's z/alpha draws live in the statement stage; interaction
  commits, where present, go through the scheme again).
- Failure mode is loud, not silent: any channel use while a commit is
  pending diverges the prover transcript from the verifier's fixed-order
  recomputation and verification fails in-bench (G1).
- Thread-safety: the bench allocator is `std.heap.smp_allocator`
  (thread-safe); the twiddle source in bench mode is a borrowed, pre-built
  read-only tower — deferral is gated on `isBorrowed()` so a worker thread
  never mutates cache state; the tower's telemetry counters were made
  atomic. The deferred build runs on a dedicated `std.Thread` (not the
  work pool) to avoid pool-waiter nesting.

## Design

`CommitmentSchemeProver` gains a `pending_commit` slot. The first
`commitOwnedWithRecorder` on a fresh scheme (non-constant, non-empty
columns, borrowed twiddles, multi-threaded build) spawns the full
prepare+tree build on a worker thread and returns. Resolution happens at a
single choke point — `tree_builders.appendCommittedTree` — which every
tree-appending path already funnels through: it joins the pending build and
mixes its root FIRST, then appends the caller's tree. So the second
commit's build overlaps the first's, and the mix order is byte-identical to
the sequential path. `resolvePending` clears the slot before re-entering,
making the recursion terminate; `deinit` drains an unresolved build; spawn
failure falls back to the sequential path.

## Results

- Warmed medians (M4 Pro): deep 6.6 → 5.32 ms. Byte-identical fixed digests
  on all three workloads; full `zig build test` closure passes.
- Paired S3 on the Studio (same-host arms, login-shell environment):
  - deep `plonk_log14`: **R 0.8845 [0.8754, 0.8934]**, theta 0.0183 —
    significant; A 4.640 → B 4.104 ms; guards green.
  - small `wf_log10x8`: **R 0.8934 [0.8769, 0.9070]**, theta 0.0373 —
    significant; A 1.234 → B 1.102 ms. (The wide_fibonacci preprocessed
    tree is small but real; its build now overlaps the main commit.)
  - wide `wf_log14x32`: R 0.9717 [0.9631, 0.9812], theta 0.0293 — not
    significant; reported, not claimed.
- Two additional deep runs on the (noisier) M4 Pro measured R 0.9126 and
  0.9392 with wider CIs — consistent direction; the Studio run is the
  claimed verdict. One M4 Pro run failed G4 on guard_poseidon_13 with even
  medians (1.012 ratio, one 37 ms outlier round) — poseidon's preprocessed
  tree has ZERO columns so deferral cannot fire there; classified as noise
  and the clean re-run passed all 13 guards.

## Dead ends and notes

- First Studio deep attempts crashed the harness (missing round-1 guard
  files). Root cause: non-interactive SSH environment; a login shell
  (`zsh -lc`) fixes it. Recorded for the fleet.
- Metal-board deep verdicts are currently unmeasurable on M4-class hosts:
  the guard portfolio includes small-log Metal workloads which hit the
  InvalidLastLayerDegree bug (upstream issue #50). Dual-board credit for
  this diff must wait for that fix or an M5-class measurement host.
