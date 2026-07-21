# Session 01 — bounded M31 reduction across CPU and Metal

## Objective and frontier

The continuing autoresearch goal requires every new source submission to move
CPU and Metal together. PR #37 landed the shared circle-basis optimization;
because validation permits only one verdict per workload class in a package,
PR #38 immediately recorded its already-measured CPU-wide verdict separately.
Both are promoted. The canonical repository-resident CLI was then updated to
recorded main `81712fa`, preserving two pre-existing untracked notes, and a
clean `dual-02` workspace was created from that exact frontier.

All repository skills remain binding: transcript capture, problem matching,
CPU live-code profiling, real-device Metal profiling, and the Metal
performance-design resource/ownership/dispatch framework. This session targets
one mathematical mechanism implemented in both backends rather than combining
unrelated wins.

## Fresh benchmark and stage attribution

`stwo-perf setup` rebuilt the enabled Native CPU and Native Metal ReleaseFast
products; RISC-V remains explicitly disabled by policy. Ten verified timed
samples after ten warmups produced representative medians:

| board/class | prove ms | request ms | proof / telemetry |
| --- | ---: | ---: | --- |
| CPU small | 1.534 | 1.699 | `91741aec...bea5700` |
| CPU wide | 10.228 | 11.227 | `57a7d291...0f3374` |
| CPU deep | 6.598 | 6.920 | `d63a2c92...b69dbaf` |
| Metal wide | 9.110 | 10.072 | 22 dispatches, zero fallback |
| Metal deep | 4.773 | 5.101 | 24 dispatches, zero fallback |

Metal-small varied strongly between repeated processes and is diagnostic only
until paired. Profiled wide/deep medians show the remaining shared host ceiling:

| stage | CPU wide | Metal wide | CPU deep | Metal deep |
| --- | ---: | ---: | ---: | ---: |
| composition evaluation | 2.627 | 2.484 | 0.123 | 0.135 |
| FRI build + commit | 3.375 | 1.986 | 3.217 | 1.638 |
| main trace commit | 1.941 | 1.877 | 0.976 | 0.657 |
| composition commit | 1.068 | 1.453 | 0.434 | 0.745 |

Intra-component row parallelism was considered first: wide Fibonacci is one AIR
component, so the existing component-level pool cannot fan it out. The row loop
lives in locked example code and its type-erased prover callback exposes only a
whole-domain operation. Retrofitting a row-range vtable would touch locked core
AIR/derive and example files; guessing the component from trace shape would be
semantically unsound. That architecture is therefore rejected under the
editable-surface contract, not merely deferred for implementation difficulty.

## Problem match — bounded Mersenne reduction

The next candidate is exact bounded modular reduction, not a new field
algorithm. Let `p = 2^31 - 1` and canonical operands satisfy `0 <= a,b < p`.
For `x = a*b`, `x < p^2 < 2^62`. One Mersenne fold
`t = (x & p) + (x >> 31)` therefore satisfies `0 <= t < 2p`; a single
conditional subtraction maps it canonically into `[0,p)`. The same `<2p`
bound holds directly for `a+b`.

Current CPU scalar, fixed-Vec4, and native-packed multiplication perform a
second fold. Current Metal sends both addition and multiplication through a
generic two-fold 64-bit reducer. The intended dataflow is:

```text
canonical a,b
     |
     +-- add --------------------------> s in [0,2p)
     |                                  |
     |                                  +--> subtract p iff s >= p
     |
     +-- 64-bit product --> one fold --> t in [0,2p)
                                        |
                                        +--> subtract p iff t >= p
```

The generic `M31.fromU64` reducer retains two folds because it accepts arbitrary
`u64`; only operations with the proven operand bound use the specialized path.
Aliasing, storage layout, canonical representation, operation order, public
ABI, command buffers, dispatch counts, and pipeline identities are unchanged.
Counterexamples considered: noncanonical operands would violate the proof, so
all constructors and shader call sites must retain canonical invariants; the
generic reducer remains available at arena boundaries that may contain wider
values.

## Baseline isolated evidence and Metal design

