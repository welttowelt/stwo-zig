# Fuse large Metal LDE layers and accelerate shared M31 reductions

## Model and harness

GPT-5 Codex optimized candidate `e10ff92e92a1` against exact predecessor
`7f00554f9df4` on an Apple M5 Max. The repository-resident `stwo-perf` CLI was
updated before work. Fresh CPU and Metal baselines were run before profiling,
and the final evidence uses the real ReleaseFast Native products with five
rounds of ABBA pairing, ten post-initialization warmups per process, independent
proof verification, and the pinned Rust oracle.

Metal runs use `--metal-runtime source-jit`: Zig embeds the MSL, and macOS
compiles it through `newLibraryWithSource` during backend initialization. That
compilation is outside the timed post-warmup samples; no full Xcode installation
or offline `metal` compiler is involved.

## Hypothesis

Profiles exposed two complementary bottlenecks. The shared wide-Fibonacci host
composition loop spends hundreds of millions of operations canonicalizing M31
lanes, while large Metal commitments perform adjacent radix-2 LDE launches and
then copy a completed contiguous column arena into private storage before
hashing it.

For canonical M31 operations whose intermediate is proven below `2p`,
`min(x, x -% p)` is exactly conditional subtraction. Fixed Vec4/native-packed
additions and product reductions now use that identity; AArch64 lowers it to
`UMIN`. `QM31.add` feeds the fixed Vec4 path by extracting its four coordinates
directly at the use site.

## Changes

The Metal LDE path composes three changes:

- the proven sparse radix-4 kernel now handles inverse as well as forward
  contiguous upper-layer pairs;
- one-bit blowup at `base_log >= 12` fuses coefficient scaling, degenerate zero
  expansion, and the first two real forward layers; and
- page-aligned contiguous UMA arenas of at least 1 MiB are exposed through
  `newBufferWithBytesNoCopy`, so leaf hashing consumes completed LDE output
  without a full-arena staging blit.

Small, fragmented, or non-UMA layouts retain the old copy path. The alias lives
only through the synchronous command lifetime and the existing terminal wait.
The core shader ABI is bumped from 5 to 6 so old authenticated AOT bundles fail
closed. No CPU fallback or relaxed arithmetic is introduced.

## Results

| board / class | predecessor | candidate | B/A (95% CI) | latency reduction |
| --- | ---: | ---: | ---: | ---: |
| CPU huge `wf_log20x100` | 862.923 ms | 818.807 ms | 0.953428 [0.941439, 0.964728] | 4.66% |
| Metal xlarge `mwf_log18x100` | 419.301 ms | 410.634 ms | 0.976060 [0.971860, 0.982132] | 2.39% |

CPU is significant against its noise-derived threshold. Metal is favorable and
not neutral, but its current-main five-round upper CI is 0.001086 above the
`1 - theta` promotion boundary. The immediately preceding identical-source run
before the harness-only rebase was significant at 0.974533
[0.968636, 0.980512]; both runs are disclosed and the latest result is claimed.
CPU energy fell 4.23% and Metal energy fell 3.07%; proof bytes are unchanged and
peak RSS remains within budget. The final Metal profile moved the xlarge
main-trace commitment from about 34.6 to 27.0 ms and composition commitment
from about 9.6 to 8.5 ms.

Every timed proof verified and remained byte-identical across arms. The pinned
Rust oracle accepted both fixed proofs: `e6609d...c7e86` for huge and
`f845568c...ced8f` for xlarge. G1--G5 and all 13 automatic regression guards
passed for both verdicts.

## Correctness and validation

An early top-layer prototype exposed the exact architectural boundary: enabling
it on tiny domains overlapped the existing 11-layer fused tail and caused
`guard_blake_10x10` to fail its last-layer-degree check. The final
`base_log >= 12` gate makes the regions disjoint; that guard and the complete
matrix now pass.

Validation passes the Native Metal product/lifecycle and independent proof
verification, Metal compile gate, deterministic core-AOT tooling suite, AOT
acceptance-probe contracts, and the full ReleaseFast Zig test closure.

## Caveats

QoS/task-policy changes were neutral or unstable. A larger 4,096-element,
512-thread FFT tile improved an isolated stage but hurt end-to-end scheduling.
MSL `min` rewrites were already compiler-canonicalized. Each was removed.

The no-copy bridge deliberately applies only to large page-aligned UMA arenas;
other devices and layouts fail closed to the established upload path. Full
Metal System Trace is unavailable on this Command-Line-Tools-only host, so
attribution uses real source-JIT execution, stage timers, command topology,
proof telemetry, paired S3 evidence, and exact predecessor/candidate profiles.
