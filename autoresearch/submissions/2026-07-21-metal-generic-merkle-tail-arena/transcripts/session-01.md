# Session 01 — fourth Metal-backend architecture campaign

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and objective

PR #27 merged the shared FRI hash arena and threadgroup-local shallow Merkle
tails. The autoresearch recorder classified its CPU-only verdict neutral and
advanced the canonical frontier and repo-resident CLI to
`f81b2cc64f7f`. A fresh workspace passed `stwo-perf setup` and branch
`autoresearch/metal-epoch4` was created at that exact recorded commit.

The five repository skills remain active: algorithm matching, Metal
performance design plus the full compute common-pattern reference, Metal
profiling, Zig host profiling, and reasoning-first submission transcripts.
The preceding submission note/transcript is the immediate research prior.
No production source has been edited.

This iteration will first rerun all three production Native Metal shapes and a
fresh stage/device attribution. The leading candidates are a FRI-specific
kernel that fuses coordinate conversion, leaf hashing, and threadgroup parent
tails for late small trees, versus extending the resident epoch backward
through circle fold or quotient commitment. Selection waits on the new
frontier measurements and an exact dependency/resource map.

## Fresh frontier benchmark and residual attribution

The untouched recorded frontier was rebuilt as ReleaseFast source-JIT Metal
and run with ten warmups plus three timed, verified profiled samples per fixed
shape. Medians were 5.875 ms small, 12.141 ms wide, and 7.309 ms deep. Every
proof matched its fixed digest and reported zero fallback. FRI remains the
largest common stage at 3.204, 4.075, and 3.764 ms. Wide also spends 1.767 ms
in main trace commit and 1.701 ms in composition commit; deep spends 0.693 and
0.787 ms respectively.

Fresh Debug device attribution confirms the merged line cascade at 93
dispatches in one command buffer/wait. Wide settles around 3.2--3.5 ms for the
cascade, plus roughly 0.62--0.66 ms quotient/Merkle and 0.03--0.04 ms circle
fold. Deep device timestamps ramp sharply across early proofs, reinforcing the
need for clean alternating end-to-end verdicts rather than isolated readings.

## Candidate architecture comparison

The 93-dispatch cascade still performs coordinate conversion and leaf hashing
as separate grids for every tree. A fused kernel could reduce it to about 73
dispatches, but adding a new eager shader export requires advancing the core
Metal ABI and invalidating authenticated AOT libraries for a limited ceiling.
The earlier resident-cascade research explicitly removed a custom shader for
the same compatibility reason.

Source tracing exposed a broader mismatch. The quotient tree already uses an
offset-addressed arena and the vetted `blake2s_parent_tail_sparse` kernel, and
the line-FRI trees now do too. Generic main/composition commitments still use
one `MTLBuffer` and one parent grid per logical level even though they invoke
the same hashes:

```text
current generic commitment
leaves -> buffer L0 -> dispatch -> buffer L1 -> ... -> buffer root
          (log+1 buffers, log parent dispatches)

selected generic commitment
leaves -> [L0 | L1 | ... | root] aligned shared arena
          large grids -> one <=256-parent threadgroup tail
          (one buffer, about six parent dispatches at log 14)
```

| Candidate | Scope/effect | Compatibility | Decision |
| --- | --- | --- | --- |
| New coordinate+leaf(+tail) shader | line FRI, ~20 dispatches | core shader ABI bump | defer |
| Fuse circle submission into line cascade | one wait/command boundary | generic FRI hook/ownership work | defer |
| Alias quotient root readback on UMA | one tiny blit/allocation | no ABI change, small ceiling | follow-up |
| Extend packed Merkle arena/tail to generic commits | main, composition, fallback FRI trees | reuses authenticated kernels/ABI | select |

The selected change is a data-layout/scheduling optimization, not a hash or
protocol change. All logical levels remain available through the existing tree
offset metadata used by root reads, full layer copies, selective hash reads,
batch decommitment, and destruction. On the target Apple unified-memory GPU,
the predecessor already chooses shared storage for every separate level; one
shared arena changes object granularity, not storage mode. Non-unified devices
retain a private arena plus an explicit 32-byte root readback.

Prediction: cut each production log-14/15 generic tree from 14/15 parent grids
and 15/16 hash buffers to roughly six parent grids and one arena. Main and
composition commit stages should fall by 8--20%, producing at least a 2%
end-to-end wide/deep win with exact roots/proofs and no fallback. Falsifiers
are any copy/decommit offset mismatch, non-unified root visibility failure,
new shader/AOT ABI requirement, or clean paired interval crossing regression.

## Implementation and first falsification pass

The generic commitment runtime now lays all logical Merkle levels into one
256-byte-aligned word-addressed arena.  The immutable tree handle points every
logical level at that arena and carries the existing per-level offsets and
lengths, so root reads, full-layer copies, selective reads, and batched
decommitment retain their public behavior.  Large parent levels use the
existing sparse grid kernel; the first eligible shallow level enters the
already-authenticated threadgroup-local parent-tail kernel.  A one-leaf tree
retains a leaf-only path.  On non-unified devices the arena is private and an
explicit 32-byte root copy remains.

The same ownership analysis exposed one remaining redundant UMA operation in
the already-packed quotient tree: it copied the root from a shared arena into
a second 32-byte shared buffer.  The shared-device path now retains the arena
directly and records the root word offset, while the private-device fallback
is unchanged.  Neither change touches MSL, shader exports, the core shader ABI,
hash definitions, transcript order, proof format, or generic prover code.

