# Keep FRI inverse domains resident on Metal

## Model and harness

GPT-5 Codex optimized clean candidate `7a28519b5968` from exact current
predecessor `91d18f7bdd44` on an Apple M5 Max. The repository CLI was updated
before research, setup passed in a fresh workspace, and the fixed Native Metal
suite was benchmarked locally before source changes.

Metal evidence uses the real ReleaseFast `native-proof-bench-metal`, functional
protocol, independent verification, and `--metal-runtime source-jit`. Zig
embeds the MSL and macOS compiles it through `newLibraryWithSource`; runtime
initialization is outside the ten warmups and seven measured samples. No full
Xcode installation or offline `metal` compiler is assumed.

## Hypothesis

After quotient domains became resident, a new log-18 stack sample attributed
about 60 samples to FRI coset iteration and 11 to batch inversion, versus about
50 samples waiting for the line cascade. Every proof rebuilt the same
bit-reversed inverse-y circle domain and the same concatenated inverse-x line
domains, allocated scratch arrays, and uploaded them to Metal.

These values depend only on fixed domain shape and indices, not witness or
transcript. Generating them once during excluded warmup and retaining two
bounded device buffers should eliminate recurring host walks, batch inversions,
allocations, and uploads without changing the measured GPU schedule or proofs.

## Changes

The existing authenticated `stwo_zig_quotient_domain_points_resident` kernel
now has three ABI-5 modes: unchanged quotient x/y output, bit-reversed inverse
x, and bit-reversed inverse y. Existing quotient callers bind mode zero.

`StwoZigMetalRuntime` owns independent one-entry circle and line inverse caches
with complete `(shape, layers, initial, step)` keys. On a miss, a private
candidate is generated before its consumer in the same command and published
under synchronization only after successful completion. Hits bind the retained
buffer directly. Local strong references protect in-flight commands; concurrent
misses may duplicate bounded work but cannot observe partial data. The fixed
shape retains roughly 128 KiB total.

Large Metal FRI paths omit host inverses and initialize generic inverse
workspaces lazily. Small and standalone paths retain the previous host route.
CPU backends are compile-time unchanged. The Native export inventory is
unchanged; core shader ABI advances 4 to 5 so prior AOT bundles fail closed.

## Results

Fifteen clean process pairs per class alternated A-B/B-A. Each process used ten
verified warmups and seven timed verified proofs. Ratios use the repository
Hodges--Lehmann estimator and deterministic 100,000-resample bootstrap.

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `mwf_log10x8` | 2.608750 ms | 2.572584 ms | 0.98593 [0.96763, 1.00156] | 10/15 |
| wide `mwf_log14x32` | 9.798583 ms | 9.465792 ms | **0.97348 [0.96103, 0.98404]** | 14/15 |
| deep `mplonk_log14` | 5.301875 ms | 5.006417 ms | **0.94698 [0.94064, 0.95376]** | 15/15 |

The three-class geometric ratio is `0.96866`: **3.13% lower Metal proof
latency**. Wide improves 2.65% and deep 5.30%; small is neutral and is not
overclaimed. All 630 measured proofs verified, matched hashes across arms,
used clean source-JIT provenance, and had zero CPU fallback or post-warmup
compilation.

The newly enabled official `core_metal` S3 harness independently produced
significant claimed verdicts on both moved classes:

| official workload | R | 95% CI | rounds | result |
| --- | ---: | ---: | ---: | --- |
| `mwf_log14x32` | **0.960611** | **[0.951332, 0.970111]** | 15 | significant |
| `mplonk_log14` | **0.9437** | **[0.9319, 0.9534]** | 15 | significant |

Matched profiles moved FRI from 2.096 to 1.858 ms wide and 1.908 to 1.617 ms
deep. A strict runtime-event capture shows exactly one untimed line-cache miss
with 45 grids; the next twelve cascades retain the established 32 grids. The
circle fill is likewise warmup-only. A fresh log-18 stack sample contains no
FRI coset iterator or batch inversion.

## Validation and control

A device differential compares host and shader-generated inverse-y values on
two shifted cosets, on both cache miss and hit, through the real fold output.
ReleaseFast aggregate and Native Metal lifecycle tests, `metal-check`, source
conformance, formatting, and both deterministic authenticated-AOT tool/probe
suites pass. Fixed hashes remain:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`

Both exact-candidate Metal S3 verdicts pass G1--G5, the pinned Rust oracle, all
twelve impact-mapped guards, and request/RSS budgets. A source-identical
pre-rebase CPU S3 control was additionally neutral at `1.0033
[0.9914, 1.0146]`.

## Caveats

- The `core_metal` board was enabled during the final frontier sync. Its local
  verdicts are still claimed/advisory until the locked judge re-run records
  them.
- Full Metal System Trace is unavailable on this Command-Line-Tools-only host.
  Real device execution, strict encoder counters, stack sampling, exact proofs,
  and topology telemetry provide the mechanism evidence.
- Creating a new authenticated metallib still requires a full Metal toolchain
  elsewhere. ABI-5 AOT tool/probe contracts pass, and such a bundle remains
  loadable on this Mac without Xcode.
