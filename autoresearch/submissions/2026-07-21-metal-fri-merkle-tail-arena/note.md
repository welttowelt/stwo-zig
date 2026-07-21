# Fuse shallow FRI Merkle levels inside one Metal threadgroup

## Model and harness

GPT-5 Codex optimized clean candidate `e6aea4a37f5a` from recorded predecessor
`564cea426cf4` on an Apple M5 Max running macOS 26.5.2. Native Metal evidence
uses the real ReleaseFast `native-proof-bench-metal` product, functional
protocol, independent proof verification, and `--metal-runtime source-jit`.
Zig embeds the MSL and macOS compiles it with `newLibraryWithSource`; source
compilation is backend initialization and is excluded from timed proofs.

The manifest still has no enabled Metal scoring workload. Attached S3 verdicts
are honest CPU no-regression controls; the performance claim below comes from
the production-compatible Native Metal binary and is not labeled as CPU-board
credit.

## Hypothesis

Fresh profiling placed the line-FRI cascade at about 3.65 ms of device time and
169 dispatches on wide. The cascade already uses one command buffer, but it
builds thirteen geometric Merkle trees with one buffer allocation and one
dispatch per logical level. Once a tree reaches at most 256 parents, every
remaining level fits in one threadgroup and needs only threadgroup barriers,
not repeated grid dispatches.

The repository already had an exact `blake2s_parent_tail_sparse` kernel for
that reduction. FRI could not use it because its levels lived in separate
buffers, while the tail kernel consumes offset-addressed levels in one arena.
The prediction was fewer dispatches and Objective-C allocations with unchanged
hashing, transcript order, proof bytes, command-buffer count, and fallback
behavior.

## Changes

The resident line-FRI runtime now allocates one 256-byte-aligned arena for the
transcript plus every logical Merkle level. Returned tree handles retain the
same arena with exact per-level word offsets and lengths, which the existing
root, layer-copy, selective-decommit, and destruction paths already support.

Large parent levels still use the established grid kernel. The first level
with at most 256 parents begins one `blake2s_parent_tail_sparse` dispatch,
which holds hashes in threadgroup memory and reduces through the root. A
single-level tail is left on the original path. No MSL, C ABI, shader export,
pipeline identity, protocol, arithmetic, transcript, or generic prover code
changed.

The focused five-layer parity test now expects 30 rather than 45 dispatches
and still compares every root, transcript challenge, terminal evaluation, and
channel state with CPU. During development, a missing leaf-arena offset was
caught because it overwrote the transcript header; Metal GPU validation and
the fixed proof hashes verified the corrected offset-aware binding.

## Results

Seven clean paired rounds per class alternated A-B / B-A process order. Every
process used ten warmups and seven timed verified proofs. Ratios use the
repository's round-median Hodges--Lehmann estimator and deterministic
100,000-resample bootstrap intervals.

| class | predecessor | candidate | B/A (95% CI) | result |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.888 ms | 2.732 ms | 0.9572 [0.9430, 1.0296] | 4.28% estimate |
| wide `wf_log14x32` | 11.990 ms | 11.859 ms | 0.9854 [0.9651, 1.0018] | 1.46% estimate |
| deep `plonk_log14` | 7.571 ms | 7.210 ms | 0.9489 [0.9352, 0.9587] | 5.11% confirmed |

The suite geometric-mean ratio is 0.9637, about 3.63% less latency. Deep is the
confirmed claim: all seven pairs improve and its upper confidence bound is
0.9587. Small and wide intervals cross one and are not overclaimed.

Debug GPU attribution shows wide line-FRI dispatches falling 169 -> 93 and its
steady device timestamp moving from about 3.65 to 3.37 ms. The command remains
one compute encoder, one command buffer, and one wait. The arena also replaces
roughly one hundred per-level Metal buffer objects at the fixed wide/deep
shape.

All 294 formal timed proofs independently verified, were byte-identical within
each process, matched across arms, reported `accelerated_without_fallbacks`,
used zero CPU fallbacks, and retained one line-FRI epoch. Fixed hashes are:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`

## Official controls and validation

Fresh CPU S3 controls for all moved classes passed G1--G5, the pinned Rust
oracle, proof-digest checks, request/RSS budgets, and all 12 regression guards.
They are neutral as expected for Objective-C compiled only into Metal:
small 1.0114 `[0.9886, 1.0256]`, wide 1.0077 `[0.9930, 1.0144]`, and deep
0.9925 `[0.9847, 1.0019]`.

Validation passes `zig build test`, `test-native-metal`, `metal-check`, both
authenticated-AOT core compile/probe gates, source conformance, diff checks,
Metal API/GPU validation, exact fixed proofs, and the modified cascade parity
test. Broad `metal-test` is 80/83 with two expected skips and only the same
pre-existing resident-policy assertion at `resident_data_test.zig:616`.

## Caveats

- No enabled Metal judge workload exists, so this cannot receive Metal-board
  credit until the harness exposes one.
- Full Metal System Trace is unavailable because this host has Command Line
  Tools rather than full Xcode. Real source-JIT execution, GPU timestamps,
  stage profiles, validation layers, and mechanism telemetry support the
  attribution.
- The single shared arena selects shared storage. This is the same storage mode
  the predecessor selected for every level on the target unified-memory Apple
  GPU; no claim is made for discrete Intel-era Macs.
