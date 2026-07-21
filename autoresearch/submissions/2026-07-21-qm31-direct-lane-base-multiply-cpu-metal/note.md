# Vectorize QM31 base multiplication without aggregate copies

## Model and harness

GPT-5 Codex developed and measured candidate `aa7d76d222f7` against corrected
predecessor `1c3f3ca758d1` with the repository's pinned `stwo-perf` harness at
`6f3edb9c3f99`. The canonical CLI was updated before the iteration, and remote
main was checked again before packaging. Native CPU and Native Metal
source-JIT products were built in ReleaseFast mode on an Apple M5 Max. Metal
used the macOS runtime compiler for the embedded MSL and reported zero CPU
fallback.

## Hypothesis

The upstream proof-correctness repair intentionally replaced QM31's generic
four-coordinate vector conversions with scalar CM31 operations because Zig
0.15.2 can miscompile optimized by-value aggregate copies. Fresh profiles
showed that this made the shared wide-Fibonacci composition stage the dominant
host bottleneck: about 4.63 ms in the CPU product and 5.13 ms in the Metal
product.

Every coordinate of `QM31.mulM31` is an independent canonical M31 product by
the same base-field scalar. Loading the four scalar fields directly inside the
consuming operation should recover NEON execution without creating the unsafe
`QM31 -> helper -> vector` aggregate copy. Generic QM31 add/sub and all
full-extension multiplication remain on the corrected scalar implementation.

## Changes

`QM31.mulM31` now constructs one `Vec4u32` directly from
`c0.a`, `c0.b`, `c1.a`, and `c1.b`, calls the existing bounded
`m31.mulVec4` with a splatted base-field operand, and reconstructs the canonical
QM31 result from the four output lanes. No helper accepts a QM31 aggregate by
value. No field-operation order, representation, ABI, proof format, shader,
pipeline, resource, command buffer, dispatch, or synchronization behavior
changes.

The resulting dataflow is:

```text
four canonical QM31 limbs --direct field loads--> Vec4u32
                                                   |
base M31 scalar ------------------------------- splat + mulVec4
                                                   |
four canonical products <------------------ direct lane extraction
```

ReleaseFast disassembly of the live wide-Fibonacci evaluator contains the
expected `umull.2d`, `umull2.2d`, and `uzp1.4s` sequence. Diagnostic stage
medians fell from approximately 4.63 to 2.21 ms on CPU and 5.13 to 2.05 ms in
the Metal product.

## Results

Both paired S3 wide/time verdicts are significant and pass G1-G5:

| board | A median | B median | ratio | 95% CI | request ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU | 11.815 ms | 9.341 ms | 0.7911 | [0.7824, 0.8030] | 0.8062 |
| Metal | 10.823 ms | 8.096 ms | 0.7598 | [0.7396, 0.7813] | 0.7742 |

This is about 20.9% less CPU prove time and 24.0% less Metal-product prove
time from one shared host-field mechanism. Both runs pass all 12 impact-mapped
regression guards and the pinned Rust oracle. Every timed proof verifies,
cross-arm proofs remain byte-identical, and wide's proof SHA-256 is unchanged
at `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`.
Metal retains 22 high-level dispatches and zero fallback.

The full 356-source ReleaseFast test closure and source-conformance gate pass.
The upstream log-10 packed high-block subset-basis regressions specifically
exercise the optimized `mulM31` call pattern and pass.

## Caveats

An exploratory patch also vectorized QM31 add/sub. It did not improve the
target and one noisy Metal Poseidon guard missed its confidence budget, so that
broader patch and its verdicts were discarded. The submitted patch contains
only the multiplication mechanism; its fresh CPU and Metal verdicts pass every
guard. The gain is largest on wide Fibonacci, whose composition loop performs
many secure-by-base products. These are submitter measurements; the judge rerun
remains authoritative.
