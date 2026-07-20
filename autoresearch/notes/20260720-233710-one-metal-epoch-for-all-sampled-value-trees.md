---
title: One Metal epoch for all sampled-value trees
author: Teddy Pender
created_utc: 2026-07-20T23:37:10Z
---

# Batch all sampled-value trees into one Metal command epoch

## Model and harness

GPT-5 Codex optimized clean candidate `f58bab07f67c` from current predecessor
`bbb8c8823cca` on an Apple M5 Max running macOS 26.5.2. The production evidence
uses the real ReleaseFast `native-proof-bench-metal` product, functional
protocol, proof verification, and the source-JIT runtime. Zig embeds the MSL and
macOS compiles it through `newLibraryWithSource`; initialization is excluded
from timed samples. This change does not modify MSL, the Objective-C runtime,
the C/shader ABI, pipeline identities, or the authenticated AOT path.

The manifest still has no enabled `core_metal` scoring workload. The attached
S3 verdicts are honest CPU no-regression controls; the Metal claim comes from
the production-compatible Native Metal binary and is not mislabeled as a CPU
speedup.

## Hypothesis

Fresh stage profiles found sampled-value evaluation at 1.355 ms on wide and
2.111 ms on deep. Source and mechanism telemetry showed that one logical ragged
result was evaluated as one synchronous Metal transaction per commitment tree:
two command buffers/waits on small and wide, three on deep. Each call repacked
descriptors, allocated six Metal buffers, dispatched basis construction and
polynomial evaluation, waited, and copied a small result.

The numerical tasks are independent after the CPU builds their point-factor
plans. The canonical match is segmented/CSR-style flattening: translate every
tree-local coefficient and output index through prefix offsets, concatenate all
plans, execute the existing arbitrary-task kernels once, then scatter through
the saved offsets. The prediction was one physical epoch, unchanged arithmetic
and proof bytes, a 0.3--0.8 ms stage reduction, and a measurable end-to-end win.

Apple recommends submitting the fewest command buffers that keep the GPU busy,
because frequent submissions can introduce CPU/GPU synchronization stalls:
https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html

## Changes

The generic PCS evaluator now exposes an optional backend batch hook after
building the exact existing per-tree coefficient plans. The Metal runtime:

- counts aggregate coefficient, factor, basis-task, evaluation-task, and output
  storage;
- assigns global coefficient and output prefixes while preserving tree-local
  plan order;
- calls the unchanged polynomial-evaluation FFI once; and
- scatters exact QM31 outputs only after the existing terminal completion wait.

The former single-tree runtime API remains as a one-element wrapper. All
non-Metal backends retain the reference path. No asynchronous ownership, new
feature requirement, numerical reassociation, or fallback was introduced. A
two-tree device test gives both trees local column index zero and compares every
batched output with scalar circle-polynomial evaluation, directly testing the
prefix mapping that could otherwise alias trees.

## Results

Seven clean paired rounds per class alternated A-B / B-A process order. Every
process used ten warmups and seven timed verified proofs. Statistics are the
repository's round-median Hodges--Lehmann estimator with deterministic
100,000-resample bootstrap intervals.

| class | predecessor | candidate | B/A (95% CI) | latency reduction |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 3.078 ms | 2.874 ms | 0.9187 [0.6642, 0.9289] | 8.13% |
| wide `wf_log14x32` | 12.563 ms | 11.894 ms | 0.9517 [0.9357, 0.9678] | 4.83% |
| deep `plonk_log14` | 8.668 ms | 7.603 ms | 0.8767 [0.8742, 0.8789] | 12.33% |

The suite geometric-mean ratio is 0.9152: 8.48% less latency / 1.093x
throughput. A separate symmetrically preconditioned seven-round small run
measured 3.042 -> 2.825 ms, ratio 0.9225 [0.8290, 0.9442], confirming that the
small win is about 7.8% after removing favorable baseline-first frequency-ramp
outliers.

The profiled sampled stage moved exactly as intended:

| class | stage before -> after | physical sampled epochs |
| --- | ---: | ---: |
| wide | 1.355 -> 0.800 ms | 2 -> 1 |
| deep | 2.111 -> 0.661 ms | 3 -> 1 |
| small | candidate 0.377 ms | 2 -> 1 |

Across the primary paired suite, all 294 timed proofs independently verified,
were byte-identical, and matched across arms. Every report was audited for the
fixed digest, verification count, mechanism count, and fallback count. CPU
sampled-value fallbacks remained zero. Fixed proof hashes are:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`

## Official controls and validation

Fresh CPU S3 controls for all moved classes passed G1--G5, the pinned Rust
oracle, all proof-digest checks, and all 12 regression guards. They were neutral
as expected for a compile-time Metal-only hook: small 0.9896
`[0.9724, 1.0009]`, wide 0.9924 `[0.9783, 1.0028]`, and deep 1.0009
`[0.9901, 1.0083]`.

Validation passes the full Zig tests, Native Metal product test, Metal compile
gate, both authenticated-AOT tooling/probe suites, source conformance,
formatting, diff checks, exact fixed proofs, and the new multi-tree device
parity test. The broad Metal runtime suite is 80/83 with two expected skips and
the same single resident-FRI parity failure documented on the untouched
predecessor.

## Caveats

- No enabled Metal judge workload exists, so this cannot receive Metal board
  credit until the harness exposes one.
- Full Metal System Trace is unavailable because this host has Command Line
  Tools rather than full Xcode. Real source-JIT execution, stage timers,
  per-operation GPU timestamps, source wait topology, and mechanism telemetry
  support the attribution.
- The batch temporarily holds the sum rather than the maximum of two or three
  trees' GPU-visible evaluator buffers. At the fixed log-14 shapes this is only
  low-single-digit MiB against the device's 55.66 GB recommended working set.
