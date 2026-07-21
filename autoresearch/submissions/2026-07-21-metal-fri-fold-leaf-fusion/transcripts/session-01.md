# Session 01 — fifth Metal-backend architecture campaign

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and objective

The preceding campaign merged PR #28, packing generic main/composition Merkle
levels into tail-fused arenas.  Its Native Metal evidence confirmed 1.55% wide
and 1.88% deep proof-latency reductions; the CPU-only recorder classified its
official controls neutral and advanced the recorded frontier to
`cafbe2c8a71f`.  The canonical checkout and repo-resident CLI were updated to
that exact commit before this workspace was created, and `stwo-perf setup`
passed.

All repository skills remain active: canonical algorithm matching, Metal
performance design and its compute-pattern reference, Metal profiling, Zig
host profiling, and reasoning-first submission transcripts.  The prior notes,
submission notes, and transcripts are cumulative research input.  No
production source has been edited in this iteration.

The first action is a fresh ReleaseFast source-JIT run of all three production
Native Metal shapes with exact proof and fallback auditing, followed by clean
stage/device attribution.  The leading unimplemented ideas from prior work are
fusing coordinate conversion with FRI leaf hashing, folding the circle-to-line
boundary into the resident FRI epoch, and reducing persistent CPU-side plan or
allocation overhead around already-fused GPU work.  Candidate selection waits
on the new frontier profile and a dependency/resource visualization.

## Fresh recorded-frontier profile

The transcript was stashed while the untouched frontier ran, so every report
records exact commit `cafbe2c8a71f`, `git_dirty=false`, `complete=true`, and
ReleaseFast.  Each class used ten warmups and seven profiled verified samples:

| stage median (ms) | small | wide | deep |
| --- | ---: | ---: | ---: |
| complete prove | 6.437 | 11.735 | 7.184 |
| main commit | 1.117 | 1.856 | 0.640 |
| composition evaluation | 0.055 | 2.618 | 0.120 |
| composition interpolate/split | 0.041 | 0.480 | 0.053 |
| composition commit | 0.933 | 1.386 | 0.742 |
| sampled values | 0.414 | 0.793 | 0.711 |
| FRI quotient/commit | 3.302 | 3.890 | 3.720 |
| proof of work | 0.406 | 0.335 | 0.318 |
| all decommitment | 0.089 | 0.120 | 0.125 |

Every timed proof matched the fixed class digest, independently verified, was
byte-identical within its process, reported accelerated-without-fallbacks, and
used zero CPU fallback.  FRI remains the dominant common residual.  Wide's
composition evaluation is also large, but it is mostly prover/field work rather
than the requested Metal focus.  The next dependency map therefore starts at
the physical boundaries inside the one-epoch line-FRI cascade, not at already
sub-millisecond decommitment or proof-of-work stages.

## FRI dependency map and selected fusion architecture

A fresh Debug device run put the thirteen-layer wide line cascade at a stable
3.37--3.51 ms, 93 dispatches, one compute encoder, one command buffer, and one
terminal wait.  The current per-stage chain is:

```text
evaluation_s (QM31 AoS)
  -> coordinate scatter grid -> coordinates_s (four SoA planes)
  -> leaf-hash grid           -> Merkle leaves_s
  -> parent grids/tail        -> root_s
  -> transcript mix/draw      -> alpha_s
  -> line-fold grid           -> evaluation_s+1
```

The coordinate planes must remain alive for proof decommitment, so deleting
the scatter is invalid.  Merely putting conversion and hashing in one new grid
would save one dispatch per stage.  A stronger producer-consumer fusion follows
from the dependency direction: the line fold has the next QM31 value in
registers.  For every nonterminal transition it can write the next evaluation,
scatter its four coordinates, and Blake-hash the next tree leaf before those
registers die.  The next stage then begins directly at its parent chain:

```text
initial: evaluation_0 -> [coordinates + leaf]_0 -> parents/root/channel

transition s:
root_s -> alpha_s -> [fold + coordinates + leaf]_(s+1)
                    |-> evaluation_(s+1)
                    |-> coordinates_(s+1)
                    `-> Merkle leaves_(s+1)
