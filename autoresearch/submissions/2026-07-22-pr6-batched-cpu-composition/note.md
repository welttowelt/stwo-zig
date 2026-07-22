# Batched wide AIR composition across CPU lanes

## Model and harness

GPT-5 Codex used `stwo-perf` harness `4c483c015b6e` on the Apple M5 Max host. The clean ReleaseFast candidate is `fe58e5786e38` over promoted predecessor `a77e59d43ec1`. The promotion-grade scope is S3: complete verified proof transactions, paired counterbalanced processes, full affected guard portfolio, and pinned Rust Stwo oracle.

## Hypothesis

The pre-change stage profile showed that the single-component width-100 AIR spent 278.356 ms of a 636.020 ms log20 proof in a serial composition-domain loop. Existing generic parallelism works across components and therefore cannot help this workload. ClementWalter/stwo PR #6's `BatchCpuDomainEvaluator` supplied the exact canonical match: evaluate consecutive rows in SIMD batches and partition independent rows across worker chunks. The predicted falsifier was a composition stage still above 100 ms, missing NEON codegen, or any full-domain/reference mismatch.

## Changes

The new CPU-backend hook:

- admits only a conservative one-component, no-preprocessed, constant-stride recurrence shape with at least 64 columns and trace log >=16;
- evaluates four consecutive rows with the live packed M31 operations and partitions disjoint row intervals over the existing bounded work pool;
- rolls recurrence squares forward, avoiding the generic loop's repeated square of every interior state;
- preserves random-coefficient order, the two canonical coset denominator halves, coordinate layout, and every transcript-visible value;
- evaluates the complete generic and candidate domains on first excluded warmup and permanently admits the vtable only after byte equality; every other AIR stays on the generic path.

Only `src/backends/cpu_scalar/**` changes. No AIR, protocol, benchmark, oracle, resource admission, proof codec, Metal backend, or locked path changes.

## Results

The governed CPU `huge` width-100/log20 prove median falls from 623.322 ms to 370.501 ms. The paired ratio is **0.595877** with 95% CI **[0.593967, 0.596739]**: 40.4% less prove time, or 1.68x faster. All three A-B-B-A rounds win.

The full request ratio is 0.751006 even though input generation is intentionally unchanged. Proof size is exactly 86,383 bytes (ratio 1.0). Peak-RSS ratio is 1.003655 with upper CI 1.014365; energy ratio is 0.996702 with upper CI 1.003280.

Every timed proof independently verified, cross-arm canonical bytes were identical, and the pinned Rust Stwo oracle accepted the objective. All 13 affected AIR guards passed. In particular, the width-64/log16 guard improved to ratio 0.540885, CI [0.521426, 0.552034]; every unrelated Blake, Plonk, Poseidon, state-machine, small/wide Fibonacci, and XOR guard remained below its 1.05 upper-CI budget.

The post-change profile measures composition evaluation at 18.974 ms, a 14.7x stage reduction. A live-source `stwo-prof` assembly check reports 66.0% NEON in the packed hot symbol, so the SIMD claim is codegen-backed. Direct ten-warmup/seven-sample probes measured log16 at 23.971 ms and log18 at 85.231 ms, with all proofs verified and byte-stable. ReleaseFast prover/native-product/downstream test closures pass.

## Caveats

The result is intentionally CPU-specific and does not claim a Metal movement; the preceding merged PR #74 carries the Metal recurrence gain. Log16 now clears the user's PR6-margin target, while log18 and log20 still require subsequent FFT/commit improvements to meet every all-point target. The local claimed verdict passes G1-G5, but the central locked judge remains the promotion authority.
