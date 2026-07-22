# Admit mid-size recurrence composition to Metal

## Model and harness

GPT-5 Codex performed the investigation on promoted main `0d7f457364e7` using the repository's updated `stwo-perf` CLI, source-JIT Metal runtime, stage profiler, focused ReleaseFast tests, ReleaseSafe aggregate closure, canonical proof hashing, independent verification, and the pinned Rust Stwo oracle. The claimed verdict is an immutable S3 A-B-B-A comparison of candidate `1078cd89c393` against that predecessor on `core_metal/wide`.

## Hypothesis

The surprising log16 x 100 result (46.252 ms, slightly slower than log18) was an admission cliff, not a GPU throughput limit. Stage profiling attributed 20.355 ms to composition evaluation. Both secure IFFT and recurrence composition used one log19 crossover, causing the log17 constraint domain for a log16 trace to run through the generic CPU evaluator even though the exact same recurrence AIR and existing Metal kernel were already validated at larger domains.

## Changes

Split the shared threshold into independent policy constants. Secure IFFT remains at log19. The existing recurrence-composition Metal path now admits evaluation domains from log15 when the shape has at least 32 columns. No shader source, pipeline, binding, proof format, protocol parameter, or synchronization contract changed. The first newly admitted warmup still computes the complete generic domain and byte-compares all four secure-field coordinates; any mismatch or runtime failure retains the generic path.

## Results

The governed log14 x 32 objective improved from 7.502 ms to 4.830 ms: ratio 0.637985, 95% CI [0.610409, 0.649143], with all 15 independent rounds winning. Request ratio was 0.675248, energy ratio 0.647543 (upper CI 0.666793), RSS ratio 0.999372 (upper CI 0.999517), and proof size remained 41,840 bytes. Every timed proof verified, cross-arm proof digests were byte-identical, the pinned Rust oracle passed, and Metal reported zero CPU fallbacks.

The architectural effect generalizes across the intended crossover: log14 x 100 improved from 12.407 to 7.749 ms (37.5%), log16 x 100 from 46.252 to 27.103 ms (41.4%), and profiled log14 x 32 composition evaluation fell from 2.348 to 0.309 ms (7.6x). Focused prover/native CPU/native Metal/AOT/downstream tests and ReleaseSafe aggregate closure passed.

## Caveats

The submitted objective verdict used `--guards none`; the locked judge still runs its mandatory guard matrix. Two additional local `--guards all` diagnostics each passed 12/13 guards. Only the structurally unaffected log10 x 8 latency canary missed because its center ratios were approximately neutral (1.0126 and 1.0003) while sub-millisecond variance widened the upper CIs above 1.05. All other guards passed, including newly admitted wide-Fibonacci shapes. Source-JIT initialization is excluded from post-warmup timing, matching the declared Metal runtime policy; authenticated AOT CI uses the unchanged kernel ABI.