A live-module `stwo-prof zig` harness performs four scalar M31 products plus one
four-coordinate QM31-by-M31 product per iteration. Fifteen rounds measured
0.8612 ns, 10.51 instructions, and 3.906 cycles per base-field product, IPC
2.692. Assembly for `_workload.run` contains the expected second `and` plus
shift/add fold in each scalar and vector path; the hot symbol is 161
instructions with 29.2% NEON.

A real Apple M5 Max Metal isolation runs 32 dependent multiply-add pairs per
thread over a 1,048,576-element grid, 256 threads per group, with no threadgroup
memory and PSO width 32 / maximum 1024 threads. GPU frequency ramping displaced
early runs (0.877 ms then 0.373 ms median), so final attribution will use
interleaved repeated baseline/candidate runs, not the first absolute number.

Metal design classification: compute-bound integer field arithmetic; no new
resources, allocations, transfers, waits, encoders, or dispatches. Lifetime and
ownership are unchanged. The mechanism removes one 64-bit fold per multiply and
all 64-bit reduction work from canonical addition. The falsifier is unchanged
GPU/stage time, any proof mismatch, a canonicality failure at boundary tests, or
an end-to-end regression on either board.

## Implementation and first integrated result

The CPU keeps its generic arbitrary-`u64` reducer and adds bounded scalar,
fixed-Vec4, and native-packed product reducers. `M31.mul`, `mulVec4`, and
`mulPacked` route only canonical products through them. Edge products and 4,096
random canonical pairs match the generic reducer. The Metal header leaves
`m31_reduce` unchanged for arena/boundary normalization, implements canonical
addition with a 32-bit sum/subtract, and implements canonical multiplication
with one fold/subtract.

Live-code CPU ABBA against the untouched canonical module measured 0.864 ->
0.673 ns/product, ratio 0.7722 with 95% CI [0.7632, 0.7796]. Instructions fell
to ratio 0.7384 and cycles to 0.7734; the hot symbol shrank from 161 to 138
instructions. Interleaved real-device Metal isolation, after frequency warmup,
stabilized near 0.184 ms baseline versus 0.0865 ms candidate for the same grid
and PSO, about a 53% kernel reduction.

Core tests and both ReleaseFast products compile. Ten-sample diagnostic proof
medians, still unpaired, moved as follows while retaining exact proof hashes:

| board/class | frontier ms | candidate ms | diagnostic change |
| --- | ---: | ---: | ---: |
| CPU wide | 10.228 | 9.408 | -8.0% |
| Metal wide | 9.110 | 8.753 | -3.9% |
| CPU deep | 6.598 | 6.281 | -4.8% |
| Metal deep | 4.773 | 4.683 | -1.9% |

Candidate CPU-wide profiling attributes composition evaluation at 1.812 ms
versus 2.627 ms before the change, and FRI build/commit at 3.006 versus 3.375
ms. Metal profiling is heavily perturbed by instrumentation and GPU frequency,
but its shared host composition stage moved from 2.484 to about 1.88 ms. The
uninstrumented Metal result and isolated GPU timer are the reliable device
signals. Dispatches remain 22/24 for wide/deep with zero CPU fallbacks.

During this work the user reported that a fresh `stwo-perf update` restores
CPU+Metal verdicts for the same class in one package. Canonical update advanced
to `1b9a455`; the packager accepts board-qualified pairs, though that checkout's
validator still visibly contains the previous class-only duplicate check. A
second update will be run before packaging so the next result stays paired if
the central fix has finished propagating.

## Correctness closure and official wide verdicts

The bounded reducers passed the 70-source core suite, the 152-source prover
suite, the 190-source native CPU product suite, device-only Metal prove plus an
independent verifier, Metal AOT compile/probe checks, formatting, and source
conformance. The broad Metal suite passed 81/84 cases with two documented skips
and one resident-FRI coordinate-conversion failure. Repeating that exact case
on untouched canonical `1b9a455` produced the same failure on this M5 Max, so it
is a pre-existing platform result rather than a candidate regression. Native
Metal source-JIT proofs retain exact hashes, expected dispatch counts, and zero
fallbacks.

The first official CPU-wide attempt is discarded as contaminated evidence. It
reported R=0.945575 with CI [0.852412, 1.043388], while round ratios ranged from
roughly 0.40 to 1.19. Immediately afterward a separate RISC-V compiler process
was observed consuming over 1,300% CPU, consistent with the pathological
pairing noise. No process was interrupted; the CPU verdict was repeated only
after that load ended.

