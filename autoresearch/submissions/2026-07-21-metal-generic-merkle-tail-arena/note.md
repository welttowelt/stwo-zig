# Pack generic Metal Merkle commitments into tail-fused arenas

## Model and harness

GPT-5 Codex optimized clean candidate `4dd2b795fea1` from recorded predecessor
`f81b2cc64f7f` on an Apple M5 Max with 64 GB unified memory running macOS
26.5.2. Native Metal evidence uses the real ReleaseFast
`native-proof-bench-metal` product, functional protocol, independent proof
verification, and `--metal-runtime source-jit`.

Zig embeds the MSL source and macOS compiles it at initialization through
`newLibraryWithSource`. That initialization is excluded from timed proofs.
This host has Command Line Tools but no offline `metal` compiler, which is not
needed for source-JIT execution. The manifest still has no enabled Metal
scoring workload, so the attached S3 verdicts are honest CPU no-regression
controls; the performance claim below comes from the production Native Metal
binary and is not labeled as CPU-board credit.

## Hypothesis

Fresh profiles placed generic main and composition commitments at 1.767 and
1.701 ms on wide, while the already-optimized quotient and FRI commitments
used offset-addressed arenas and a vetted shallow-parent tail kernel. Generic
commitments still allocated one `MTLBuffer` and launched one parent grid for
every logical Merkle level.

Once a tree reaches at most 256 parents, every remaining level fits in one
threadgroup. Packing all levels into an aligned arena permits the existing
`blake2s_parent_tail_sparse` kernel to reduce those shallow levels through the
root using threadgroup barriers. The prediction was fewer dispatches and Metal
objects in every main/composition commitment, with unchanged hashes, proof
bytes, transcript order, shader ABI, and fallback behavior.

## Changes

The generic Metal commitment runtime now stores every logical Merkle level in
one 256-byte-aligned word-addressed arena. Returned tree handles retain that
arena with exact per-level offsets and lengths, preserving root reads,
full-layer copies, selective hash reads, batched decommitment, and destruction.
Large parent levels use the established sparse grid kernel. The first eligible
shallow level enters one established threadgroup-local tail dispatch.

A log-14 tree therefore uses five large parent grids plus one tail instead of
fourteen parent grids; log-15 uses six grids plus one tail instead of fifteen.
The arena also replaces 15 or 16 hash buffers with one. A one-leaf tree keeps a
leaf-only path. Unified-memory devices expose the arena root directly;
non-unified devices retain a private arena and explicit 32-byte root readback.

The already-packed quotient tree had one remaining shared-to-shared 32-byte
root blit on unified memory. It now retains its shared arena and root offset
directly, while keeping the private-device fallback. No MSL, C ABI, shader
export, core shader identity, protocol operation, or generic prover code
changed.

## Results

Seven clean paired rounds per class alternated A-B / B-A process order. Every
process ran from its own exact clean checkout with ten warmups and seven timed
verified proofs. Ratios use the repository's round-median Hodges--Lehmann
estimator and a deterministic 100,000-resample percentile bootstrap.

| class | predecessor | candidate | B/A (95% CI) | result |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.687 ms | 2.709 ms | 0.9949 [0.7840, 1.0458] | neutral |
| wide `wf_log14x32` | 11.936 ms | 11.800 ms | 0.9845 [0.9589, 0.9970] | 1.55% confirmed |
| deep `plonk_log14` | 7.258 ms | 7.135 ms | 0.9812 [0.9270, 0.9899] | 1.88% confirmed |

The suite geometric-mean ratio is 0.9869, about 1.31% less proof latency.
Wide won 6/7 pairs and deep won 7/7. Small is not overclaimed; two opposite
cold-state excursions widened its interval, and no round was deleted.

Three additional clean alternating profiled pairs tied the result to the
target path on Plonk: median main Merkle time fell 0.419 -> 0.390 ms, total
main commit 0.680 -> 0.650 ms, and composition commit 0.777 -> 0.744 ms.
Untouched sampled evaluation remained 0.662 -> 0.662 ms and FRI was effectively
flat at 3.778 -> 3.773 ms.

All 294 formal timed proofs independently verified, were byte-identical within
each process, matched across arms and rounds, reported
`accelerated_without_fallbacks`, and used zero CPU fallbacks. Fixed hashes are:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`

Frozen validation passes `zig build test`, `test-native-metal`, `metal-check`,
`metal-test`, source conformance, both authenticated-AOT core compile/probe
contract tests, diff checks, exact complete proofs, and a proof with both
Metal API and GPU shader validation enabled. Fresh CPU S3 controls passed
G1--G5, the pinned Rust oracle, cross-arm proof checks, request/RSS budgets,
and impact-mapped guards. They are neutral as expected: small 1.0134
`[1.0020, 1.0350]`, wide 1.0102 `[0.9993, 1.0231]`, and deep 1.0008
`[0.9934, 1.0106]`.

## Caveats

- No enabled Metal judge workload exists, so the current harness cannot award
  Metal-board credit. The attached CPU verdicts are controls, not the source
  of this performance claim.
- Full Metal System Trace is unavailable without the full Xcode application.
  Real source-JIT execution, stage profiles, validation layers, exact proofs,
  and source-visible dispatch topology provide the local attribution.
- This Apple GPU executes the unified-memory branch. The private-storage root
  copy compiles and retains its prior contract but cannot be exercised here.
- AOT shader compilation requires an offline Metal toolchain elsewhere. The
  deterministic AOT tooling and acceptance-probe contracts pass, and this
  change does not alter shader artifacts or their ABI.
