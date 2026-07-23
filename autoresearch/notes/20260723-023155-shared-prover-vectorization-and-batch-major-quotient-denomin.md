---
title: Shared prover vectorization and batch-major quotient denominators
author: Teddy Pender
created_utc: 2026-07-23T02:31:55Z
---

# Problem match — shared prover vectorization, epoch 6

## Measured problem

After the direct-column BLAKE2 promotion, the longest RISC-V proof is no longer
dominated by message staging. The largest editable clusters are four-message
BLAKE2 compression, quotient tiles, forward/inverse circle FFT passes, and
batch inversion. The seven-workload portfolio must move together; frontend-only
specialization is both locked by policy and too narrow.

## Structural matches

| observed shape | known optimization pattern | repository application |
| --- | --- | --- |
| independent inversion chains | dependency striping + SIMD batching | pack four CM31 values across AdvSIMD lanes |
| four products before a field reduction | delayed modular reduction | exact `u64` M31 `dot4` |
| four contiguous extension coordinates | transpose the SIMD dimension | multiply `[c0,c1,c2,c3]` by scalar splats |
| final transform followed by uniform scale | fuse producer and affine consumer | absorb `n^-1` into final inverse radix-8 |
| zero-padded 2x extension | exploit known-zero/duplicate boundary | synthesize upper half in first active radix pass |
| four independent ARX chains | software pipelining / ILP exposure | advance BLAKE2 G dependency levels in lockstep |
| constant extension sample point, varying base row | partial evaluation + structure-of-arrays transpose | precompute the CM31 determinant and evaluate four batch-major rows together |

## Generalization and safety

The matches depend on mathematical and layout properties, not benchmark IDs:
nonzero CM31 batches, canonical M31 bounds, compact contribution geometry,
four-coordinate QM31 representation, transform stage position, and 2x LDE
semantics. The quotient denominator reduction follows the exact identity
`(prx-x)*piy-(pry-y)*pix = det-x*piy+y*pix`; CPU and Metal share that algebra.
Generic architectures retain scalar fallbacks. Focused differential tests
cover odd lengths, high-value reductions, zero rejection, row- and batch-major
layouts, changing retained-scratch strides, fused versus generic FFT stages,
and synthesized versus materialized expansion.

## Falsifiers used

- Reject a layer if exact proof hex, statement, transcript, or oracle parity
  changes.
- Reject instruction-saving SIMD if cycles or end-to-end latency regress under
  paired measurement.
- Reject a plan/layout change below 0.1% process work reduction when it adds
  persistent complexity.
- Do not submit until the complete deep portfolio CI clears the repository's
  noise-adjusted significance boundary.

## Result

The final stacked clean candidate reaches proving geomean ratio 0.982416 with
95% CI [0.980101, 0.984837], 4.78% lower energy, flat RSS, identical proof
bytes, and oracle acceptance for all seven workloads. The last denominator
layer alone removes 1.21% of SHA2-2048 process instructions and 0.95% of
cycles. Rejected worker sweeps, flattened direct plans, wide dependency
stripes, extra accumulators, generic QM31 SIMD, and statistically inconclusive
paired runs are retained in the session transcript.