```

| physical work, wide | current | fused |
| --- | ---: | ---: |
| coordinate grids | 13 | folded into producer |
| leaf grids | 13 | folded into producer |
| line-fold grids | 13 | 12 fused transitions + 1 terminal |
| initial producer grid | 0 | 1 |
| parent grids/tails | 28 | 28 |
| transcript grids | 26 | 26 |
| total dispatches | 93 | 68 predicted |

Small similarly predicts 55 -> 38 dispatches.  Besides dispatch setup, the
fused kernels avoid rereading every just-written coordinate plane for leaf
hashing.  The hash message is still exactly the four QM31 coordinates followed
by twelve zero words, with the same seeded/unseeded initialization and byte
count as generic four-column leaves.

Candidate comparison:

| candidate | ceiling and risk | decision |
| --- | --- | --- |
| Fuse only coordinate scatter + leaf hash | 13 dispatches, one coordinate reread | subsumed |
| Fuse circle-to-line submission boundary | one tiny ~0.03 ms device stage plus host boundary | defer |
| Cache Objective-C plans/metadata | CPU allocation-only, unclear lifetime win | defer |
| Fold + next coordinates + next leaf | 25 wide/deep dispatches and memory traffic | select |

The initial design called for two eager Native entry points (initial
coordinates/leaves and fold/next-coordinates/leaves), so the authenticated core
shader ABI must advance rather than silently accepting an older metallib.
Source-JIT remains the production benchmark path on this host.  The exact
entry-point accounting is left to implementation and the editable-path gate;
AOT contract tests and hosted Metal compile remain mandatory.

Prediction: reduce wide/deep line-cascade device time by 0.25--0.55 ms and
end-to-end proof latency by at least 2% on one production class, with exact
roots, coordinate columns, terminal evaluation, channel state, proof bytes,
one command buffer/wait, and zero fallback.  Falsifiers are any prefix-hash
mismatch, next-tree root mismatch, missing coordinate value, Metal validation
error, authenticated-AOT contract failure, or clean paired interval crossing a
material regression.

## Implementation and mechanism check

The two existing eager core pipelines now own the producer boundary through
explicit ABI-3 modes.  The coordinate pipeline scatters each QM31 evaluation
into four planes and, in cascade mode, hashes that same in-register value into
its four-column leaf.  The line-fold pipeline always writes the next AoS
evaluation and, in prepare-next mode, simultaneously scatters and hashes it
into the next tree.  Plain modes preserve every existing standalone/prepared
caller; the terminal fold remains plain.  The host cascade therefore starts
each tree at its parent levels and retains the same coordinate buffers for
decommitment.

The widened kernels live in the modular commitment translation unit, not the
legacy shader file.  The authenticated core shader ABI advances from 2 to 3,
but the exact Native export inventory remains 78 and no out-of-scope AOT probe
edit is needed.  Old ABI-2 bundles fail closed.  Runtime source-JIT compiles the
same embedded amalgamation through `newLibraryWithSource`; no offline compiler
is present or needed on this machine.

Focused exact-parity tests compare every coordinate plane, Merkle root,
Fiat--Shamir challenge, and final evaluation against the unfused reference.
The five-layer fixture moved from 30 to 21 dispatches.  Full Debug proofs
matched all fixed digests and observed the predicted production topologies:

| class | line-cascade dispatches before -> after | warmed cascade GPU time |
| --- | ---: | ---: |
| small | 55 -> 38 | 1.72--1.86 ms |
| wide | 93 -> 68 | 2.83 ms, from 3.37--3.51 ms |
| deep | 93 -> 68 | frequency-sensitive, exact at every sample |

The wide device reduction is roughly 0.64 ms, exceeding the predicted ceiling.
The result still uses one command buffer, one compute encoder, and one terminal
wait; it is dispatch and coordinate-read elimination rather than hidden host
overlap.

## First-implementation diagnostic screen

Before freezing, seven alternating process pairs per class ran the real
ReleaseFast source-JIT product with ten warmups and seven independently
verified timed proofs per process.  This screen is intentionally labeled
diagnostic because the candidate worktree was dirty.  Every proof matched its
fixed digest, all 294 timed proofs verified and were byte-identical within
process, all samples classified accelerated-without-fallbacks, and total CPU
fallbacks were zero.

| class | predecessor median | candidate median | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small | 2.700 ms | 2.672 ms | 0.9896 [0.9762, 1.0024] | 5/7 |
| wide | 11.730 ms | 11.619 ms | 0.9921 [0.9758, 1.0091] | 4/7 |
| deep | 7.178 ms | 7.066 ms | 0.9844 [0.9778, 0.9914] | 7/7 |

The robust three-class geometric-mean ratio is 0.9887.  Device attribution and
seven unanimous deep wins justified retaining the architecture, while the wide
interval honestly records end-to-end thermal noise.  A first clean candidate
preserved the effect, but its two added exports required changing a hard AOT
count assertion outside the manifest's editable set.  The official control
caught that as G2 before submission.  The implementation was therefore
redesigned around the two widened existing entry points described above.  The
out-of-scope change was fully removed, all legacy callers were rebound, and no
favorable measurement from the rejected tree is used as final evidence.

## Final clean paired evidence

Final candidate `e20053d0dd90` and predecessor `cafbe2c8a71f` were independently
built from clean ReleaseFast worktrees.  Fifteen rounds per class alternated
A-B / B-A process order.  Every process used ten verified warmups followed by
seven timed independently verified proofs.  The reports were rejected unless
they named the exact commit, were clean and complete, used source-JIT, created
no post-warmup pipeline, matched the fixed digest, classified every sample as
accelerated-without-fallbacks, and reported zero CPU fallback.

| class | predecessor median | candidate median | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small | 2.694 ms | 2.655 ms | 0.9855 [0.9713, 0.9981] | 11/15 |
| wide | 11.718 ms | 11.575 ms | 0.9921 [0.9812, 1.0039] | 9/15 |
| deep | 7.139 ms | 7.105 ms | 0.9942 [0.9911, 0.9979] | 12/15 |

The robust suite geometric-mean ratio is 0.9906, about 0.94% less proof
latency.  Small and deep intervals exclude 1.0; wide is favorable but remains
neutral and is not overclaimed.  The first small round contains a large
baseline-first frequency-ramp excursion (5.162 vs 3.080 ms).  It is retained,
not pruned; the Hodges--Lehmann estimator and all bootstrap resamples see it.
Across the experiment all 630 timed proofs verified and stayed byte-identical.

Three final clean paired profiled rounds per large class locate the movement in
the selected stage.  Median FRI quotient/build/commit time fell 3.926 -> 3.836
ms on wide (2.3%) and 3.705 -> 3.672 ms on deep (0.9%).  Wide's FRI stage won
all three profile pairs and deep won two of three.  This is consistent with the
fixed 93 -> 68 dispatch topology and with a small whole-prover effect after the
earlier large synchronization and Merkle wins.

## Official controls

The enabled judge board is CPU-only, so fresh S3 controls measure no expected
Metal benefit.  All three pass G1--G5, the pinned Rust oracle, exact cross-arm
proof checks, editable-path policy, request budgets, and applicable guards:

- small: 1.0069 [0.9883, 1.0236], confirmed neutral;
- wide: 0.9909 [0.9700, 0.9976], below 1.0 but inside its dispersion threshold;
- deep: 0.9970 [0.9909, 1.0020], confirmed neutral.

These controls are not presented as Metal performance credit.  The claim above
comes from the real production Native Metal binary on the source-JIT path.

## Frozen validation

The final candidate passes the full Zig closure, Native Metal product closure and
device-only lifecycle, exact cascade parity test, runtime `metal-check`, source
conformance, authenticated-AOT compile and acceptance-probe suites, diff checks,
and a complete proof with both Metal API and GPU shader validation enabled.
The broad Metal suite remains 80/83: two expected skips and the same resident
policy assertion reproduced on the untouched predecessor.  Moving the kernels
out of the legacy shader file was required to retain the 850-line manual-source
ceiling; no conformance exception was added.  The aggregate frontier diff
touches only `src/backends/metal/**` and passes the submission editable-path
gate.
