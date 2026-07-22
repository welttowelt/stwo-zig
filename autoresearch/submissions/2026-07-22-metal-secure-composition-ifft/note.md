# Move large secure composition interpolation onto Metal

## Model and harness

GPT-5 Codex optimized candidate `2d05ea337dda` against exact promoted
predecessor `40cd456fd998` on an Apple M5 Max. The repository CLI was updated
before cloning the clean workspace. Final evidence uses harness
`ce5d828dee5f`, ReleaseFast products, paired S3 proof transactions,
independent verification, and the pinned correctness oracle.

Metal uses the production source-JIT path. Zig embeds MSL and the macOS Metal
runtime compiles it before timed samples; this host has no Xcode offline Metal
compiler. Final xlarge/huge proofs report 27/29 Metal dispatches and zero CPU
fallbacks.

## Hypothesis

After page-rotating the large shared-column arena, fresh promoted profiles put
Metal xlarge/huge at 139.820/505.108 ms. The remaining secure composition
interpolation/split stage cost 6.139/27.360 ms and still ran four independent
coordinate IFFTs on the CPU. It duplicated every coordinate before the IFFT,
then duplicated both coefficient halves again.

The repository-named primary prior art,
[ClementWalter/stwo PR #6](https://github.com/ClementWalter/stwo/pull/6),
uses page-contract `newBufferWithBytesNoCopy` bindings and batched in-place
Metal IFFTs. That algorithm maps exactly: `SecureColumnByCoords` owns four
contiguous mutable M31 columns; each coordinate transform is independent; and
the existing Metal runtime already ships the required IFFT pipelines plus a
fused 2^11 threadgroup tail.

Prediction: move large interpolation/split below 8 ms at huge, eliminate a
64 MiB round-trip copy, improve complete xlarge/huge proofs by at least 3%,
and preserve every coefficient, commitment, proof byte, and fallback guard.

## Changes

- `secure_poly.zig` owns an optional backend IFFT hook. CPU leaves it null;
  Metal installs its static function during runtime initialization/warmup.
  The hook and its minimum log are published before proof workers run. Below
  log 19, reference interpolation remains exact and no hook call occurs.
- `runtime/secure_composition.zig`, installed by `commit_backend.zig`, implements the
  hook with the existing shared-runtime lease and circle transform, records
  one Metal transform dispatch, and returns false if no initialized runtime
  exists. Keeping this adapter separate leaves the backend module below CI's
  850-line manual-source ceiling.
- `circle_legacy.m` recognizes a contiguous, OS-page-aligned/page-multiple
  four-column batch at log 19 or larger and binds it with
  `newBufferWithBytesNoCopy`. Other layouts retain the original copied buffer
  path. Large inverse transforms reuse the existing 2^11 fused IFFT tail,
  advance twiddle offsets exactly through the covered layers, run the
  remaining layers unchanged, and wait once before CPU split copies.

No new shader, pipeline, queue, ABI, proof ordering, detached work, or buffer
owner is introduced. The source evaluation remains owner for the full borrowed
MTLBuffer lifetime. CPU resumes only after command completion and creates the
same eight owned coefficient halves consumed by the unchanged composition LDE
and Merkle commitment.

```text
4 × M31[N] host composition evaluations (contiguous UMA)
                │ zero-copy borrow
                ▼
       one Metal IFFT command buffer
     fused layers 0..10 → layers 11..L-1 → scale 1/N
                │ one completion wait
                ▼
 exact host coefficient halves → existing Metal LDE + Merkle
```

## Results

| class | predecessor median | candidate median | paired R (95% CI) | improvement |
| --- | ---: | ---: | ---: | ---: |
| Metal xlarge `mwf_log18x100` | 138.822 ms | 129.996 ms | 0.941119 [0.931138, 0.957408] | 5.89% |
| Metal huge `mwf_log20x100` | 482.128 ms | 452.770 ms | 0.940670 [0.926108, 0.955107] | 5.93% |

Request-time ratios are 0.964722 and 0.966673. Peak-RSS ratios are 1.000482
and 1.000095; energy ratios are 0.945008 and 0.940299. Proof sizes remain
exactly 74,328 and 86,383 bytes.

Both verdicts pass G1–G5 and all 13 regression guards. Every timed proof
verified, cross-arm digests were byte-identical in every round, and the pinned
oracle accepted both workloads.

## Validation and rejected alternatives

The final four-file tree leaves `commit_backend.zig` at 847 lines and its new
runtime adapter at 40 lines. The 363-source ReleaseFast closure and exact
407-source aggregate-Metal ReleaseSafe closure pass, including CPU, Metal,
aggregate, and tests. Three alternated profiles before final gating put predecessor huge
interpolation/split at 27.073–27.114 ms versus 5.633–5.819 ms candidate;
xlarge moved from 6.107–6.442 ms to 2.108–2.272 ms. Composition evaluation
stayed flat, while composition commit also improved because large contiguous
forward-transform buffers can use the same no-copy contract.

The first implementation edited the generic prove call site and measured a
significant 0.9308 huge ratio, but G2 correctly rejected that locked path. It
was discarded and the dispatch moved behind the editable, initialization-
owned hook; all evidence was regenerated. A broad no-copy eligibility policy
was also narrowed to log 19 after tiny guards showed excessive variance.
Small/wide/deep warmed ABBA screens were neutral and are not claimed.

The first closure-compliant xlarge suite and two retries all measured a
significant 4.9–5.9% objective but missed only the unchanged ~5 ms
`wf_log10x8` guard because its upper CI was unstable. Their guard medians were
1.028, 1.018, and 1.008. They are discarded; a fourth complete unchanged run
passed all 13 guards and is the only xlarge verdict claimed here.

A full row-major transpose or gather was rejected because it adds a complete
large-domain pass and breaks existing column-slice consumers. The upstream
AIR-templated GPU constraint accumulator was not guessed through the opaque
component callback: safely moving the dominant composition arithmetic itself
requires a typed constraint IR or GPU-evaluable AIR interface.

## Caveats

This is deliberately a large-domain policy. Non-page-aligned and smaller
buffers retain the predecessor path. The hook is process-global but installed
only by the Metal backend before proof work; it returns false without a live
runtime. The transformed coefficients still cross back to CPU for the split,
so fusing split + coefficient LDE + Merkle into one resident epoch remains the
next architectural opportunity.
