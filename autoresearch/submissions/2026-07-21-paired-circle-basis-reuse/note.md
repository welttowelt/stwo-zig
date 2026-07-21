# Reuse one circle basis across CPU and Metal sampled-value evaluation

## Model and harness

Model: GPT-5 Codex. The repository-resident `stwo-perf` and `stwo-prof` tools
were used on an Apple M5 Max. ReleaseFast source-JIT Metal initialization was
excluded by the benchmark warmups. Every timed proof verified, cross-arm proof
digests were byte-identical, and the pinned Rust oracle verified the workload.

## Hypothesis

For one sampled circle point, the recursive coefficient evaluator is exactly
the subset-product linear form
`sum(coeff[i] * product(factor[set_bits(i)]))`. Materializing that basis once
per point and reusing it across columns should replace repeated full-extension
multiplies on CPU. Metal already materialized it, but rebuilt every element
independently from all set bits; retaining an 8-bit low product per lane and
sharing one high product per 256-entry block should remove most basis work.

At log14, the Metal basis estimate falls from roughly 114,688 full QM31
multiplies per point to about 17,600, with unchanged tasks, buffers, dispatches,
ABI, and proof bytes. The falsifier was a neutral sampled stage, any proof
difference, or a regression on either CPU or Metal.

## Changes

The CPU path now prepares all point bases once, shares them read-only across
column workers, and evaluates packed QM31-by-M31 dot products. Its two-level
basis builder keeps the 256 low entries in a Karatsuba-ready packed tile. A
live hardware-counter harness measures 3.902 ns and 15.87 cycles per log14
basis element, down from 4.318 ns and 17.44 cycles.

The Metal basis kernel keeps its existing export and ABI but splits each index
into a lane-local low byte and a high block. Lane zero publishes the high
product through one 16-byte threadgroup value; barriers bound its lifetime.
Source-JIT and authenticated AOT still consume the same kernel identity.

Two guarded ownership cuts improve the shared host composition path. Fresh
zeroed buckets use direct stores only while row indices are strictly
sequential; repeated/out-of-order use returns permanently to additive
semantics. A sole max-domain bucket transfers out of finalization instead of
being copied into another zeroed 512 KiB column. Four-coordinate
`QM31.add/sub/mulM31` use existing tested Vec4 M31 primitives.

## Results

Profiled CPU sampled-value medians moved from 0.089/0.751/0.370 ms to about
0.056/0.338/0.231 ms on small/wide/deep. Metal wide moved from 0.865 to about
0.59 ms with zero CPU fallbacks.

After refreshing to current harness `827c0794eea9`, same-session uninstrumented
S3 wide results against current predecessor `3979c29` are:

- `core_cpu`: 10.984 -> 10.258 ms, ratio 0.9331, 95% CI
  [0.9211, 0.9576], significant.
- `core_metal`: 9.596 -> 9.199 ms, ratio 0.9533, 95% CI
  [0.9393, 0.9629], significant.

ReleaseFast core/prover/CPU closures, Native Metal tests, source-JIT execution,
Metal parity, AOT tooling contracts, formatting, and source conformance pass.
Fixed proof SHA-256 values remained `91741aec...bea5700` small,
`57a7d291...0f3374` wide, and `d63a2c92...b69dbaf` deep.

## Caveats

Full Metal System Trace was attempted but `xctrace` is unavailable without
full Xcode. Device attribution instead uses the real M5 Max, production stage
timers, dispatch telemetry, source wait topology, and command-buffer GPU
timestamps. Four-product delayed Mersenne reduction and four-column worker
granularity were measured neutral/slower and removed; those dead ends remain
in the attached transcript. Local S3 verdicts are advisory until judge reruns.
