# Subtree-scheduled Merkle layer construction and size-routed layer buffers

## Model and harness

Model: Claude Fable 5. Autonomous session on an Apple M4 Pro (12 cores)
running macOS, second session in this solver lane. Candidate and predecessor
are both `9046758f0def`; the workspace was a fresh `stwo-perf clone` and the
canonical checkout confirmed current by `stwo-perf update` before the final
paired runs. Evidence uses the repo-resident harness end to end: `--profiled`
stage attribution, `stwo-prof zig isolate` counters on live repo code, and
`stwo-perf run --scope s3` paired verdicts with the pinned Rust oracle.

## Hypothesis

Fresh stage attribution put `fri_quotient_build_and_commit` first in every
scored class (42% of small, 32% of wide, 47% of deep prove time). Env-gated
phase timers decomposed the wide-class stage: the inner FRI layer cascade
cost ~2.26 ms, of which per-layer Merkle commits were ~1.63 ms while the
line folds themselves were only ~0.24 ms. A 16384-leaf inner tree cost
567 µs against ~100 µs of true hash work (isolated harness: 17.3M
instructions per commit, ~525 instructions/hash vs a ~350–375 kernel floor,
futex wait 8.4%, spawn entry 8.8%).

Three scheduling defects explained the gap, multiplied by one tree per FRI
fold layer plus every trace commit:

1. every Merkle layer buffer — including 64-byte top layers — was allocated
   through raw mmap/madvise/munmap with first-touch page faults (~120
   mmaps per proof);
2. upper layers ran one thread-pool barrier per level, and every level with
   fewer than 2048 output nodes ran serially — the entire top of every tree,
   ~2047 serial hashes per large tree;
3. worker-override environment lookups re-ran per level per tree.

Prediction: routing small buffers to the general-purpose heap and building
all upper layers in one subtree-parallel pass with a single barrier removes
most of the non-hash overhead, with byte-identical layers, moving all three
classes.

## Changes

All inside `src/prover/vcs_lifted/`:

- `parameters.zig`: `layerAllocator` now routes buffers below 1 MiB to the
  general-purpose heap and keeps mmap (sequential-read hint, pages returned
  on free) for buffers at or above 1 MiB. Alloc and free route by the same
  length rule, so pairing is consistent.
- `layers.zig`: new `buildUpperLayersSubtree` builds every internal layer in
  one pass. Worker count is floored to a power of two so chunk boundaries
  align with subtree boundaries at every level; each worker builds its
  contiguous subtree bottom-up (cache-hot, no cross-worker reads before the
  barrier), one `spawnWg` barrier total, then the top `log2(W)` levels
  finish serially with the existing seeded 4-wide loop. Serial fallback
  preserves the sequential path for small trees and non-seeded hashers.
- `prover.zig`: both tree-build call sites (`buildTreeFromOwnedLeaves` and
  `commitWithOptions`) use the new builder; the worker-override environment
  lookup is hoisted to once per tree.

Buffer sizes, allocation order, hash inputs, and layer contents are
unchanged — layers are byte-identical by construction. Leaf building, the
hash kernel, fold arithmetic, and all protocol logic are untouched.

## Results

Fixed proof digests match the committed values on all three workloads;
every timed sample verified and byte-identical; `zig build test` passes.
Warmed diagnostics: wide first-layer upper tree 520→225 µs, wide inner
cascade 2260→1750 µs.

Paired S3, 15 rounds per class, all G1–G5 green, 13/13 regression guards:

| class | workload | A ms | B ms | R (95% CI) | theta |
| --- | --- | ---: | ---: | --- | ---: |
| small | `wf_log10x8` | 1.624 | 1.336 | 0.8116 [0.7868, 0.8386] | 0.0373 |
| wide | `wf_log14x32` | 10.870 | 9.632 | 0.8921 [0.8788, 0.9175] | 0.0293 |
| deep | `plonk_log14` | 7.103 | 5.791 | 0.8113 [0.7957, 0.8276] | 0.0183 |

Suite geometric mean ≈ 0.834. The mechanism is visible where predicted: the
Merkle-commit share of the FRI stage and the trace commits shrink while fold
and quotient-tile phases are unchanged.

## Caveats

- One earlier deep-class run failed G4 on `guard_blake_12x16` with round
  medians at 0.997 — late-round outliers inflated the guard's upper CI. A
  clean re-run passed 13/13 guards with a tighter objective CI; both runs
  are recorded in the attached transcripts.
- Verdicts are claimed/advisory (M4 Pro); the judged re-run is
  authoritative. The barrier/serial-tail savings should transfer to any
  multi-core host, but the split between the allocator and scheduling
  contributions is topology-dependent; low-core hosts will see mainly the
  allocator effect.
- The 1 MiB mmap threshold was chosen so the largest suite buffers keep the
  existing mmap behavior; it was not swept.
- This change is scheduling-only per the algorithm-matching gate: the
  canonical problem (binary Merkle over a fixed hasher) and its protocol
  shape are mandated, so no algorithm replacement was considered.
