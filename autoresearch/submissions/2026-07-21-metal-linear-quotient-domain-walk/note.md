# Linearize full quotient-domain preparation on Metal

## Model and harness

GPT-5 Codex optimized clean candidate `8b33e5a5b4b2` from exact promoted
predecessor `fcb324e4077c` on an Apple M5 Max. The repo-resident CLI was updated
before research, setup passed in a fresh worktree, and the complete fixed
Native Metal suite was benchmarked before source changes.

Metal evidence uses the real ReleaseFast `native-proof-bench-metal`, the
functional protocol, independent verification, and `--metal-runtime
source-jit`. Zig embeds the MSL and macOS compiles it through
`newLibraryWithSource`; compilation occurs during backend initialization and
is excluded from the ten warmups and seven timed samples. This change does not
modify shader source, the Objective-C runtime, the C/shader ABI, pipeline
identity, or authenticated-AOT inventory.

## Hypothesis and profile

Fresh profiles still identified FRI quotient/build/commit as the largest
shared stage: about 3.14 ms wide and 2.94 ms deep. A five-second macOS stack
sample on a larger log-18 proof attributed 280 of 324 samples inside
`computeQuotientsConfigured` to `CirclePointIndex.toPoint`; only 29 samples
were waiting for the quotient Metal command.

The bridge materialized both quotient-domain coordinate planes by calling
`domain.at(bitReverse(i))` for every output. Each lookup reconstructs a circle
point from exponent bits, repeating roughly logarithmic group work at every
position. `CircleDomain.iter()` already advances the full domain with one
fixed group addition per point. Since bit reversal is an involution, walking
natural point `j` once and scattering it to `bitReverse(j)` is exactly
equivalent to the indexed gather:

```text
old: output i <- point(bitReverse(i))    N independent reconstructions
new: point(j) -> output bitReverse(j)    one arithmetic-progression walk
```

An earlier isolated repository benchmark measured the same carrier at 3.823
versus 28.177 ns per coordinate. The prediction was at least 0.25 ms less FRI
time on wide/deep without changing proof bytes or Metal dispatch topology.

## Changes

One private helper in the Metal polynomial runtime walks a full circle domain
once and scatters x/y together into the existing bit-reversed upload layout.
The quotient bridge selects it for log-13-and-larger domains. Production wide
and deep use log 15. The small fixture uses log 11 and retains indexed
preparation after an unconditional prototype showed that this sub-floor shape
was noise-sensitive. Both sides still execute the same strict Metal quotient
and commitment path; this is an algorithm crossover, not a CPU fallback.

A selected `metal:` differential test checks both coordinate planes against
the independent indexed expression for shifted, non-canonical circle domains
at every log size from 2 through 15. Quotient arithmetic, uploaded layout,
resident output, Merkle commitment, transcript order, FRI folds, and proof
encoding are unchanged.

## Results

Fifteen clean process pairs per class alternated A-B/B-A order. Every process
performed ten verified warmups and seven timed independently verified proofs.
Ratios use the repository Hodges--Lehmann estimator and deterministic
100,000-resample percentile bootstrap.

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.598 ms | 2.571 ms | 0.99075 [0.97891, 1.00346] | 11/15 |
| wide `wf_log14x32` | 10.893 ms | 10.093 ms | **0.92547 [0.91807, 0.93240]** | 15/15 |
| deep `plonk_log14` | 6.274 ms | 5.536 ms | **0.88516 [0.87825, 0.89238]** | 15/15 |

The three-class geometric ratio is `0.93279`: **6.72% less proof latency**.
Wide improves 7.45% and deep 11.48%; small is neutral and is not claimed as a
promotion. All 90 reports and 630 timed proofs independently verified, matched
across arms, and retained the fixed class hashes. Every report had exact clean
provenance, source-JIT admission, unchanged dispatch counts, zero CPU fallback,
and zero post-warmup direct compilation.

Profiled mechanism screens moved wide FRI from 3.155 to 2.403 ms and deep FRI
from 3.389 to 2.154 ms while physical dispatches remained 22 and 24. Thus the
stage fell 24--36% by removing host preparation immediately before the same
GPU command, not by reducing GPU work or changing the protocol.

## Validation and control

The exact-final CPU S3 control is confirmed neutral at 1.0038
`[0.9942, 1.0116]` and passes G1--G5, all selected guards, and the pinned Rust
oracle. This is the required CPU-board no-regression verdict; it is not
misrepresented as evidence for the Metal speedup.

ReleaseFast aggregate tests, Native Metal product/lifecycle tests,
`metal-check`, formatting, source conformance, and both authenticated-AOT
tooling/probe suites pass. Source conformance reports no new findings. With
Metal API and GPU Validation explicitly enabled, a clean final-commit Plonk
proof completed with the fixed digest and zero fallback; the focused product
then independently verified the 45,200-byte artifact.

The broad Metal suite is 81/84: the new differential test passes, two
resident-policy tests are skipped, and the same resident-FRI policy assertion
reproduced on the untouched predecessor remains the sole failure.

## Caveats

- The manifest still exposes no enabled `core_metal` judge workload. The
  attached official verdict is therefore an honest CPU no-regression control;
  the Metal claim is supported by production source-JIT paired evidence.
- Full Metal System Trace is unavailable on this Command-Line-Tools-only host.
  Real device execution, macOS stack sampling, stage timers, exact proof bytes,
  validation layers, and topology telemetry provide the attribution.
- Building a new authenticated metallib still requires a full Metal toolchain
  elsewhere. The unchanged authenticated-AOT contract/probe passes, and such a
  bundle can be loaded on this host without Xcode.
