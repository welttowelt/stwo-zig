# Fuse large Metal LDE layers and accelerate shared M31 reductions

## Model and harness

GPT-5 Codex optimized candidate `7e70f1a70ba4` against exact predecessor
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

The optimized reduction and four-coordinate `QM31.add` are compile-time gated
to AArch64. A first CI pass showed that Zig 0.15.2's optimized x86_64 vector path
could produce a constraint-invalid RISC-V proof even though field laws passed.
All other architectures therefore compile the exact predecessor scalar/select
implementation; this restores x86 proof semantics while leaving the measured
AArch64 machine code unchanged.

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
| CPU huge `wf_log20x100` | 858.236 ms | 814.475 ms | 0.950000 [0.944843, 0.957135] | 5.00% |
| Metal xlarge `mwf_log18x100` | 424.022 ms | 408.540 ms | 0.970515 [0.961068, 0.977978] | 2.95% |

Both results are significant against their noise-derived thresholds. CPU
energy fell 4.46% and Metal energy fell 3.18%; proof bytes are unchanged and
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
acceptance-probe contracts, field-law suites, the exact local RISC-V proof, the
static x86_64 Linux RISC-V product build, and the full ReleaseFast Zig test
closure.

## Caveats

QoS/task-policy changes were neutral or unstable. A larger 4,096-element,
512-thread FFT tile improved an isolated stage but hurt end-to-end scheduling.
MSL `min` rewrites were already compiler-canonicalized. Each was removed.

The no-copy bridge deliberately applies only to large page-aligned UMA arenas;
other devices and layouts fail closed to the established upload path. Full
Metal System Trace is unavailable on this Command-Line-Tools-only host, so
attribution uses real source-JIT execution, stage timers, command topology,
proof telemetry, paired S3 evidence, and exact predecessor/candidate profiles.
