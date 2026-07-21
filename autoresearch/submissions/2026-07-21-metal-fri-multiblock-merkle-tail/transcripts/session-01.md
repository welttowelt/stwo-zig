# Session 01 — sixth Metal-backend architecture campaign

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and fresh benchmark

PR #29 merged fold/coordinate/leaf producer fusion and the recorder advanced
canonical main to `6c622c60297d`.  The repo-resident CLI was updated to that
exact commit, a fresh isolated workspace passed `stwo-perf setup`, and the real
ReleaseFast Native Metal product was built before any source edit.

The complete fixed three-class Metal suite then ran with ten warmups and seven
timed verified samples per class on `--metal-runtime source-jit`:

| class | prove median | request median | logical Metal dispatch telemetry |
| --- | ---: | ---: | ---: |
| small `wf_log10x8` | 6.713 ms | 7.025 ms | 306 |
| wide `wf_log14x32` | 11.465 ms | 12.450 ms | 374 |
| deep `plonk_log14` | 7.084 ms | 7.405 ms | 408 |

Every report named clean complete commit `6c622c60297d`, used ReleaseFast,
matched its fixed proof digest, independently verified all samples, classified
accelerated-without-fallbacks, and reported zero CPU fallback.  The small
absolute latency is frequency-state sensitive, so architecture selection uses
the stage and device decomposition rather than that one process median.

## Fresh profile and physical residual

Seven-sample ReleaseFast profiles place the common residual as follows:

| stage median (ms) | small | wide | deep |
| --- | ---: | ---: | ---: |
| main trace commit | 0.919 | 1.779 | 0.652 |
| composition evaluation | 0.049 | 2.637 | 0.127 |
| composition interpolate/split | 0.033 | 0.481 | 0.054 |
| composition commit | 0.918 | 1.404 | 0.747 |
| sampled values | 0.411 | 0.806 | 0.665 |
| FRI quotient/build/commit | 3.188 | 3.865 | 3.656 |
| proof of work | 0.376 | 0.345 | 0.351 |
| all decommitment | 0.071 | 0.119 | 0.129 |

FRI remains the dominant common stage.  A fresh Debug source-JIT device run of
the merged wide cascade is stable at 3.138--3.177 ms, thirteen logical trees,
68 physical dispatches, one command buffer, one compute encoder, and one wait.
Small is 1.654--1.678 ms, nine trees, and 38 dispatches.  Device capabilities
queried through the repository Metal profiler are Apple M5 Max, 1,024 maximum
threads per threadgroup, 32,768 bytes threadgroup memory, unified memory, and a
55.66 GB recommended working set.

For wide/deep the 68-dispatch graph now consists of:

```text
14 producer/fold grids
  = initial [coordinates + leaves] + 12 [fold + next coordinates + leaves]
    + terminal fold
28 Merkle parent/tail grids
26 serialized transcript mix/draw grids
------------------------------------------
68 total
```

The thirteen trees have logs 14 down through 2.  The existing shallow-tail
kernel fuses the top of each tree once parent cardinality reaches at most 256,
but bottom parent levels still launch globally and reread just-written leaf or
parent hashes.  Coordinates and leaves must remain globally materialized for
decommitment; parent construction is the remaining legal locality boundary.

## Candidate architectures

| candidate | ceiling | risk / decision |
| --- | --- | --- |
| Remove intermediate AoS evaluations and fold from SoA coordinates | 12 buffers plus about 262 KiB read/write | useful but low byte ceiling; defer |
| Fuse only the first parent into each producer | 13 dispatches and leaf reread | safe but leaves four more global bottom levels on the largest tree |
| Full 256-leaf threadgroup-memory subtree | 22 dispatches and bottom-level traffic | 32 KiB scratch forces one resident group; reject occupancy risk |
| SIMDgroup-register microtrees plus tiny cross-subgroup reduction | 22 dispatches without large scratch | select |

