# De-alias wide column storage across CPU and Metal

## Model and harness

GPT-5 Codex optimized candidate `715e37c89da6` against exact predecessor
`bca6540a3fbe` on an Apple M5 Max. The repository CLI was updated before the
search. Final evidence uses harness `a9bf238c4fdc`, ReleaseFast products, five
paired ABBA rounds, ten post-initialization warmups, independent verification,
and the pinned correctness oracle.

Metal uses the production `source-jit` variant on this host. Zig embeds the MSL
source, the macOS runtime compiles it through `newLibraryWithSource`, and that
initialization is outside the timed samples. Every measured Metal request
reported zero CPU fallbacks.

## Hypothesis

Profiles showed an unexpected split in the wide 100-column workload. CPU
xlarge spent about 111 ms in composition, while Metal xlarge spent about
344 ms in the same host-side composition evaluator even though its AArch64
loop was equivalent. The evaluator walks one row across 100 column-major
arrays. At log18 after blowup, adjacent logical columns began exactly 2 MiB
apart:

```text
row r -> col0[r] -> col1[r] @ +2 MiB -> ... -> col99[r]
          same cache-set/page-offset pattern on every stream
```

The power-of-two stride made the 100 simultaneous streams conflict in cache
and translation structures. Rotating successive streams by one cache line
should remove the conflict while preserving logical column contents. The
expected signature was a large composition-stage improvement at 100 columns,
neutral narrow guards, identical proof bytes, and no Metal fallback.

## Changes

Each wide column now receives one 64-byte line of padding, changing the stride
to `2 MiB + 64 B` while preserving each public column slice and every logical
value. The CPU path applies this only to 65--256-column batches; this targets
the scored wide shape without perturbing the repeated 64-column
Blake/Poseidon batches.

CPU transforms its owned coefficient columns in place and retains a pooled
skewed evaluation arena. Metal keeps coefficients separately releasable and
places the skewed evaluations in a page-rounded shared arena. Offset-aware
circle-LDE kernels preserve the fused scale, expansion, and top-two forward
layers. The commitment tree hashes logical slices directly from their retained
backing instead of repacking the skewed layout. The changed shader interface is
covered by core ABI version 7, so an incompatible authenticated AOT bundle
fails closed.

The initial layout win exposed a second boundary. In the raw FRI quotient
upload, only the first skewed column was page-aligned; Metal therefore copied
the other 99 two-megabyte columns. Live lifetime-peak probes isolated the jump
to FRI quotient commit: 438 MiB before the stage and 663 MiB after it. The
runtime now aliases the page-aligned VM envelope surrounding each logical
column and binds its exact byte offset. This removes the copies without
changing shader indexing or ownership. Metal xlarge peak RSS returned to
516.923 MiB, ratio 0.999577 against the predecessor.

## Results

| board / class | predecessor median | candidate median | paired R (95% CI) | paired improvement |
| --- | ---: | ---: | ---: | ---: |
| CPU xlarge `wf_log18x100` | 216.379 ms | 166.644 ms | 0.770148 [0.764104, 0.773767] | 22.99% |
| CPU huge `wf_log20x100` | 814.947 ms | 709.311 ms | 0.862618 [0.850738, 0.908437] | 13.74% |
| Metal xlarge `mwf_log18x100` | 407.538 ms | 160.480 ms | 0.390284 [0.380132, 0.397715] | 60.97% |
| Metal huge `mwf_log20x100` | 1396.273 ms | 609.984 ms | 0.454118 [0.402681, 0.559136] | 54.59% |

CPU energy ratios are 0.929222 and 0.960105. Metal energy ratios are 0.579504
and 0.636679. Peak-RSS ratios are 0.997810, 1.007619, 0.999577, and 1.000019,
respectively. Proof sizes remain exactly 74,328 bytes at xlarge and 86,383
bytes at huge.

All four verdicts pass G1--G5 and all 13 regression guards. Every timed proof
verified, cross-arm proof digests were byte-identical in every round, and the
pinned oracle accepted all four objective workloads.

## Validation and rejected alternatives

The complete 361-source ReleaseFast closure passed. The Native Metal product
test passed its device-only prove, independent verify, product-marker, and
233-source closure checks. Small/wide/deep correctness screens remained exact,
and Metal telemetry remained accelerated without fallbacks.

Several hypotheses were falsified during the search. AArch64 code generation
was not the source of the Metal-host gap. QoS, delay, spin, fixed-buffer gather,
argument-buffer, and scalar-M31 variations did not produce a durable complete-
proof improvement. Narrowing the Merkle alias alone did not explain the peak.
Bypassing the backing-aware Merkle path raised peak RSS to about 760 MiB and was
rejected. The decisive resource fix was the page-envelope quotient alias,
identified only after stage-by-stage lifetime-peak instrumentation.

## Caveats

The layout policy is intentionally limited to 65--256 same-log columns; other
shapes retain the prior layout. The measurements use Metal runtime source-JIT,
with pipeline creation outside timed samples, rather than an AOT metallib. Two
initial huge suites each observed one noisy unchanged small guard; clean
sequential reruns passed all guards without a source change, and only those
passing reruns are claimed.
