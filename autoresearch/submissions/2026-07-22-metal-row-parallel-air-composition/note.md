# Row-parallel Metal AIR composition

## Model and harness

GPT-5 Codex used `stwo-perf` harness `81ec9e6b9b99` on the locked Apple M5 Max source-JIT Metal lane. The candidate is `1009418fe0f9` over predecessor `971db238e3e4`. Measurements use verified proof request scope s3, paired counterbalanced processes, the pinned Rust oracle, and the automatic 13-workload guard portfolio.

## Hypothesis

The wide-Fibonacci Metal prover still evaluated its 98 AIR constraints on the CPU, row by row, after producing a device-resident 100-column LDE. This forced a cache-hostile full-domain CPU traversal immediately before sending the four-coordinate composition polynomial back to Metal. Assigning one evaluation row to each GPU lane should make the column reads coalesced, preserve the transcript fold order exactly, and expose the embarrassingly parallel part of the proof to the GPU.

## Changes

The prover now offers an optional backend composition-evaluation hook. Metal recognizes only a conservative single-component, no-preprocessed, 64-or-more-column recurrence shape. Admission is semantic: the first excluded warmup computes both GPU and full CPU results, compares every output word, and keys acceptance to the exact component vtable. A mismatch permanently returns that vtable to the reference path.

The Metal LDE retains its page-backed output buffer, so the new row-parallel kernel reads the existing 100-column commitment arena without a host upload. Each lane streams one row, evaluates `c - a^2 - b^2`, folds 98 constraints using the transcript QM31 powers, applies the two coset denominator inverses, and writes four coordinate-major outputs. The already accelerated secure IFFT consumes those outputs. The stacked transform work also fuses host upload with the first eleven IFFT layers and uses radix-4 direct transforms on large domains; the fused-upload path is admitted only at log 16 or larger.

## Results

| Metal workload | predecessor | candidate | ratio (95% CI) | speedup |
| --- | ---: | ---: | ---: | ---: |
| xlarge, `2^18 x 100` | 133.745 ms | 49.372 ms | 0.3738 [0.3618, 0.3860] | 2.68x |
| huge, `2^20 x 100` | 474.916 ms | 161.796 ms | 0.3433 [0.3330, 0.3561] | 2.91x |

Both verdicts pass G1-G5 and 13/13 guards with zero CPU fallbacks. Request-time ratios are 0.6179 and 0.6252; energy ratios are 0.6195 and 0.7668; RSS ratios are 0.9972 and 0.9996. Proofs remain byte-identical at 74,328 and 86,383 bytes. A timestamp profile measured the new xlarge recurrence kernel at 0.462 ms median and the complete timed proof at 47.289 ms.

## Caveats

This is deliberately not a generic AIR compiler. Unsupported shapes keep the exact CPU evaluator, and a compatible vtable pays one full-domain CPU validation during excluded warmup before it can use the GPU fast path. Source-JIT pipeline creation remains backend-initialization work and is outside these steady-state measurements. Earlier cache-batched LDE scheduling reduced raw GPU time but increased driver/residency wall time and was rejected; no claim is made for that experiment or for small workloads.
