# Native CPU/Metal Backend Benchmark, 2026-07-18

Status: complete six-example correctness baseline; 11 of 12 timing rows are headline-valid.

This is the broad Native Stwo suite over Wide Fibonacci, XOR, Plonk, state machine, Blake, and
Poseidon. It measures the shared Zig proof transaction and makes no Cairo or SN PIE claim.

## Contract

- Revision: `44a81457` (`Complete streaming commitment stage profiles`).
- Build: Zig 0.15.2 `ReleaseFast`, parallel proving enabled, fresh Zig cache, Apple M5 Max.
- Protocol: functional Blake2s, PoW 10, blowup 1, three queries, fold step 1.
- Sampling: ten verified warmups and ten measured proofs per lane and row.
- Scheduling: CPU/Metal lane order alternates by row; rows and lanes execute sequentially with a
  one-second cooldown.
- Correctness: all 240 measured proofs verified; every lane was byte-stable; CPU and Metal emitted
  identical canonical proof bytes for all 12 rows; the pinned Rust Stwo oracle accepted every row.
- Timing: a row is diagnostic-only when its ordered samples exceed the five-percent drift gate.
  Timing eligibility never weakens exact proof acceptance.

## Results

`Total` is the complete verified request: input construction, proving, canonical proof encoding,
and verification. MHz uses each workload's declared native unit and is comparable only between
lanes for the same row. RSS is process peak RSS.

| Workload | CPU prove | CPU total | CPU MHz | CPU RSS | Metal prove | Metal total | Metal MHz | Metal RSS | Metal speedup | Evidence |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| Wide Fibonacci log14 x 32 | 16.726 ms | 17.703 ms | 0.980 | 24.6 MiB | 19.738 ms | 20.696 ms | 0.830 | 41.7 MiB | 0.85x | headline |
| Wide Fibonacci log16 x 64 | 89.311 ms | 102.530 ms | 0.734 | 86.2 MiB | 111.062 ms | 123.908 ms | 0.590 | 133.5 MiB | 0.80x | headline |
| XOR log14 | 11.653 ms | 11.938 ms | 1.406 | 22.7 MiB | 15.809 ms | 16.096 ms | 1.036 | 36.3 MiB | 0.74x | headline |
| XOR log16 | 29.569 ms | 30.087 ms | 2.216 | 63.2 MiB | 38.135 ms | 38.662 ms | 1.719 | 67.0 MiB | 0.78x | headline |
| Plonk log14 | 12.311 ms | 12.628 ms | 1.331 | 23.5 MiB | 16.183 ms | 16.505 ms | 1.012 | 36.9 MiB | 0.76x | headline |
| Plonk log16 | 30.410 ms | 30.977 ms | 2.155 | 62.2 MiB | 39.349 ms | 39.929 ms | 1.666 | 70.6 MiB | 0.77x | headline |
| State machine log14 | 11.682 ms | 11.939 ms | 1.402 | 23.8 MiB | 15.915 ms | 16.179 ms | 1.029 | 37.1 MiB | 0.73x | headline |
| State machine log16 | 29.419 ms | 30.048 ms | 2.228 | 61.8 MiB | 38.320 ms | 38.942 ms | 1.710 | 67.1 MiB | 0.77x | headline |
| Blake log10 x 10 rounds | 34.851 ms | 38.464 ms | 0.294 | 49.9 MiB | 35.982 ms | 39.570 ms | 0.285 | 52.0 MiB | 0.97x | headline |
| Blake log12 x 16 rounds | 112.413 ms | 140.604 ms | 0.583 | 223.6 MiB | 116.459 ms | 144.800 ms | 0.563 | 186.2 MiB | 0.97x | headline |
| Poseidon log10 instances | 6.399 ms | 7.670 ms | 0.160 | 21.5 MiB | 9.739 ms | 11.044 ms | 0.105 | 38.3 MiB | 0.66x | diagnostic |
| Poseidon log13 instances | 45.520 ms | 52.378 ms | 0.180 | 57.1 MiB | 47.021 ms | 53.993 ms | 0.174 | 68.9 MiB | 0.97x | headline |

## Interpretation

All 12 rows satisfy proof stability and cross-backend/Rust correctness. Poseidon log10 is excluded
only because the Metal ordered prove-time series drifted by more than five percent. The current
Metal backend remains `metal_hybrid`: it proves real device dispatch and names every CPU fallback,
but it is not yet faster than CPU on this matrix. Blake and large Poseidon are close to parity;
narrow work and Wide Fibonacci remain CPU-favored.

The checked v4-to-v5 delta is comparable. Across the nine rows that are headline-valid in both
runs, geometric-mean prove time regressed by 10.36% on CPU and 11.27% on Metal; complete request
time regressed by 9.57% and 10.10%, respectively. These are observed clean-run deltas, not an
attribution to one change. They establish the optimization baseline rather than a speedup claim.

The bounded six-workload profile is diagnostic-only and separate from MHz evidence. It records
CPU samples, complete host root stages, Metal command timing for all rows, and stage-boundary
encoder timestamps for Blake. Streaming CPU commitment preparation and finalization are explicit;
per-batch streaming leaf hashing remains inside the parent commitment timer and is a profiling
granularity TODO, not missing proof work.

## Evidence

- Exact report: `vectors/reports/benchmark_history/reports/native_proof_cross_backend_matrix_v5/3e3cf347fe958b822558e7c614b5f11317187f321d412fbd4a834d551b81d78b.json`
- Raw matrix bundle: `vectors/reports/benchmark_history/matrix_bundles/native_proof_matrix_bundle_v1/8904754e1be42115f1c14ab86c4f41c646b26a37ce52a1782b58f4c6f7a4fea5/`
- Comparable delta: `vectors/reports/native_proof_broad_delta_44a81457.json`
- Immutable delta SHA-256: `935452a7f710c885cff681fa6f374c23e9136d1df179adbfa13412491e02ecbd`
- Profile manifest: `vectors/reports/native_profile_baseline_44a81457/manifest.json`
- Profile manifest SHA-256: `c22fcae00416385a8ca3d5b0535c4650bb3d0c1e074de5103f65eed5b77c5d32`
- Native Rust oracle revision: `a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`
- Rust oracle binary SHA-256: `b8b8d824fa54db7091d77918f2f72c470b5fa372d65e9d5a9c91638536b57697`
