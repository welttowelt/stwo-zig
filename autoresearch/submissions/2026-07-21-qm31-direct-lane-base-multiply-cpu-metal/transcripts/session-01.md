# Session 01 — corrected QM31 throughput on CPU and Metal

## Objective and corrected frontier

The continuing objective is one source change that materially improves both
Native CPU and Native Metal, followed immediately by a paired submission and a
green PR. The user had paused while a proof-correctness failure was repaired on
main. Work resumed only after that repair landed.

The repository-resident CLI was updated first. Corrected main is
`1c3f3ca758d11`, containing `a156e71` (restore correct QM31 arithmetic),
`e694a34` (production-proof gate), and `1c3f3ca` (isolate pre-push tests from
hook Git state). Full upstream CI for that frontier is green. Clean candidate
and predecessor worktrees were created at that exact commit and both Native
CPU and Native Metal ReleaseFast products were rebuilt. A final fetch before
packaging confirmed that `origin/main` had not moved.

Two pre-existing untracked research notes in the canonical checkout were
preserved across the update and were not modified.

## Fresh benchmark grounding

Ten verified samples after ten warmups established the post-correctness
frontier:

| board/class | prove ms | request ms | proof / telemetry |
| --- | ---: | ---: | --- |
| CPU small | 1.922 | 2.151 | `91741aec...bea5700` |
| CPU wide | 11.882 | 12.704 | `57a7d291...0f3374` |
| CPU deep | 6.263 | 6.602 | `d63a2c92...b69dbaf` |
| Metal small | 3.428 | 3.649 | 18 dispatches, zero fallback |
| Metal wide | 10.594 | 11.392 | 22 dispatches, zero fallback |
| Metal deep | 4.680 | 5.002 | 24 dispatches, zero fallback |

All 60 samples verified and were byte-identical. Metal used embedded MSL
source JIT through `newLibraryWithSource`; backend initialization and shader
compilation were outside the timed samples.

The correctness repair produced a useful natural experiment. Relative to the
previous promoted source, small and wide slowed sharply while deep remained
nearly flat. The changed code replaced vectorized QM31 add/sub/base-multiply
with two scalar CM31 operations and removed private QM31-to-Vec4 conversion
helpers.

## Stage profiles and bottleneck visualization

Five-sample ReleaseFast stage profiles localized nearly the entire wide loss to
shared host composition evaluation. GPU dispatch counts and the remaining
Metal stages were stable.

```text
CPU wide composition       2.23 ms before fix |███████████
                            4.63 ms corrected  |███████████████████████

Metal wide composition     2.34 ms before fix |████████████
                            5.13 ms corrected  |██████████████████████████

Other major stages         approximately flat
```

On the corrected CPU frontier, composition was about 4.6 ms, FRI quotient
build/commit about 3.0 ms, and main-trace commit about 1.8 ms. On the Metal
product, composition was about 5.1 ms and had become larger than any GPU-owned
stage. This established the highest-leverage Metal-product target as a shared
host field kernel rather than another shader dispatch.

## Architecture search

Three designs were evaluated.

1. Pack independent wide-Fibonacci rows in the example component. This gives a
   clean structure-of-arrays kernel and avoids aggregate conversion entirely,
   but `src/examples/**` is outside the editable manifest. Adding a type-shaped
   special case in the generic component prover would be unsound, so this path
   was rejected.
2. Restore the old private `toVec4(self: QM31)` helper. This recovers speed but
   recreates the exact optimized by-value aggregate copy implicated by the
   correctness repair. The new log-10 point-evaluation tests exist to cover
   that failure mode, so this design was rejected without submission.
3. Extract the four scalar fields directly inside a consuming operation, feed
   those scalars to the established Vec4 M31 primitive, and reconstruct the
   result directly from lanes. This retains SIMD while eliminating the
   intermediate QM31 aggregate-copy helper.

The chosen design is deliberately narrow:

```text
QM31 lhs (already in caller registers / fields)
  |-- c0.a.v --\
  |-- c0.b.v ---+--> Vec4u32 --> bounded mulVec4(rhs splat) --> four lanes
  |-- c1.a.v ---+                                             | | | |
  |-- c1.b.v --/                                              v v v v
  +------------------------------------------------------ canonical QM31

There is no: QM31 by-value copy --> conversion helper --> vector.
```

The mathematical invariant is simple. For canonical limbs `x_i` and canonical
base scalar `r`, every output lane is independently
`reduceProduct(x_i * r)`. The existing scalar `QM31.mulM31` computes the same
four products through two CM31 calls. Lane order, reduction, and
canonicalization are unchanged.

## Isolation and narrowing

The first experiment vectorized only `mulM31`. The 152-source prover closure,
including the new high-block subset-product and evaluation tests, passed in
ReleaseFast. A quick CPU-wide run moved from about 11.88 to 9.43 ms with the
exact fixed proof hash. The Metal composition stage moved from about 5.13 to
2.54 ms with 22 dispatches and zero fallback.

For diagnosis, direct-lane forms of QM31 add and sub were then enabled as well.
All correctness tests still passed, but they produced no additional target
gain. The first full Metal verdict on that broader experiment had a strong
wide objective, R=0.7623, while one noisy Poseidon guard had R=1.0309 with a
wide confidence interval crossing the 1.05 budget. Regardless of whether that
guard was noise, generic add/sub broadened the semantic and performance
surface without reward. Those changes and all verdicts bound to that commit
were discarded.

The final patch restores scalar add/sub and changes only `mulM31`: 11 inserted
lines and 3 removed lines in `src/core/fields/qm31.zig`. Its live
wide-Fibonacci function disassembly contains `umull.2d`, `umull2.2d`, and
`uzp1.4s`, confirming that the intended four-lane widening survived inlining.
Fresh profile medians measured composition at 2.21 ms on CPU and 2.05 ms in the
Metal product.

## Correctness and paired S3 evidence

The final candidate is `aa7d76d222f7`; the untouched paired predecessor is
`1c3f3ca758d1`; the harness identity is `6f3edb9c3f99`. The full 356-source
ReleaseFast test closure, formatting, diff checks, and source conformance pass.
Direct ten-sample CPU/Metal diagnostics retained all three fixed proof hashes,
verification, byte identity, expected Metal dispatches, and zero fallback.

The final paired S3 wide/time verdicts are:

| board | A median ms | B median ms | R | 95% CI | request R | guards |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| CPU | 11.815 | 9.341 | 0.7911 | [0.7824, 0.8030] | 0.8062 | 12/12 |
| Metal | 10.823 | 8.096 | 0.7598 | [0.7396, 0.7813] | 0.7742 | 12/12 |

Both pass G1-G5, the pinned Rust oracle, and cross-arm byte identity. The proof
digest remains
`57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`.
This is a 20.9% CPU prove-time reduction and a 24.0% Metal-product reduction
from the same corrected shared-field mechanism.

One rerun initially stopped before measurement because the harness tried to
create an oracle artifact that already existed in its ignored `.runs/latest`
directory. The stale CPU and Metal oracle artifacts were moved intact to the
external evidence directory; the final verdicts above were then generated
fresh and are bound to the final commit.

## Submission boundary

The submission claims exactly CPU-wide and Metal-wide. Small and deep remain
guards rather than claimed objectives. The patch does not alter MSL, pipeline
creation, source-JIT/AOT selection, resource ownership, or synchronization;
the Metal win comes from removing the new dominant host-side stage in the full
Metal product. Judge reruns remain authoritative.
