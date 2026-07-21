# Keep quotient domains resident on Metal

## Model and harness

GPT-5 Codex optimized clean candidate `b63898f4a2f7` from exact current
predecessor `483275c35d73` on an Apple M5 Max. The repository CLI was updated
before research, a fresh workspace passed setup, and the full fixed Native
Metal suite was run locally before source changes.

Metal evidence uses the real ReleaseFast `native-proof-bench-metal`, functional
protocol, independent verification, and `--metal-runtime source-jit`. Zig
embeds the MSL and macOS compiles it through `newLibraryWithSource`; runtime
initialization is outside the ten warmups and seven measured samples. No full
Xcode installation or offline `metal` compiler is assumed.

## Hypothesis

The prior frontier removed logarithmic point reconstruction, but every proof
still walked the entire quotient domain on the CPU, allocated two arrays,
copied them into two Metal buffers, and discarded them. A five-second log-18
sample attributed roughly 55 main-thread samples to that linear iterator versus
23 waiting for the quotient command.

Quotient-domain coordinates depend only on `(row_count, log_size,
initial_index, step_size)`, not the witness or transcript. The existing
authenticated `stwo_zig_quotient_domain_points_resident` kernel can generate
them once during the excluded warmups. A bounded device cache should therefore
remove all recurring host generation and upload without changing proof bytes
or the measured Metal schedule.

## Changes

`StwoZigMetalRuntime` now retains one combined x/y domain buffer and its exact
four-field key. Log-13-and-larger quotient calls look it up under synchronization.
On a miss, the existing domain kernel fills `2*N` shared words before the
quotient grid in the same command; the runtime publishes the buffer only after
successful completion. On a hit, quotient kernels bind x and y as two offsets
of that buffer. Local strong references make replacement safe, and concurrent
misses can duplicate bounded work without exposing partial data. Fixed log-15
proofs retain 256 KiB; a shape change replaces it.

Small domains keep the predecessor's indexed host path because their preparation
is below the useful crossover. Shader source, exported shader inventory,
function constants, authenticated-AOT shader ABI, quotient arithmetic,
commitments, transcript order, and proof encoding are unchanged.

## Results

Fifteen clean process pairs per class alternated A-B/B-A. Each process performed
ten verified warmups and seven timed verified proofs. Ratios use the repository
Hodges--Lehmann estimator and a deterministic 100,000-resample percentile
bootstrap.

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.610 ms | 2.581 ms | 0.98773 [0.97473, 0.99867] | 11/15 |
| wide `wf_log14x32` | 10.015 ms | 9.795 ms | **0.97209 [0.96003, 0.98597]** | 13/15 |
| deep `plonk_log14` | 5.525 ms | 5.246 ms | **0.95065 [0.94519, 0.95609]** | 15/15 |

The three-class geometric ratio is `0.97004`: **3.00% lower Metal proof
latency**. Wide improves 2.79% and deep 4.93%; small is neutral and is not
claimed as a promoted result. All 90 reports and 630 measured proofs verified,
matched hashes across arms, used clean source-JIT provenance, and had zero CPU
fallback or post-warmup compilation.

Matched stage profiles moved FRI quotient/build/commit from 2.430 to 2.096 ms
wide and 2.156 to 1.908 ms deep, with unchanged 22/24 topology counters. A new
log-18 stack sample contains no quotient-domain iterator beneath the quotient
call: it is almost entirely waiting for Metal. This binds the result to removed
host materialization rather than protocol or GPU arithmetic changes.

The exact-candidate CPU S3 control is neutral at 1.0054
`[0.9978, 1.0123]` and passes G1--G5, guards, and the pinned Rust oracle.
ReleaseFast aggregate and Native Metal lifecycle tests, `metal-check`, source
conformance, formatting, and authenticated-AOT tool/probe tests pass. Metal API
and GPU Validation also pass a cold-cache Plonk proof followed by independent
verification of its fixed 45,200-byte artifact.

## Caveats

- The manifest has no enabled `core_metal` judge workload. The attached
  official verdict is therefore an honest CPU no-regression control; the Metal
  claim is supported by the clean production source-JIT paired evidence.
- The broad Metal suite remains at the known 80/83 host baseline: one resident
  FRI policy assertion fails and two stress tests skip identically on the
  predecessor.
- Full Metal System Trace is unavailable on this Command-Line-Tools-only host.
  Real device execution, stack sampling, stage profiles, validation layers,
  exact proof bytes, and topology telemetry provide the mechanism evidence.
- Creating a new authenticated metallib still requires a full Metal toolchain
  elsewhere. The unchanged AOT contract/probe passes, and such a bundle remains
  loadable on this Mac without Xcode.
