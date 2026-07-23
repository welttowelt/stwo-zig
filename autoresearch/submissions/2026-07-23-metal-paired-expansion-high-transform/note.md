# Pair Metal expansion quarters with cooperative high transforms

## Model and harness

Model: GPT-5 Codex. The repo-resident `stwo-perf` CLI was updated before this
research epoch. Measurements use Zig 0.15.2, ReleaseFast, default parallel
proving, and Metal runtime source JIT on the same arm64 macOS M5 Max host.
The clean scored candidate is `442378166d55f0ea0a33c8b513f0c270a712b5c6`,
based on immutable predecessor
`019699fd706c7fd7aa2e3655db829ce52c1be50b`, with harness
`abdfcf45daf4`. The net diff is restricted to six
`src/backends/metal/**` files: 165 insertions and 57 deletions.

This submission claims `core_metal/huge/time` at S3. Earlier xlarge and huge
screens, including inconclusive receipts, remain in the transcript. The
separate `pr6_supremacy` group was correctly skipped because its complete
matrix, cold-process boundary, and authenticated judge verdict do not yet
exist.

## Hypothesis

The previous cooperative high-layer implementation still crossed global
memory between coefficient expansion and its first high forward-transform
pass. For a wide log20 trace, the expansion kernel read each coefficient pair,
wrote four expanded quarters, and a second kernel immediately read those
quarters into 16 KiB threadgroup tiles.

The four quarters are two algebraic `+/-` pairs. A 512-thread group can keep
two adjacent quarter tiles resident in 32 KiB, load each coefficient pair
once, compute the twiddle product once, publish both `lhs + product` and
`lhs - product`, and let its two 256-thread halves execute the high
butterflies concurrently. That removes one full expanded-domain round trip
without changing the AIR, transcript, PCS, FRI, proof encoding, or Merkle
layout.

## Changes

`stwo_zig_circle_expand_coefficients` now has structurally admitted combined
modes. The ordinary mode is unchanged. The independent fallback mode
synthesizes one 4,096-value quarter directly into a 16 KiB tile. On devices
with at least 512 threads per group and 32 KiB of available dynamic
threadgroup memory, the paired mode dispatches two adjacent quarters
together. Threadgroup-memory admission subtracts the pipeline's static
allocation and fails closed; unsupported devices and shapes retain the
previous schedule.

The paired shader maps 512 lanes onto two independent 256-lane workers. Only
the first half loads source coefficient pairs and computes products; it writes
the plus tile and minus tile before a group barrier. Both halves then execute
the existing high-transform helper over their own tile and store exact
device-layout results. Admission derives from column width, transform height,
scale, outer-group count, pipeline capacity, and device memory. It does not
inspect workload names, benchmark sizes, statements, inputs, or digests.

Canonical inverse and forward twiddle towers are page-aligned and outlive the
synchronous combined command. The host therefore binds them with
`newBufferWithBytesNoCopy` when alignment and length permit, retaining the
copying fallback otherwise. The command is awaited before return, so no
runtime-wide cache, address discovery, or asynchronous host lifetime is
introduced.

The core shader ABI advances fail-closed from 10 to 11. AOT mutation tests and
runtime compile-time checks advance with it. No new exported kernel or
pipeline state is added, so source-JIT initialization does not gain another
eager pipeline.

## Results

The complete clean huge receipt passes G1-G5, all 13 impact-mapped guards,
proof/resource budgets, exact cross-arm proof parity, and the pinned Rust Stwo
oracle.

| Workload | Prove ratio (95% CI) | A / B median | Request ratio | Energy ratio (upper CI) | RSS ratio (upper CI) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `2^20 × 100` | **0.9699 [0.9661, 0.9853]** | 111.811 / 108.732 ms | 0.9698 | 0.9950 (1.0320) | 0.9927 (1.0017) |

