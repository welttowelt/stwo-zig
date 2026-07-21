# Session 01 — seventh Metal-backend architecture campaign

Date: 2026-07-21
Model: GPT-5 Codex

## Frontier and fresh local grounding

The recorder advanced canonical main to `35819ff7920d` after PR #30 merged the
multi-block FRI Merkle tail.  Before editing source, the repository CLI was
updated to that exact frontier, a fresh isolated workspace passed setup, and a
real ReleaseFast Native Metal product was built with the macOS runtime
source-JIT path.  Ten warmups and seven verified timed samples gave:

| class | prove median | request median |
| --- | ---: | ---: |
| small `wf_log10x8` | 6.693 ms | 6.964 ms |
| wide `wf_log14x32` | 11.737 ms | 12.670 ms |
| deep `plonk_log14` | 7.038 ms | 7.368 ms |

All samples were exact, independently verified, source-JIT admitted, and
fallback-free.  Fresh profiled wide/deep runs locate the remaining commitment
cost as follows:

| stage median (ms) | wide | deep |
| --- | ---: | ---: |
| main trace commit | 1.838 | 0.652 |
| main commit's Merkle child | 0.745 | 0.389 |
| composition evaluation | 2.594 | 0.127 |
| composition interpolate/split | 0.479 | 0.062 |
| composition commit | 1.558 | 0.756 |
| sampled values | 0.810 | 0.660 |
| FRI | 3.794 | 3.638 |

PR #30 demonstrated that the isolated `parentTailSparse` pipeline can reduce
many independent bottom subtrees in one grid without the occupancy regression
of producer fusion.  The generic main/composition commitment path still emits
one encoder and grid for each bottom parent level, then one top-tail grid.

## Selected generic multi-block architecture

Extend the prepared generic `StwoZigMerkleParentChain` plan with a capability-
and-layout-derived bottom segment.  On this device, each 128-threadgroup owns
256 initial child hashes, writes eight complete logical parent levels to their
existing global destinations, and leaves one block root.  The existing upper
tail then joins the block roots:

```text
separate arena levels, large tree

leaf hashes ──┬─ TG 0: 128 -> 64 -> ... -> 1 ─┐
              ├─ TG 1: 128 -> 64 -> ... -> 1 ─┤
              ├─ ...                           ├─ upper tail -> root
              └─ TG N: 128 -> 64 -> ... -> 1 ─┘

old:  global L0 -> global L1 -> ... -> global L7 -> top tail
new:  one concurrent bottom grid                         -> top tail
```

For a normal log-14 direct commitment this predicts six physical Merkle
parent grids becoming two.  Main trace and composition each use the same
prepared chain, so a wide proof should remove about eight launch boundaries
without changing the leaf pipeline, node layout, proof data, shader exports,
or public ABI.

The critical correctness constraint is cross-threadgroup aliasing.  Metal has
no global barrier inside a grid: if a destination overlaps the initial child
range, one group could overwrite leaves another group has not loaded.  The
bottom segment is therefore enabled only when:

1. the first parent count exceeds the ordinary top-tail capacity;
2. at least eight exact halving levels exist for a 128-parent local cascade;
3. every bottom output level has a pairwise-disjoint arena range;
4. every bottom output range is disjoint from the complete initial child
   range; and
5. the first global count is an exact multiple of the local width.

Direct main/composition commitments allocate a distinct range per level and
qualify.  Ping-pong and overlapping recipe layouts fail closed to their
current per-level schedule.  Shallow trees are deliberately unchanged.

Prediction: exact roots and every materialized node remain unchanged; large
direct chains report two parent dispatches, production proof telemetry drops,
and at least one wide/deep class improves materially.  Falsifiers are a Metal
validation error, any node/root/proof mismatch, changed shallow topology,
activation on aliased storage, or same-session/counterbalanced latency loss.

## Implemented schedule and first measurements

Plan preparation now records a bottom level count, local width, group count,
and scratch requirement only after the five geometry checks above pass.  The
existing source-JIT shader needs no ABI or source change because PR #30 already
made its first global read and every global write group-relative.  A stack
array substitutes local counts `128, 64, ..., 1` while the plan retains global
counts for validation and arena bounds.

The generic chain was also brought into the same encoder model as the FRI
cascade.  Bottom, any conservative global middle, and the top tail share one
compute encoder with explicit `MTLBarrierScopeBuffers` barriers.  The direct
commitment's leaf grid joins that encoder too, with a barrier before the first
parent read.  Thus a normal large direct commitment changes from:

