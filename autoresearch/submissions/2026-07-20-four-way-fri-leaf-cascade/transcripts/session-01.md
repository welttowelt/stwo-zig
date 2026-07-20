# Session 01 — frontier synthesis and large-step search

Model: GPT-5 Codex

## Objective and starting state

The user asked for the largest defensible forward step, not a sequence of small
constant-factor submissions. The repository-specific `stwo-perf update` was run
before research and reported the checkout current at `95f32a8f9f6e`. The fresh
workspace was then created from that clean `main` predecessor.

The fixed objective is end-to-end CPU prove time with byte-identical proofs.
The scored classes are small wide-Fibonacci (`wf_log10x8`), wide
wide-Fibonacci (`wf_log14x32`), and deep Plonk (`plonk_log14`). Promotion needs
an S3 paired-run confidence interval wholly beyond the 1% threshold, while
conformance, identity, mechanism, resource, and environment gates remain valid.

The initial frontier has two promoted results: packed direct quotient rows plus
resident Merkle-pool reuse (wide frontier 17.321 ms), followed by deeper
resident-pool use in Merkle trees (small frontier 2.379 ms). The next step will
start from their combined code on `main`, not re-test a stale baseline.

## Decision process

Before changing code, the plan is to read the complete notes and transcripts
for both promoted efforts, reconstruct their diffs and measured stage profiles,
and inspect recent branch history for unpromoted ideas. This is necessary to
avoid duplicating already-rejected work and to identify the next structural
bottleneck exposed by the two pool/packing changes.

The selection bar is deliberately high: prefer a mechanism affecting a major
end-to-end stage across multiple workloads, with a predicted improvement over
1%, rather than accumulating isolated micro-edits. CPU counter or stage-profile
evidence will determine whether the next move targets arithmetic work, memory
traffic, dependency chains, or orchestration overhead. If the move replaces an
algorithm rather than tuning an implementation, the repository's algorithm
matching gate will be completed before editing.

## Prior-work synthesis and current attribution

Both promoted transcripts and source diffs were read in full. Earlier history
also shows that this code already has four-way SIMD BLAKE2 compression, seeded
parent hashing, four-lane first-layer leaf hashing, batched leaf packing, fused
lazy quotient-to-leaf production, FRI fold-step 4, and global worker-pool reuse.
Those mechanisms are therefore baselines, not new hypotheses.

Current profiled diagnostics put `fri_quotient_build_and_commit` at roughly
1.22 ms of a 2.78 ms small proof, 5.39 ms of a 14.11 ms wide proof, and 5.34 ms
of a 9.95 ms deep proof. Main/composition Merkle commitments and wide
composition evaluation are secondary. Because the public stage aggregates
quotient evaluation, first-tree hashing, circle/line folding, and inner FRI
trees, temporary timing probes will split this stage. They will be removed
before any candidate benchmark; their purpose is to distinguish a hash/schedule
attack from a fold/arithmetic attack.

Temporary warmed probes resolved the aggregate. On wide/deep, the lazy first
layer was about 0.9–1.0 ms, initial circle folding about 0.74 ms, line folds
about 0.62 ms total, coordinate conversion under 0.06 ms, and inner Merkle
commits roughly 3.0 ms. The 8,192-leaf inner tree took about 0.81–0.83 ms while
the larger 16,384-leaf tree took only 0.50–0.55 ms. Source inspection explains
the inversion: the four-message SIMD batched leaf builder is selected only at
16,384 leaves, while every smaller FRI layer constructs and finalizes one
incremental hasher per leaf. Since the functional protocol uses fold step 1,
this slower fallback repeats at every power-of-two layer down to the final
polynomial.

The first candidate lowers the existing batched-leaf crossover to 1,024 leaves.
This is constant-factor strategy selection between two already-correct builders,
not an algorithm replacement. Prediction: remove at least 0.8 ms from wide and
deep FRI commits and materially improve small proofs by accelerating several
repeated commitments. Falsifier: warmed full-proof time regresses or the
1,024/2,048-leaf trees show allocation/task overhead larger than their SIMD
hashing savings. Thresholds below 1,024 are deferred until this crossover is
measured because the batched builder reserves scratch and hasher storage.