The first Debug build produced exact independently verified fixed proofs for
small, wide, and Plonk with zero fallback.  Metal API and GPU validation were
then enabled together for a complete small proof and reported no error.  A
mistaken diagnostic invocation reused the installed Debug product after a
ReleaseFast test step; its provenance said `Debug`, so those apparent stage
numbers were discarded before any performance conclusion.

An explicit ReleaseFast rebuild showed wide main commitment at 1.706 ms versus
the fresh 1.767 ms frontier reading and composition commitment at 1.387 ms
versus 1.701 ms; proof time was 11.704 versus 12.141 ms.  Temperature drift
made independent small/deep process medians unsuitable, so four alternating
process pairs per class were run with ten warmups and seven timed verified
proofs per process.  Before the quotient-root cleanup, candidate wins were
4/4 wide, 4/4 small, and 3/4 deep.  After that cleanup, a second four-pair wide
screen again won 4/4, with candidate medians 1.0--2.8% below their adjacent
predecessors.  Every diagnostic proof matched its fixed digest and reported
zero CPU fallback.  This clears the threshold for a clean, committed,
promotion-grade paired experiment; the diagnostic numbers themselves are not
the verdict.

At the freeze candidate, `zig build test`, `test-native-metal`, `metal-check`,
and the broad `metal-test` closure complete successfully.  Allocation failure
checks occur before inserting the arena into Objective-C arrays, and the
private-device root copy remains compile-covered even though this Apple GPU
can execute only the unified-memory branch.

## Frozen clean-commit Metal verdict

The production change was frozen as `4dd2b795fea1` (`metal: pack generic
Merkle commitment arenas`) against recorded predecessor `f81b2cc64f7f`.  The
transcript was stashed and both exact checkouts were rebuilt as clean
ReleaseFast products.  A first formal wide pass revealed that product
provenance is discovered from the process working directory: launching both
binaries from the candidate checkout labeled both arms with the candidate
commit.  Although the binaries and timings were distinct, that pass was
rejected.  Every accepted process below ran with its own checkout as cwd and
reported the expected exact commit, `git_dirty=false`, `complete=true`, and
`ReleaseFast`.

Seven round pairs per class alternated A--B / B--A process order.  Each arm
used ten verified warmups and seven timed verified proofs.  Applying the
repository's round-median Hodges--Lehmann estimator and a deterministic
100,000-resample percentile bootstrap (seed 20260721) gives:

| Metal class | predecessor median | candidate median | B/A HL (95% CI) | paired wins |
| --- | ---: | ---: | ---: | ---: |
| small, `wf_log10x8` | 2.687 ms | 2.709 ms | 0.9949 [0.7840, 1.0458] | 5/7, neutral |
| wide, `wf_log14x32` | 11.936 ms | 11.800 ms | 0.9845 [0.9589, 0.9970] | 6/7, confirmed |
| deep, `plonk_log14` | 7.258 ms | 7.135 ms | 0.9812 [0.9270, 0.9899] | 7/7, confirmed |

The three-class geometric-mean ratio is 0.9869, about 1.31% less proof
latency.  Wide and deep independently clear one; small is not overclaimed.
Small's interval reflects two opposite cold-state excursions in its first two
pairs (ratios 0.569 and 1.097), which the robust location estimator contains
without deleting data.  Wide's confirmed estimate is a 1.55% reduction and
deep's is 1.88%.

All 294 formal timed proofs independently verified, were byte-identical within
each process, matched the fixed digest across arms and rounds, reported
`accelerated_without_fallbacks`, and used zero CPU fallbacks.  The hashes are
`91741aec...bea5700` small, `57a7d291...0f3374` wide, and
`d63a2c92...69dbaf` deep.

Three clean alternating profiled pairs per production-sized class tied the
result to the intended path.  On deep, median main Merkle time moved
0.419 -> 0.390 ms, total main commit 0.680 -> 0.650 ms, and composition commit
0.777 -> 0.744 ms.  Sampled evaluation remained 0.662 -> 0.662 ms, while FRI
varied only 3.778 -> 3.773 ms.  The source schedule explains the mechanism:
a log-14 generic tree now uses five large parent grids plus one shallow-tail
dispatch rather than fourteen parent grids; log-15 uses six grids plus one
tail rather than fifteen.  Each tree also uses one arena rather than 15 or 16
hash buffers.  Wide stage timers were noisier, but its clean end-to-end CI and
six paired wins confirm that the same shared generic path produces a net gain.

Frozen validation passes `zig build test`, `test-native-metal`, `metal-check`,
`metal-test`, `source-conformance`, both authenticated-AOT core compile/probe
contract tests, exact full-proof verification, diff checks, and a complete
proof with both Metal API and GPU shader validation enabled.  No MSL or shader
ABI changed, and runtime source-JIT compilation remains outside post-warmup
samples.

The manifest still has no enabled Metal scoring group, so official S3 runs are
CPU no-regression controls rather than the performance claim.  All three pass
G1--G5, the pinned Rust oracle, cross-arm digests, request/RSS budgets, and the
impact-mapped guards: small 1.0134 [1.0020, 1.0350], wide 1.0102
[0.9993, 1.0231], and deep 1.0008 [0.9934, 1.0106].  Each is classified
confirmed-neutral under its measured threshold.
