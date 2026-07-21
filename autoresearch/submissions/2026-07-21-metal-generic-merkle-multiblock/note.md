# Parallelize generic Metal Merkle parent chains

## Model and harness

GPT-5 Codex optimized clean candidate `03ec753d0232` from exact promoted
predecessor `35819ff7920d` on an Apple M5 Max.  Before source changes, the
repo-resident CLI was updated, the fixed three-class Metal suite was run
locally, and fresh profiles identified generic main-trace and composition
Merkle commitments as the next shared hot path.

All production measurements use the real ReleaseFast
`native-proof-bench-metal`, functional protocol, independent proof
verification, and `--metal-runtime source-jit`.  Zig embeds the MSL and macOS
compiles it through `newLibraryWithSource`; shader initialization is excluded
from timed post-warmup samples.  No full Xcode installation or offline `metal`
compiler is involved.

## Hypothesis

Large generic commitments still dispatched the lower Merkle levels one at a
time.  A log-14 tree launched five global parent grids before its existing
single-threadgroup top tail.  PR #30 had already proved that the isolated
parent-tail kernel can reduce many independent bottom subtrees concurrently
without the occupancy regression of fusing hash work into a leaf producer.

The predicted architecture was one 128-parent threadgroup per 256 leaves,
writing every required global layer through eight local reduction levels,
followed by the existing upper tail.  A normal large parent chain would move
from six dispatches to two.  Keeping leaf and parent grids in one compute
encoder with explicit buffer barriers would also remove six encoder
boundaries per direct commitment.

## Changes

Prepared generic parent chains now derive an optional multi-block bottom
segment from reflected pipeline/threadgroup limits and arena geometry.  The
fast schedule is enabled only when counts halve exactly, the first count is an
exact multiple of the local width, every bottom destination is pairwise
disjoint, and every destination is disjoint from the complete initial child
range.  This last condition prevents a cross-threadgroup read/write race on
ping-pong storage; aliased layouts retain their conservative schedule.

Bottom, any global middle, and top-tail grids share one compute encoder with
`MTLBarrierScopeBuffers` barriers.  The direct commitment's leaf grid joins
that encoder and barriers before the first parent read.  Buffer layout, every
materialized proof node, hash order, public C ABI, shader source, export
inventory, source-JIT/AOT split, and fallback behavior are unchanged.

## Results

An isolated production `commitColumns` run discards five commits and measures
the following 96, using exact stable roots:

| log-14 commitment | predecessor GPU median | candidate GPU median | reduction |
| --- | ---: | ---: | ---: |
| 32 columns (wide main trace) | 0.091 ms | 0.077 ms | 15.4% |
| 4 columns (composition) | 0.076 ms | 0.062 ms | 18.4% |

Final end-to-end evidence uses fifteen clean process pairs per class,
alternating A-B / B-A order.  Every process performs ten verified warmups and
seven timed verified proofs.  Statistics are the repository Walsh-average
Hodges--Lehmann estimator with deterministic bootstrap intervals.

| class | predecessor | candidate | B/A (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.689 ms | 2.651 ms | 0.99005 [0.98088, 0.99723] | 12/15 |
| wide `wf_log14x32` | 11.578 ms | 11.518 ms | 0.99574 [0.98490, 1.00467] | 9/15 |
| deep `plonk_log14` | 7.026 ms | 6.997 ms | 0.99609 [0.99098, 0.99934] | 9/15 |

The three-class geometric-mean ratio is `0.993954`: about 0.60% less proof
latency / 1.006x throughput.  Small and deep are statistically favorable;
wide is favorable but neutral.  One favorable small frequency-ramp outlier is
retained and disclosed rather than pruned.

Across 90 clean reports, all 630 timed proofs independently verify, remain
byte-identical, and match the fixed digest for each class.  Every report has
the exact expected commit, complete clean provenance, source-JIT admission,
zero post-warmup direct compilation, `accelerated_without_fallbacks`
classification, and zero CPU fallback.

## Validation and official control

A strengthened 2,048-leaf device fixture forces the new schedule, reports one
compute encoder/two parent dispatches, and compares all eleven materialized
levels with scalar Blake2s.  Its aliased ping-pong pass rejects the bottom
schedule, uses barrier-separated globals plus the safe top tail, and produces
the same root.

Native Metal build/lifecycle, independent verification, `metal-check`, source
conformance, core-AOT tooling, AOT acceptance-probe contracts, formatting, and
diff checks pass.  A full Plonk proof passes with Metal API and GPU Validation
enabled.  The broad Metal suite remains at the predecessor's 80/83 baseline:
two expected skips and the same pre-existing resident-policy assertion.

The required CPU S3 deep control passes G1--G5 and the pinned Rust oracle at
1.0043 [0.9952, 1.0122], correctly confirmed-neutral against theta 0.0183.

## Caveats

- The manifest still has no enabled `core_metal` judge workload.  The CPU
  verdict is a no-regression packaging control; the optimization claim comes
  from the clean production Metal evidence and is not mislabeled as CPU gain.
- Full Metal System Trace is unavailable on this Command-Line-Tools-only host.
  Real source-JIT execution, GPU command timestamps, stage profiles, exact
  topology counters, validation layers, and isolated production commitments
  provide the attribution.
- Devices unable to provide the reflected tail capacity, and chains with
  overlapping storage, fail closed to the existing per-level path.
