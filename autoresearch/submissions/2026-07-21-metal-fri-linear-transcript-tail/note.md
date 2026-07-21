# Linearize Metal FRI preparation and fuse Merkle roots into transcript draws

## Model and harness

GPT-5 Codex optimized clean candidate `4d4dbdc54c4e` from exact promoted
predecessor `f52e3a791dd7` on an Apple M5 Max. The repo-resident CLI was
updated before the campaign, setup passed in a fresh worktree, and the full
fixed Native Metal suite was benchmarked before source changes.

All performance evidence uses the real ReleaseFast
`native-proof-bench-metal`, the functional protocol, independent proof
verification, and `--metal-runtime source-jit`. Zig embeds the MSL and macOS
compiles it with `newLibraryWithSource`; shader compilation occurs during
backend initialization and is excluded from post-warmup samples. No full
Xcode installation or offline `metal` compiler is used.

## Hypothesis

Fresh profiles put FRI at 3.891 ms on wide and 3.626 ms on deep, the largest
shared Metal stage. Two independent serial costs remained.

First, all four Metal fold orchestration paths still generated inverse
coordinates with `domain.at(bitReverseIndex(i << 1))` for every output. That
reconstructed a circle-group point from index bits at every position—roughly
O(N log N) group work—even though an earlier CPU campaign had already proved
an equivalent linear coset walk.

Second, each of thirteen resident FRI trees finished its one-threadgroup
Merkle tail, then launched separate one-thread root-mix and secure-challenge
grids before the next fold. The root already existed in threadgroup scratch,
so those two serialized launches were an avoidable API boundary.

## Changes

The Metal backend now walks each fold coset once in natural order and scatters
x or y to its bit-reversed destination before the unchanged batch inversion.
Bit reversal is an involution, so the vector is byte-identical to indexed
gathering while coordinate preparation becomes O(N). Circle fold, generic
line fold, fold-plus-commit, and the full resident line cascade all use the
backend-local helper. CPU files and CPU execution are untouched.

The existing group-aware `stwo_zig_blake2s_parent_tail_sparse` kernel gained
an explicit three-word transcript configuration. Generic Merkle tails and
parallel FRI bottom subtrees bind disabled mode. A one-group FRI upper tail
binds the channel and alpha offsets; after materializing the exact root, lane
zero performs the existing Blake2s mix and secure-field draw before the next
fold consumes alpha across the established buffer barrier.

Using the existing entry point preserves the authenticated inventory at 78
Native and 90 aggregate kernels with zero function constants. The changed
binding advances the core shader ABI from 3 to 4; older AOT bundles fail
closed. Unsupported/no-tail layouts retain separate transcript grids.

Production wide/deep FRI topology moves from 58 to 32 physical grids. The
exact log-10 fixture moves from 38 to 20 while retaining one encoder, one
command buffer, and one wait.

## Results

Fifteen clean process pairs per class alternated A-B/B-A order. Every process
performed ten verified warmups and seven timed independently verified proofs.
Ratios use the repository Hodges--Lehmann estimator and deterministic
100,000-resample percentile bootstrap.

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.635 ms | 2.559 ms | **0.9752 [0.9661, 0.9877]** | 13/15 |
| wide `wf_log14x32` | 11.593 ms | 10.871 ms | **0.9371 [0.9315, 0.9435]** | 15/15 |
| deep `plonk_log14` | 7.002 ms | 6.280 ms | **0.8962 [0.8897, 0.9014]** | 15/15 |

The three-class geometric ratio is `0.935616`: **6.44% less proof latency**.
All 90 reports and all 630 timed proofs independently verified, matched across
arms, and retained the fixed class digests. Every report had exact clean
provenance, source-JIT admission, `accelerated_without_fallbacks`, zero CPU
fallback, and zero post-warmup direct compilation.

Seven-sample final profiles attribute the movement to FRI:

| profiled stage | wide A → B | deep A → B |
| --- | ---: | ---: |
| FRI quotient/build/commit | 3.833 → 3.097 ms | 3.609 → 2.922 ms |
| main-trace commit control | 1.833 → 1.831 ms | 0.635 → 0.642 ms |

Thus the FRI stage falls about 19% on both production shapes while an
unrelated Metal stage remains flat. The exact cascade fixture checks every
root, challenge, coordinate column, terminal evaluation, channel digest,
draw counter, and error state against CPU at the predicted 20 dispatches.

## Validation and control

`zig build test`, `test-native-metal`, `metal-check`, source conformance, both
authenticated core-AOT contract/probe suites, formatting, and diff checks
pass. A complete Plonk proof and independent verification pass with Metal API
and GPU Validation explicitly enabled. The broad Metal suite remains at the
predecessor baseline of 80/83: two expected skips and the same known resident
FRI policy assertion.

The required CPU S3 deep control passes G1--G5 and the pinned Rust oracle at
1.0020 `[0.9925, 1.0104]`, correctly confirmed-neutral for this Metal-only
diff. Every changed tracked file is under `src/backends/metal/**`.

## Caveats

- The manifest still has no enabled `core_metal` judge workload, so the CPU
  verdict is a packaging/no-regression control; no CPU-board speedup is
  claimed.
- Full Metal System Trace is unavailable on this Command-Line-Tools-only host.
  Real source-JIT execution, GPU timestamps, stage profiles, exact topology
  counters, validation layers, and byte-identical proofs provide attribution.
- Producing an authenticated AOT metallib still requires a full Metal toolchain
  elsewhere, but the ABI-4 contract and acceptance-probe suites pass and the
  resulting bundle can be loaded on this host without Xcode.
