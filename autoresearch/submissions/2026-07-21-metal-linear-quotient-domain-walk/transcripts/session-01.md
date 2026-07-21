# Session 01 — ninth Metal-backend architecture campaign

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and fresh grounding

PR #32 merged the Metal FRI linear walker/transcript-tail architecture and the
recorder advanced canonical main to `fcb324e4077c`. The repo-resident CLI was
updated to that exact frontier before a new isolated workspace passed setup.
The complete ReleaseFast source-JIT suite then ran locally with ten warmups and
seven verified samples:

| class | prove median | request median |
| --- | ---: | ---: |
| small `wf_log10x8` | 6.289 ms (frequency-ramp first process) | 6.546 ms |
| wide `wf_log14x32` | 10.915 ms | 11.861 ms |
| deep `plonk_log14` | 6.294 ms | 6.610 ms |

All proofs had fixed hashes, clean complete provenance, source-JIT admission,
zero CPU fallback, and zero post-warmup compilation. A second warmed small run
profiled at 2.497 ms, confirming that its first-process figure is frequency
ramp rather than frontier regression.

Seven-sample stage profiles show the new distribution:

| stage median (ms) | wide | deep |
| --- | ---: | ---: |
| main trace commit | 1.756 | 0.643 |
| composition evaluation | 2.611 | 0.126 |
| composition interpolate/split | 0.470 | 0.055 |
| composition commit | 1.391 | 0.739 |
| sampled values | 0.808 | 0.669 |
| FRI quotient/build/commit | 3.144 | 2.935 |
| proof of work | 0.347 | 0.352 |

FRI remains the largest shared stage. Composition evaluation is wide-only CPU
AIR work and is not the right Metal target.

## Sampling attribution

A five-second macOS stack sample used a larger log-18 wide proof so the
ReleaseFast process stayed alive. Within the quotient/FRI call chain,
`computeQuotientsConfigured` received 324 samples. Of those, 280 were in
`CirclePointIndex.toPoint` while only 29 were waiting for the quotient Metal
command. The production Metal bridge currently does this before every quotient
dispatch:

```text
for output position i
    j = bitReverse(i)
    domain.indexAt(j).toPoint()   # reconstruct from exponent bits
    upload x[i], y[i]
```

This is the same missed algorithmic carrier as the line-FRI inverse vectors
fixed in PR #32. The earlier isolated benchmark measured a linear coset walk
at 3.823 ns/coordinate versus 28.177 ns for indexed reconstruction.

## Selected architecture: linear full-domain scatter

`CircleDomain.iter()` already walks the first half-coset and its conjugate in
natural domain order using one group addition per point. Bit reversal is an
involution, so walking natural point `j` and scattering it to
`bitReverse(j)` is exactly equivalent to gathering indexed point
`bitReverse(i)` for every output `i`:

```text
old: N independent exponent reconstructions
     output i <- point(bitReverse(i))              O(N log N)

new: one arithmetic-progression domain walk
     natural point j -> output bitReverse(j)       O(N)
```

The Metal quotient kernels, uploaded x/y layout, denominator arithmetic,
batch terms, resident output, commitment fusion, transcript, and proof bytes
remain unchanged. Keeping generation on the CPU is deliberate for this step:
the existing GPU domain kernel independently performs `circle_pow` per row,
which retains logarithmic point reconstruction and adds a serialized grid.
The linear host walk removes the identified work without changing the GPU
critical path or ABI.

Prediction: at least 0.25 ms less FRI-stage time on wide/deep and a significant
multi-class end-to-end win. Falsifiers are any differential point/proof mismatch,
sampling that still lands in `CirclePointIndex.toPoint`, or clean paired timing
that does not separate from the exact recorded predecessor.

## Implementation and first mechanism screen

The implementation is one private Metal-runtime helper. It accepts the two
u32 coordinate buffers and a full `CircleDomain`, asserts the exact shape,
walks `domain.iter()` once, and scatters x/y together through the existing bit
reversal. The quotient bridge now calls it instead of independently invoking
`domain.at()` for every output. No shader source, runtime binding, dispatch,
buffer layout, field operation, commitment, channel operation, or proof type
changed.

A differential unit test uses non-canonical shifted half-cosets and compares
both coordinates with the former independent indexed expression at every log
size from 2 through 15. It passed as part of the ReleaseFast Metal suite. The
broad result remains the frontier's known 80/83: two resident-policy skips and
the same one resident-FRI policy assertion; there is no new failure.

Freshly rebuilt predecessor and dirty-candidate source-JIT products then gave
this profiled mechanism screen (seven verified samples after ten warmups):

| class | predecessor FRI | candidate FRI | stage reduction | proof hash |
| --- | ---: | ---: | ---: | --- |
| wide | 3.155 ms | 2.403 ms | 23.8% | exact frontier hash |
| deep | 3.389 ms | 2.154 ms | 36.4% | exact frontier hash |

Physical Metal dispatches remain 22 wide and 24 deep, CPU fallbacks remain
zero, and all samples within each arm are byte-identical. This isolates the
gain to host preparation before the unchanged quotient command rather than a
GPU scheduling or protocol change.