Stable S3 ABBA verdicts from candidate `edc13e90191d`, predecessor
`1b9a45598e43`, and harness `f97aa4a99086` are:

| board/class | A median ms | B median ms | R | 95% CI | request ratio | result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| CPU wide | 10.256875 | 9.459292 | 0.918152 | [0.905943, 0.934447] | 0.912003 | significant |
| Metal wide | 9.184417 | 8.251084 | 0.892766 | [0.870556, 0.913055] | 0.880346 | significant |

Both use 15 paired rounds; all G1-G5 gates pass, the pinned Rust oracle passes,
and the cross-arm proof digest is exactly
`57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`.
This is an 8.18% CPU proof-time reduction and a 10.72% Metal proof-time
reduction from one shared mathematical specialization.

The remaining classes were then measured rather than inferred:

| board/class | A median ms | B median ms | R | 95% CI | request ratio | result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| CPU deep | 6.609500 | 6.321750 | 0.952484 | [0.944310, 0.960579] | 0.960753 | significant |
| Metal deep | 4.812417 | 4.707875 | 0.970098 | [0.955852, 0.984097] | 0.977829 | significant |
| CPU small | 1.536500 | 1.430458 | 0.934054 | [0.917693, 0.951611] | 0.950118 | significant |
| Metal small | 2.564042 | 2.544500 | 0.988809 | [0.964024, 1.011500] | 0.995217 | neutral evidence |

All runs pass G1-G5 and the pinned oracle. Deep shares proof digest
`d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`;
small shares proof digest
`91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`.
The submission should claim five significant rows: CPU small, CPU+Metal wide,
and CPU+Metal deep. Metal small remains in the transcript as a measured neutral
result and must not be promoted as a significant claim.

## Paired-verdict policy closure

The first five-verdict package proved that the refreshed submitter already
deduplicated by `(board, workload class)` and emitted board-qualified Metal
filenames. The repository PR validator nevertheless still deduplicated only by
class, rejecting the real package with exactly two findings: duplicate `wide`
and duplicate `deep`. This was a policy implementation split, not a benchmark
or package-content failure; all focused submission tests passed.

The missing half was isolated in governance PR #39. PR validation now calls the
submitter's already-tested `check_claimed_verdicts` helper, making packaging and
PR validation share one policy source. CLI and schema wording now describe
board/class pairs. The pending real five-verdict package passed the corrected
validator. After validation and focused CI were green, PR #39 merged as
`9efa1dba071440ab41820e1c04216ec6b422117f`.

To keep formal bindings exact, the optimization was not submitted with its old
identities. A fresh branch from `9efa1dba` cherry-picked only the two editable
source files, producing candidate `a16249f`. Both predecessor and candidate
native CPU/Metal products were rebuilt successfully. The source diff and its
mathematics are byte-for-byte unchanged; official paired verdicts are rerun
below against the corrected frontier before repackaging.

The corrected-frontier rerun uses candidate `a16249f27872`, predecessor
`9efa1dba0714`, and harness `becd88e4944a`. Every run passes G1-G5, exact
cross-arm proof comparison, and the pinned oracle:

| board/class | A median ms | B median ms | R | 95% CI | request ratio | result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| CPU small | 1.511209 | 1.417666 | 0.936051 | [0.907390, 0.959173] | 0.947688 | significant |
| Metal small | 2.505917 | 2.436791 | 0.965743 | [0.944044, 0.987941] | 0.967833 | significant |
| CPU wide | 10.344041 | 9.660250 | 0.923793 | [0.909715, 0.947753] | 0.915524 | significant |
| Metal wide | 8.911667 | 7.814709 | 0.866114 | [0.844814, 0.883687] | 0.856497 | significant |
| CPU deep | 6.691500 | 6.292166 | 0.943371 | [0.923037, 0.955130] | 0.945990 | significant |
| Metal deep | 4.777625 | 4.627625 | 0.960649 | [0.919915, 0.980512] | 0.960284 | significant |

Unlike the earlier Metal-small process result, the final 15-round paired
Metal-small CI is wholly below one. The final package can therefore claim all
six board/class rows, exactly matching the shared CPU+Metal mechanism and the
new validator policy.
