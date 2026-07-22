# Session 01: Metal recurrence crossover

Model: GPT-5 Codex

## Objective

Find and submit the largest safe Metal-backend improvement after promoted main `0d7f457364e7`, prioritizing the wide-Fibonacci points that remained unexpectedly slow on GPU.

## Grounding measurements

The promoted source-JIT Metal matrix, each with ten warmups and seven verified samples, measured:

- log14 x 100: 12.407 ms prove
- log16 x 100: 46.252 ms prove
- log18 x 100: 45.555 ms prove
- log20 x 100: 162.357 ms prove

The inversion between log16 and log18 was the useful anomaly. A profiled log16 proof spent 20.355 ms of 52.055 ms in composition evaluation. Reading `secure_composition.zig` showed that secure IFFT and recurrence composition shared a log19 admission threshold. A log16 trace evaluates constraints over log17, so it fell back to the generic CPU evaluator; log18 crossed the threshold and used the existing Metal recurrence kernel.

## Design and experiment

The existing recurrence kernel is an exact match for the one-component wide-Fibonacci AIR and already performs a full-domain candidate-versus-generic byte comparison on its first excluded warmup. The change split the two unrelated crossovers:

- secure IFFT remains at log19;
- recurrence composition is admitted at evaluation log15 and at least 32 columns.

No MSL, bindings, pipeline ABI, protocol parameter, proof layout, or synchronization contract changed. Unsupported shapes still use the generic evaluator, and failed first-use validation fail-closes to it.

The first experiment used log17 / 64 columns. It reduced log16 x 100 to 27.215 ms and composition to 1.362 ms. Profiling the adjacent generic log14 shapes found 2.348 ms at width32 and 4.348 ms at width100 in the same evaluator, so the final threshold was tested at log15 / 32 columns before being retained.

## Results

Local ten-warmup/seven-sample results preserved canonical hashes, verified every proof, and reported zero CPU fallbacks:

- log14 x 32: 6.466 ms prove before the formal clean run; profiled composition 2.348 -> 0.309 ms (7.6x stage speedup)
- log14 x 100: 12.407 -> 7.749 ms (0.625 ratio)
- log16 x 100: 46.252 -> 27.103 ms (0.586 ratio)
- log20 x 100 adjacent check: 143.888 ms, canonical hash unchanged

Focused prover, native CPU product, native Metal lifecycle, Metal AOT/probe, downstream, and ReleaseSafe aggregate closure builds all passed.

The immutable S3 `core_metal/wide` submission verdict compared candidate `1078cd89c393` with predecessor `0d7f457364e7` for 15 A-B-B-A rounds:

- prove ratio 0.637985, 95% CI [0.610409, 0.649143]
- predecessor median 7.502 ms; candidate median 4.830 ms
- request ratio 0.675248
- energy ratio 0.647543; upper CI 0.666793
- RSS ratio 0.999372; upper CI 0.999517
- proof size 41,840 bytes on both arms
- proof digest `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`
- all timed samples verified; cross-arm bytes matched; pinned Rust Stwo oracle passed

## Guard diagnostic

Two separate full 13-guard advisory runs passed 12/13. The only failure was the tiny log10 x 8 wide-Fibonacci latency canary, whose recurrence shape is explicitly ineligible for this change. Its center ratios were 1.012599 and 1.000346, but its noisy upper confidence bounds were 1.100122 and 1.212112. Every other guard, including the affected log14 x 32 and log16 x 64 recurrence shapes, passed. The submitted objective verdict is fully green and the locked judge will rerun the mandatory full matrix.

## Conclusion

The optimization removes an accidental CPU admission cliff rather than introducing a new algorithm. The GPU now receives the embarrassingly parallel recurrence work at the mid-size domains where it is already strongly profitable, while first-use differential validation preserves the generic implementation as the semantic authority.