```text
leaf encoder | P0 encoder | P1 | P2 | P3 | P4 | top-tail encoder
```

to:

```text
leaf grid -> buffer barrier -> multi-group bottom grid -> barrier -> top tail
<--------------------------- one compute encoder --------------------------->
```

The strengthened 2,048-leaf source-JIT fixture reports one compute encoder and
two parent dispatches, and compares all eleven globally materialized layers
against scalar Blake2s.  A second pass deliberately ping-pongs through the
initial leaf range.  It rejects the concurrent bottom schedule, retains nine
barrier-separated global grids plus its safe two-level top-tail grid, and
matches the same root.  The broad Metal suite remains at its known 80/83
frontier baseline: two expected skips and the pre-existing resident-policy
assertion are unchanged.

Full-proof A/B screening is frequency noisy in wide because composition
evaluation and FRI dominate, but deep is favorable in every six-pair screen.
An isolated production `commitColumns` measurement removes that confounder.
Each process creates the real source-JIT runtime, discards five commits, and
measures the next 96 log-14 commitments:

| commitment | frontier GPU median | candidate GPU median | change |
| --- | ---: | ---: | ---: |
| 32 columns (wide main-trace geometry) | 0.091 ms | 0.077 ms | -15.4% |
| 4 columns (composition geometry) | 0.076 ms | 0.062 ms | -18.4% |

The corresponding candidate wall medians are 0.449 and 0.307 ms, versus 0.465
and 0.345 ms in the counterbalanced frontier processes.  Earlier cold process
outliers are retained rather than silently pruned; the table uses the second
counterbalanced pair after both orders had warmed the device.  Exact roots are
stable in every repetition.  This mechanism result and the consistently
favorable deep proof class are sufficient to advance to clean validation and
submission; wide end-to-end movement will not be overclaimed.

## Clean end-to-end evidence and controls

Candidate `03ec753d0232` and predecessor `35819ff7920d` were built in separate
clean worktrees.  An initial 90-report attempt was discarded before use
because both binaries were launched with the dirty research workspace as the
process current directory; runtime provenance correctly marked the reports
dirty even though the executable files came from clean builds.  The complete
suite was rerun with each process rooted in its owning clean worktree.

Fifteen process pairs per class alternated A-B / B-A order.  Every process used
ten verified warmups and seven timed verified proofs.  The corrected audit has
90 reports, exactly 45 per commit, and no provenance error.  All 630 timed
proofs independently verified, remained byte-identical within each process,
matched the fixed cross-arm class digest, used source-JIT admission, reported
`accelerated_without_fallbacks`, had zero CPU fallback, and performed zero
post-warmup direct compilation.

| class | predecessor median | candidate median | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.689 ms | 2.651 ms | 0.99005 [0.98088, 0.99723] | 12/15 |
| wide `wf_log14x32` | 11.578 ms | 11.518 ms | 0.99574 [0.98490, 1.00467] | 9/15 |
| deep `plonk_log14` | 7.026 ms | 6.997 ms | 0.99609 [0.99098, 0.99934] | 9/15 |

The repository Walsh-average Hodges--Lehmann estimator and deterministic
bootstrap give a three-class geometric-mean ratio of `0.993954`, about 0.60%
less end-to-end proof latency.  Small and deep are confirmed favorable; wide
is favorable but neutral and is not overclaimed.  The first small pair has a
large favorable ratio of 0.517, consistent with the known small-workload GPU
frequency ramp.  It is retained, disclosed, and handled by the robust
estimator rather than pruned.

Validation passes the Native Metal ReleaseFast build and lifecycle, independent
proof verification, `metal-check`, source conformance, core-AOT tooling tests,
and the authenticated-AOT acceptance-probe contracts.  The broad device suite
is unchanged at 80/83: two expected skips and the pre-existing resident-policy
assertion.  A complete Plonk proof passes with both Metal API Validation and
Metal GPU Validation explicitly enabled.  No shader source or export changed;
the macOS runtime still compiles the embedded MSL through source-JIT, while the
host-runtime identity correctly incorporates the Objective-C scheduler change.

The required official `core_cpu` S3 deep control passes G1--G5 and the pinned
Rust oracle over fifteen paired rounds.  It measures 1.0043 [0.9952, 1.0122]
against theta 0.0183 and is correctly confirmed-neutral.  The current manifest
still has no enabled `core_metal` workload, so the claimed improvement is the
clean production Metal evidence above; no Metal verdict or locked benchmark
change is fabricated.
