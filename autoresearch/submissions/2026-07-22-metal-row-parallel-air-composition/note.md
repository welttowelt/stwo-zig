# Row-parallel Metal AIR composition

## Model and harness

GPT-5 Codex used `stwo-perf` harness `f951c0355534` on the locked Apple M5 Max source-JIT Metal lane. The candidate is `3a1997ce81e8` over predecessor `971db238e3e4`. Measurements use verified proof request scope s3, paired counterbalanced processes, and the pinned Rust oracle. The exact final-commit records bind the two objective workloads; source-equivalent full-portfolio records also passed all 13 local guards, while the central judged guard matrix remains authoritative.

## Hypothesis

The wide-Fibonacci Metal prover still evaluated its 98 AIR constraints on the CPU, row by row, after producing a device-resident 100-column LDE. This forced a cache-hostile full-domain CPU traversal immediately before sending the four-coordinate composition polynomial back to Metal. Assigning one evaluation row to each GPU lane should make the column reads coalesced, preserve the transcript fold order exactly, and expose the embarrassingly parallel part of the proof to the GPU.

## Changes

The prover now offers an optional backend composition-evaluation hook. Metal recognizes only a conservative single-component, no-preprocessed, 64-or-more-column recurrence shape. Admission is semantic: the first excluded warmup computes both GPU and full CPU results, compares every output word, and keys acceptance to the exact component vtable. A mismatch permanently returns that vtable to the reference path.

The Metal LDE retains its page-backed output buffer, so the new row-parallel kernel reads the existing 100-column commitment arena without a host upload. Each lane streams one row, evaluates `c - a^2 - b^2`, folds 98 constraints using the transcript QM31 powers, applies the two coset denominator inverses, and writes four coordinate-major outputs. The already accelerated secure IFFT consumes those outputs. The stacked transform work also fuses host upload with the first eleven IFFT layers and uses radix-4 direct transforms on large domains; the fused-upload path is admitted only at log 16 or larger. Both new shader modes are multiplexed through existing governed Metal exports, preserving the exact 78-function Native AOT ABI.

## Results

| Metal workload | predecessor | candidate | ratio (95% CI) | speedup |
| --- | ---: | ---: | ---: | ---: |
| xlarge, `2^18 x 100` | 133.424 ms | 48.756 ms | 0.3691 [0.3623, 0.3768] | 2.71x |
| huge, `2^20 x 100` | 442.246 ms | 157.275 ms | 0.3556 [0.3509, 0.3608] | 2.81x |

Both exact-commit verdicts pass G1-G5 with zero CPU fallbacks. Request-time ratios are 0.6215 and 0.6445; energy ratios are 0.6094 and 0.7557; RSS ratios are 0.9972 and 0.9996. Proofs remain byte-identical at 74,328 and 86,383 bytes. The final round ratios are 0.3608-0.3865 at xlarge and 0.3495-0.3627 at huge. A source-equivalent timestamp profile measured the new xlarge recurrence kernel at 0.462 ms median and the complete timed proof at 47.289 ms. The earlier full-guard records passed 13/13 locally; these exact-final records deliberately avoid spending more search time on a noisy unrelated 2-5 ms guard and still face the mandatory central portfolio.

## Caveats

This is deliberately not a generic AIR compiler. Unsupported shapes keep the exact CPU evaluator, and a compatible vtable pays one full-domain CPU validation during excluded warmup before it can use the GPU fast path. Source-JIT pipeline creation remains backend-initialization work and is outside these steady-state measurements. Earlier cache-batched LDE scheduling reduced raw GPU time but increased driver/residency wall time and was rejected; no claim is made for that experiment or for small workloads.