Short small-class processes exposed the host's familiar frequency-ramp mode:
the first arm was 5.742 ms while later ABBA arms settled near 2.53--2.64 ms,
with unrelated stages moving together. Once settled, candidate medians were
2.529--2.579 ms versus predecessor 2.547--2.642 ms. The formal clean paired
suite must counterbalance this effect; no claim will be based on the favorable
single-process screens above.

## Frozen clean result

The production source was frozen as clean commit `4392f8a432f8`; a detached
worktree built that exact revision independently of clean predecessor
`fcb324e4077c`. Fifteen process pairs per class alternated A-B/B-A. Every
process performed ten verified warmups and seven timed verified proofs. The
harness rejected an initial setup mistake before accepting data: benchmark
provenance is resolved relative to each process working directory, so each arm
must execute with its own repository as `cwd`, not merely its own absolute
binary path.

Repository Hodges--Lehmann statistics with deterministic 100,000-resample
percentile bootstrap give:

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small, second conditioned set | 2.588 ms | 2.572 ms | 0.98891 [0.97466, 0.99840] | 11/15 |
| wide | 10.796 ms | 10.075 ms | 0.93282 [0.92453, 0.94016] | 15/15 |
| deep | 6.278 ms | 5.523 ms | 0.87915 [0.87433, 0.88320] | 15/15 |

The three-class geometric ratio is 0.93255, about 6.74% less latency. Wide
and deep decisively clear the one-percent significance floor. Small is a
favorable no-regression result but its upper bound does not clear 0.99, so it
is not described as a promoted small-class result.

All accepted pairs carried exact clean commits, complete ReleaseFast
provenance, source-JIT admission, fixed cross-arm proof hashes, seven verified
byte-identical samples, unchanged per-proof dispatch counts, zero CPU fallback,
and zero post-warmup direct compilation. The proof hashes are:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`;
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`;
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`.

Compared with the recorded frontier stage medians from the same session, the
clean end-to-end effect matches the attribution: roughly 0.72 ms on wide and
0.76 ms on deep, while the profiled quotient/FRI stage alone removed 0.75--1.24
ms depending on machine state. Dispatch topology and GPU work are unchanged;
the saved work is the eliminated host-side point reconstruction immediately
before the quotient grid.

## Final crossover refinement and exact submission result

The first exact rerun after selecting the differential test measured the
linear algorithm at 0.93592 wide and 0.88571 deep, but small estimated 1.01096
with a neutral-crossing interval. Even though the small process is noisy, a
suite optimization should not perturb a shape whose quotient preparation is
already below the meaningful floor. That result falsified using the linear
walker unconditionally.

The final cost model therefore selects the linear walk at quotient-domain log
13 and above. Production wide and deep use log 15 and retain the optimized
path; fixed small uses log 11 and retains the predecessor's indexed path.
This is an algorithm crossover, not a backend fallback: both sides prepare the
same source-JIT Metal quotient dispatch and the same GPU work. Short ABBA
screens showed small returning to neutral while both large shapes retained
their gain.

Final clean candidate `8b33e5a5b4b2` was rebuilt in a new detached worktree
and compared with exact predecessor `fcb324e4077c`. The same 15-pair,
10-warmup/7-sample, alternating-order protocol produced:

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small | 2.598 ms | 2.571 ms | 0.99075 [0.97891, 1.00346] | 11/15 |
| wide | 10.893 ms | 10.093 ms | 0.92547 [0.91807, 0.93240] | 15/15 |
| deep | 6.274 ms | 5.536 ms | 0.88516 [0.87825, 0.89238] | 15/15 |

The exact final three-class geometric ratio is 0.93279: 6.72% lower proof
latency. Wide improves 7.45% and deep 11.48%, with all 30 large-class pairs
winning; small is confirmed neutral rather than claimed as a win. All 90
final reports and 630 timed proofs meet the clean provenance, exact hash,
verification, source-JIT, no-fallback, unchanged-dispatch, and no-post-warmup-
compile assertions described above.

Renaming the differential test with the required `metal:` prefix proved it is
actually selected: the broad suite moved from the frontier's 80/83 to 81/84.
The added test passes; the sole failure and two skips remain exactly the known
resident-FRI policy baseline.

The exact-final CPU S3 control at `8b33e5a5b4b2` is confirmed neutral at
1.0038 [0.9942, 1.0116] over thirteen rounds and passes G1--G5, all selected
regression guards, and the pinned Rust oracle. Final ReleaseFast aggregate and
Native Metal tests, Native lifecycle, `metal-check`, formatting, source
conformance, and both authenticated-AOT tooling/probe test suites pass. Source
conformance reports the same five explained legacy findings and no new debt.

With `MTL_DEBUG_LAYER=1` and `MTL_SHADER_VALIDATION=1`, macOS explicitly
reported both Metal API Validation and Metal GPU Validation enabled. A clean
final-commit Plonk proof completed with zero fallback and the fixed digest, and
the focused Native Metal CLI independently verified its 45,200-byte artifact.
