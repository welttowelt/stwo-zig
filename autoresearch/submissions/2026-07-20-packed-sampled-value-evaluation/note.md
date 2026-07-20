# Evaluate sampled-value polynomials across native SIMD lanes

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf`, updated before research
to current `main` (`4dc26f00d743`). ReleaseFast on arm64 macOS, paired S3
time evaluations against the unchanged current-main predecessor for every
affected class. A reasoning-first sanitized transcript is attached as
`transcripts/session-01.md`.

## Hypothesis

PCS sampled-value evaluation applies the same secure-field point factors to
many independent circle-basis coefficient polynomials. The existing batched
helper shares factors but reduces one polynomial at a time, leaving native SIMD
lanes unused inside each worker. Packing independent polynomials into M31 lanes
should preserve each polynomial's exact carry-style merge order while removing
most scalar secure-field instructions across all three workloads.

## Changes

Added a lane-wise packed QM31 reduction for one native-width batch of
coefficient streams. `evalManyAtPointsWithFlatFactors` dispatches full batches
through it and retains the existing scalar evaluator for incomplete tails and
scalar targets. The existing batch-vs-scalar property test now covers one full
native batch plus a tail. Tree scheduling, point factors, field semantics,
coefficient order, transcript order, and protocol bytes are unchanged.

## Results

S1 on 32 degree-2^14 live-repo polynomials at one secure point: packed/scalar
wall ratio **0.3730**, 95% CI **[0.3674, 0.3738]**; instruction ratio **0.3201**
and cycle ratio **0.3730**. The packed kernel measured 72.52 versus 226.5
instructions per coefficient. Live arm64 disassembly contains the predicted
`umull/umull2.2d`, `uzp1.4s`, `add/sub/cmhi.4s`, and `st4.4s` operations.

Profiled sampled-value medians fell from 0.158 to 0.087 ms small, 1.745 to
0.711 ms wide, and 0.879 to 0.380 ms deep. Promotion-grade paired S3 results:

- `wf_log10x8` small: ratio **0.9612**, 95% CI **[0.9441, 1.0006]**, 15 rounds,
  1.645 to 1.582 ms; favorable but correctly recorded as not significant.
- `wf_log14x32` wide: ratio **0.9181**, 95% CI **[0.9099, 0.9246]**, 15 rounds,
  12.573 to 11.524 ms; significant improvement.
- `plonk_log14` deep: ratio **0.9430**, 95% CI **[0.9345, 0.9498]**, 15 rounds,
  8.608 to 8.131 ms; significant improvement.

Every timed proof verified and remained byte-identical. Fresh seven-sample
suite diagnostics retained proof SHA-256 values `91741aec...bea5700` small,
`57a7d291...0f3374` wide, and `d63a2c92...69dbaf` deep. The ReleaseFast prover
and native CPU product closures passed across 152 and 190 transitive Zig
sources respectively.

## Caveats

These are local claimed verdicts; the locked judge rerun remains authoritative.
The anchor is not frozen, so budgets and judged promotion remain inactive.
Mechanism telemetry is still pending in the harness; differential tests,
counter ratios, stage attribution, and live codegen provide the current
mechanism evidence. Small's measured stage improvement did not clear the
end-to-end confidence threshold, so no significance is claimed for that class.
