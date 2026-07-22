# Single-submit Metal circle commitment epoch

## Model and harness

GPT-5 Codex used `stwo-perf` harness `7f58f1c01a28` on the locked Apple M5 Max. The clean ReleaseFast candidate is `1ee9a852b736` over promoted predecessor `505537924cd4`. The claimed objective is the `core_metal/huge` width-100, log20 complete verified proof transaction. Local source-JIT compilation occurs during excluded initialization; the same existing 78-entry-point shader ABI remains eligible for authenticated AOT CI.

## Hypothesis

The pre-change log20 profile placed 96.627 ms in main-trace commitment. Circle LDE used roughly 47 ms of GPU time but 60-64 ms blocking wall, followed by a 7.2 ms GPU Merkle operation taking 21-33 ms blocking wall. The extended evaluations were already resident and had no intervening CPU consumer. Encoding LDE and Merkle into one dependency-ordered command buffer should remove one submission and one completion wait without changing arithmetic, hashes, or proof bytes.

## Changes

The generic PCS driver now exposes an optional precommitted-tree hook. Metal admits it only for retained, blowup-one, uniform 64-256-column trees at base log >=16. The backend creates page-backed coefficient/evaluation arenas and encodes source upload, fused inverse FFT layers, remaining sparse transforms, expansion/forward FFT, Merkle leaves, and all parent levels in one command buffer with one final wait.

The returned tree owns both backing arenas and the resident Merkle allocation. Unsupported shapes and pre-submit failures leave inputs untouched for the generic path; error ownership and arena arithmetic are checked explicitly. No MSL function, protocol parameter, transcript order, hash seed, proof codec, or resource admission rule changes.

## Results

The submission-grade S3 objective falls from 171.866 ms to 162.570 ms. Its paired ratio is **0.9324** with 95% CI **[0.9073, 0.9555]**; all five A-B-B-A rounds win. The complete-request ratio is 0.981918. Peak RSS ratio is 0.999886 and energy ratio is 0.988597 (upper CI 0.990488). Proof size remains exactly 86,383 bytes.

Every timed proof independently verified, every cross-arm digest was byte-identical (`e6609d...c7e86`), the pinned Rust Stwo oracle accepted the artifact, and Metal reported zero CPU fallbacks. A post-change stage profile measured main-trace commitment at 82.616 ms, 14.011 ms below the 96.627 ms predecessor profile. Direct ten-warmup/seven-sample medians were 47.210 ms at log18 and 160.329 ms at log20, clearing the requested concrete PR6-margin targets of 51.85 and 164.38 ms.

Focused prover, native CPU/Metal lifecycle, downstream, AOT-manifest, and AOT-probe closures pass. The broad Metal test has one pre-existing resident-FRI failure: candidate and clean predecessor both produce 81/84 with the identical failing test and two skips.

## Caveats

The claimed verdict intentionally contains objective-only local guards; the central judge still applies the impacted full matrix. Six additional full-portfolio local attempts are preserved beside the transcript. Each had one different high-variance small guard exceed its per-run upper-CI cap, but 72/78 individual decisions passed and every guard's six-run geometric ratio was neutral or favorable (0.9806-1.0056). This is disclosed rather than selecting or editing a guard result.

The formal xlarge run improved with ratio 0.9514 and CI [0.9222, 0.9861], but did not clear that class's stricter significance cutoff and is not claimed. This submission satisfies the current significant Metal-huge promotion gate; it does not claim completion of the broader all-point PR #6 supremacy objective, whose cold-process, log22, and exact Blake/Plonk parity cells remain future work.
