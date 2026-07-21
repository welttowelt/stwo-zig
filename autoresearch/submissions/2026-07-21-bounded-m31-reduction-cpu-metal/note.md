# Specialize bounded M31 reduction on CPU and Metal

## Model and harness

GPT-5 Codex developed and measured this change with the repository's pinned
`stwo-perf` harness at harness commit `becd88e4944a`. The candidate is
`a16249f27872` against promoted predecessor `9efa1dba0714`. All reported S3
verdicts use paired ABBA rounds, verified proof digests, and the pinned Rust
oracle on an Apple M5 Max. Native CPU and Metal source-JIT products were built
in ReleaseFast mode; Metal runs reported no CPU fallback.

## Hypothesis

M31 multiplication was using a generic reducer designed for arbitrary 64-bit
inputs even though multiplication receives canonical field elements. With
`p = 2^31 - 1` and `0 <= a,b < p`, the product satisfies `a*b < p^2 < 2^62`.
One Mersenne fold therefore lands below `2p`, so one conditional subtraction is
sufficient. Canonical addition also lands below `2p` and needs only one
conditional subtraction. Removing redundant folds should reduce integer work
in both host field arithmetic and Metal shaders without changing proofs,
dispatches, resources, or ownership.

## Changes

The CPU scalar, four-lane vector, and native-packed multiplication paths now use
a bounded product reducer. The generic arbitrary-`u64` reducer remains intact
for constructors and boundary normalization. Edge cases, 4,096 randomized
canonical products, Vec4 results, and native-packed results are checked against
the generic reducer.

The Metal M31 header now implements canonical addition with a 32-bit
sum/subtract and canonical multiplication with one 64-bit fold/subtract. The
generic Metal reducer remains available for wider arena values. No public ABI,
buffer layout, resource lifetime, encoder, synchronization, pipeline, or
dispatch behavior changes.

## Results

All six S3 CPU+Metal time verdicts are significant:

| board / class | A median | B median | ratio | 95% CI | request ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU / small | 1.511209 ms | 1.417666 ms | 0.936051 | [0.907390, 0.959173] | 0.947688 |
| Metal / small | 2.505917 ms | 2.436791 ms | 0.965743 | [0.944044, 0.987941] | 0.967833 |
| CPU / wide | 10.344041 ms | 9.660250 ms | 0.923793 | [0.909715, 0.947753] | 0.915524 |
| Metal / wide | 8.911667 ms | 7.814709 ms | 0.866114 | [0.844814, 0.883687] | 0.856497 |
| CPU / deep | 6.691500 ms | 6.292166 ms | 0.943371 | [0.923037, 0.955130] | 0.945990 |
| Metal / deep | 4.777625 ms | 4.627625 ms | 0.960649 | [0.919915, 0.980512] | 0.960284 |

All claimed verdicts pass G1-G5, cross-arm proof digests are byte-identical,
and the pinned Rust oracle verifies every workload. An isolated live-code CPU
profile measured ratio 0.7722 with 95% CI [0.7632, 0.7796], while instructions
fell to ratio 0.7384. A warmed real-device Metal arithmetic kernel stabilized
near 0.184 ms before versus 0.0865 ms after, supporting the same mechanism.

## Caveats

Metal-small was noisy in an earlier process-level diagnostic, but its final
15-round paired verdict is significant and is included above. One broad
resident-FRI Metal test fails on this machine at both the candidate and
untouched predecessor; focused device-only proof and independent-verifier tests
pass, as do core, prover, native CPU, Metal AOT compile/probe, formatting, and
source-conformance checks. These are submitter measurements; only the judge
rerun determines promotion.