The 1,024-leaf experiment passed its falsifier. Warmed diagnostics moved from
about 14.07 to 12.81 ms wide, 10.02 to 8.64 ms deep, and 2.71 to 2.36 ms small,
with the same proof hashes. Inner FRI time fell from about 4.33 to 3.16 ms on
wide and 4.23 to 3.09 ms on deep. The 8,192/4,096/2,048/1,024-leaf Merkle
commits all became much faster; the 512-leaf legacy commit was then slower than
the newly batched 1,024-leaf commit.

Inspection found that the SIMD branch of `buildBatched` never reads its
per-leaf `H` array: it packs exactly four leaf messages and calls the four-way
hash primitive directly. It also needs only `4 * bytes_per_leaf` scratch, not
the generic 256 KiB per worker. The candidate will therefore retain the
existing generic allocations for non-four-way hashers but allocate zero
incremental hashers and exact four-message scratch for the SIMD-capable hasher.
This reduces memory as well as setup cost and supports testing a 256-leaf
crossover without turning tiny FRI layers into allocation-heavy work.

## Final candidate and evidence

The final candidate selects the SIMD batched leaf builder at 256 leaves. For
the four-way-capable hasher it allocates no incremental hasher array and sizes
scratch to exactly four leaf messages per worker; generic hashers retain their
previous storage path. Temporary timing probes were removed before candidate
measurement, and the final source diff is confined to `leaves.zig` and
`parameters.zig` under the manifest's editable surface.

Seven-sample warmed diagnostics, run separately on candidate and unchanged
predecessor under the same machine state, produced these medians:

- small: 2.816 ms predecessor versus 2.208 ms candidate;
- wide: 16.469 ms predecessor versus 12.589 ms candidate;
- deep: 12.017 ms predecessor versus 8.542 ms candidate.

All candidate samples verified, were mutually byte-identical, and retained the
predecessor proof hashes for each workload. These are diagnostics rather than
the paired promotion claim, but they show the mechanism is suite-wide and has
no observed cross-class regression.

Focused ReleaseFast gates passed for both the prover library (152 transitive
Zig sources) and the native CPU product (190 transitive Zig sources). Formatting
and `git diff --check` passed; no temporary probe or locked-path change remained.

The exact S3 deep/time ABBA run against unchanged current `main` produced ratio
0.8636 with 95% CI [0.8587, 0.8708] across 15 paired rounds. Predecessor median
was 9.853 ms and candidate median was 8.521 ms. G1–G5 all passed, including
verification and byte identity on every timed proof. This is a 13.64% paired
end-to-end improvement and is significant beyond the 1% floor.

## Alternatives and dead ends retained

- Reworking BLAKE2 compression was rejected after history/source review showed
  four-way SIMD, seeded parents, byte-shuffle rotates, and direct transposition
  were already implemented. The observed discontinuity was dispatch policy,
  not absence of a vector kernel.
- A FRI folding rewrite was rejected for this submission after detailed probes
  attributed about 3.0 ms to inner Merkle commits versus roughly 1.36 ms to
  initial and line folding on wide/deep. It had less immediate headroom and a
  larger correctness surface.
- Proof-of-work thread reuse was considered because PoW costs about 0.23 ms,
  but the channel implementation is outside the manifest's editable paths and
  the maximum saving is much smaller than the repeated FRI-tree opportunity.
- Stopping at the 1,024-leaf threshold was rejected because its own result
  showed the 512-leaf fallback had become slower than the 1,024-leaf SIMD path.
  Removing unused allocation made the 256 crossover the coherent completion of
  the same mechanism rather than a separate micro-optimization.
- Thresholds below 256 were not added after a significant solution existed;
  their absolute residual share is small, and the user explicitly requested
  submission as soon as a large improvement cleared the paired bar.

The submission decision follows directly from the user instruction: package
now that a large, suite-wide mechanism has a significant S3 verdict, rather
than holding it for unrelated follow-on work.