The selected producer assigns one leaf to each lane.  A SIMDgroup retains its
eight-word leaf hash in registers and repeatedly gathers adjacent child hashes
with `simd_shuffle`, producing and globally storing every logical parent level
through a 32-leaf subtree.  Up to eight SIMDgroup roots occupy only 256 bytes
of threadgroup memory; the first subgroup reduces them to one 256-leaf block
root.  Thus a 256-thread producer writes levels 0 through 8 in one dispatch
while preserving the complete proof tree:

```text
folded QM31 lane value
  |-> four global coordinate planes (proof data)
  |-> global leaf hash            (proof data)
  `-> lane hash state
       -> shuffle-reduce levels 1..5 within each 32-lane SIMDgroup
       -> 8 subgroup roots in 256 B shared scratch
       -> first subgroup reduces levels 6..8
       -> global nodes at every level (proof data)
```

For logs 14 through 9, one existing top-tail dispatch finishes from the block
roots; logs 8 through 2 finish entirely inside their producer.  The predicted
wide/deep cascade is therefore:

| physical work | current | SIMD microtree |
| --- | ---: | ---: |
| producers/folds | 14 | 14 |
| parent/tail grids | 28 | 6 |
| transcript grids | 26 | 26 |
| total | 68 | 46 |

Small predicts 38 -> 30.  Compared with the pre-fusion 93-dispatch graph, this
would remove 47 grids.  It also replaces global reads between the bottom eight
Merkle levels with register shuffle or 256-byte shared-root traffic.

The implementation will widen the same two authenticated entry points again,
advance core shader ABI 3 -> 4, and keep the exact 78-export inventory.  Plain
coordinate/fold modes must bind the wider ABI and return before collectives;
tree mode dispatches full SIMDgroups.  The host derives a power-of-two block
width no larger than 256 or the reflected pipeline limit, so smaller Apple GPUs
remain valid.  Existing global-parent scheduling remains as a capability
fallback before the top tail if a pipeline cannot produce enough local levels.

Prediction: at least 0.15 ms less ReleaseFast FRI time and a significant
end-to-end win on one production class.  Falsifiers are any missing logical
layer node, root/challenge/final-evaluation mismatch, Metal validation error,
pipeline limit below one SIMDgroup, authenticated-AOT failure, dispatch count
above the capability-derived model, or clean paired regression.

## Rejected producer microtree experiment

The implementation widened the two existing producer kernels, retained a
capability fallback, materialized every logical Merkle node, and passed the
real source-JIT compiler plus the broad Metal suite at its unchanged 80/83
baseline (two expected skips and the known resident-policy assertion).  The
five-tree exact fixture moved from 21 to 16 dispatches and preserved every
root, transcript challenge, coordinate, and terminal evaluation.  Production
wide topology also matched the model at 46 dispatches with 256-thread blocks.

Device timing falsified the performance hypothesis.  The 256-thread producer
was about 3.36 ms versus a same-session frontier cascade around 2.88--2.94 ms.
Sweeping the capability cap exposed an occupancy knee: 32, 64, 128, and 256
thread choices produced 49, 48, 47, and 46 dispatches respectively, but even
the best 128-thread version remained roughly 3.0--3.3 ms in a direct thermal
countercheck.  Folding seven rounds of BLAKE parent work into the already
register-heavy fold/leaf pipeline costs more occupancy than the removed global
launches and traffic save.  The entire producer experiment is therefore
reverted and none of its favorable topology counts are used as improvement
evidence.

The failed result sharpens the next boundary: keep the producer pipeline
compact, and reuse the existing isolated parent-tail pipeline across multiple
independent bottom subtrees.  That kernel already reduces a 512-leaf tree from
global children through a 256-parent, 8 KiB threadgroup scratch without
bloating fold or leaf register allocation.  Adding only a threadgroup-position
base lets one dispatch process every 512-leaf block of a large tree; one final
tail then joins the block roots.  This is the same validated reducer, applied
at both the bottom and top of large trees rather than only once the whole level
fits one group.

## Selected multi-block parent-tail architecture

The parent-tail shader now includes its threadgroup position when addressing
the first global child level and every globally materialized destination
level.  Existing one-group users retain group zero and identical semantics.
The FRI cascade can therefore launch many independent bottom reductions with
the already-authenticated pipeline.  Each 128-thread group consumes a
256-leaf block, retains at most 128 parent hashes in 4 KiB of threadgroup
memory, writes all eight logical parent levels, and leaves one block root.  A
separate existing upper-tail dispatch joins all block roots.  Fold,
coordinate, and leaf pipelines are unchanged, avoiding the occupancy failure
above.

Bottom width and upper-tail capacity are intentionally asymmetric.  A device
profile sweep found 128 bottom threads better than 64 or 256; the upper tail
keeps its proven 256-thread capacity so shallow trees do not gain an extra
dispatch.  On this device, wide/deep line FRI moves 68 -> 58 dispatches while
small stays exactly 38.  The new exact log-10 fixture forces four independent
bottom groups, then checks every coordinate, layer root, transcript challenge,
and final evaluation against the CPU reference.  It reports the modeled 38
fixture dispatches and passes source-JIT execution.

An initial dirty ReleaseFast ABBA screen used ten verified warmups and seven
timed proofs per process.  Wide moved 11.695 -> 11.644 ms and 11.656 -> 11.438
ms across the two counterbalanced pairs.  A first deep pair moved 7.574 ->
7.374 ms (2.6%), while small was neutral at 6.023 versus 6.043 ms.  All 42
timed samples in this screen independently verified, were byte-identical
within each process, matched their fixed class digests, used source-JIT, and
reported zero fallback.  These dirty-tree numbers are mechanism screening,
not final verdict evidence.

The broad Metal suite remains at the frontier's 80/83 result: two expected
skips and the same pre-existing resident-policy assertion.  Native Metal
product/lifecycle, `metal-check`, source conformance, core-AOT contract tests,
and the AOT acceptance-probe contract all pass.  A complete proof also passes
with both Metal API validation and GPU shader validation enabled.  The final
change keeps the buffer ABI and exact export inventory unchanged; authenticated
AOT identity changes through the embedded shader-source digest, so no ABI
version or offline Metal compiler is required for this source-JIT run.

## Final clean paired Metal evidence

Final candidate `f01a645ad829` and exact predecessor `6c622c60297d` were built
independently from clean ReleaseFast worktrees.  Fifteen process pairs per
class alternated A-B / B-A order; every process used ten verified warmups and
seven timed independently verified proofs.  The complete 90-report audit found
the expected 45 reports per commit, clean complete provenance, source-JIT
admission, no post-warmup direct compilation, accelerated-without-fallbacks
classification, zero CPU fallbacks, and the fixed digest for each class.  All
630 timed proofs verified and remained byte-identical within each process.

| class | predecessor median | candidate median | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.660 ms | 2.632 ms | 0.9937 [0.9785, 1.0110] | 9/15 |
| wide `wf_log14x32` | 11.725 ms | 11.629 ms | 0.9946 [0.9867, 1.0049] | 11/15 |
| deep `plonk_log14` | 7.088 ms | 7.031 ms | 0.9915 [0.9856, 0.9959] | 13/15 |

The repository Hodges--Lehmann/bootstrap estimator gives a three-class
geometric-mean ratio of 0.99325, about 0.68% less proof latency.  Deep is the
confirmed class; small and wide are favorable but neutral and are not
overclaimed.  One small candidate-first round contains a large favorable
frequency excursion (ratio 0.553); it is retained rather than pruned, and the
robust estimator plus every bootstrap resample sees it.

The official autoresearch board is CPU-only, so its S3 deep control measures no
expected Metal credit.  Candidate `f01a645` versus predecessor `6c622c6`
passes G1--G5, locked-path policy, pinned Rust oracle, and exact proof checks at
0.9929 [0.9830, 0.9992] over seven rounds.  Its measured theta is 0.0183, so it
is correctly classified confirmed-neutral.  The claimed Metal improvement is
the clean device evidence above, not this CPU control.