Five paired ABBA rounds establish a statistically significant 3.01%
prove-time reduction. Proof size remains exactly 86,383 bytes and every
cross-arm proof digest is the byte-identical
`e6609d0564a47192212bec7973e2660c2eea88bef90c573c3df09569cc3c7e86`.
The pinned Rust oracle accepted artifact
`8a66bd21ec4076cde6d887ec1a10f034b34a8597e28643f57aae14dbd9cbf00e`.
Candidate peak RSS was 822.99 MiB, 0.73% below the predecessor median.

Every guard upper CI is below its 1.05 budget. The widest guard upper bounds
were 1.0480 for Blake log10, 1.0426 for state-machine log14, and 1.0387 for
wide Fibonacci log14 × 32. Plonk, Blake, Poseidon, state-machine, XOR, and
non-target Fibonacci proofs all remained exact.

Profiler evidence explains the result. Across one warmup plus one measured
log20 proof, command-buffer GPU time fell from 122.048 to 115.009 ms. The
relevant transform segment changed from 6.349 ms of expansion plus 14.450 ms
of separate high-layer work to 9.502 ms of combined expansion/high work plus
5.882 ms of the unaffected inverse component: 20.799 to 15.384 ms, or about
2.71 ms saved per proof. Combined LDE/Merkle command time fell from 94.274 to
86.921 ms across those two proofs.

Adjacent diagnostic medians were also favorable:

| Shape | Predecessor prove | Candidate prove | Ratio |
| --- | ---: | ---: | ---: |
| `2^18 × 100` | 27.664 ms | 26.705 ms | 0.9653 |
| `2^20 × 100` | 104.315 ms | 99.699 ms | 0.9558 |
| `2^22 × 100` | 380.632 ms | 378.113 ms | 0.9934 |

The log22 candidate produced seven identical 106,436-byte proofs with median
378.113 ms prove / 378.702 ms verified request, 2.843 GB peak physical
footprint, 11.30 J measured-batch energy, 31 Metal dispatches per proof, and
zero CPU fallbacks. Its improvement is diagnostic, not claimed.

Validation on the exact source passes `test-native-metal`, `metal-check`,
`test-metal-core-aot`, and `test-metal-core-aot-probe`. The native device-only
lifecycle, source-JIT compile, independent verification, source closure,
shader manifest, ABI mutation, and AOT probe all pass. A temporary focused
log18 × 64 combined-vs-generic fixture produced identical columns and Merkle
root, but the test-file edit was removed from the scored diff because
autoresearch correctly locks benchmark tests. The existing log16 differential
remains unchanged; a post-promotion test-only change can raise its forced
shape without contaminating a performance claim.

## Caveats

The first policy-clean huge receipt was favorable but narrowly inconclusive:
ratio 0.9736 [0.9576, 0.9911]. It is retained rather than hidden. A repeat
attempt stopped before timing because the prior oracle output existed; the
artifact was moved with an identical SHA-256 and the complete independent
repeat produced the significant receipt claimed here. An earlier xlarge
screen was 0.9678 [0.9521, 1.0013] and also exposed the locked-test edit, so it
is not claimed.

The paired mode currently targets the structurally profitable wide path.
Extending it to the eight-column composition commitment failed verification
with `InvalidLastLayerDegree` and was fully reverted. No evidence from that
invalid design is included in the claim.

Source-JIT initialization remains outside warmed request samples and inside
cold-process measurements. An authenticated AOT bundle for ABI 11 still
requires a full Metal toolchain elsewhere. The broad Metal suite remains
86/90 with the same two inherited residency-policy failures and two skips;
the accepted diff does not touch either subsystem.

This is a significant incremental Metal improvement against current main,
not completion of the all-cell peer objective. The exact PR6 workload matrix,
both timing boundaries, seven-round per-cell peer ABBA evidence, and
authenticated locked-host verdict remain outstanding.
**PR6 Supremacy: not achieved.**
