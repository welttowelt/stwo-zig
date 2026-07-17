# Native CPU/Metal Backend Benchmark, 2026-07-17

Status: verified real-AIR comparison with immutable delta evidence.

This run measures the shared Zig proof transaction over Wide Fibonacci, XOR,
Plonk, state-machine, and Blake workloads. It is the broad raw-Stwo backend
suite, not a Cairo or SN PIE claim.

## Contract

- Baseline: `b6f3a533` (`Measure Metal evaluation library preparation`).
- Current: `e2613ba5` (`Pin the real AIR Rust benchmark oracle`).
- Build: Zig 0.15.2 `ReleaseFast`, parallel proving enabled, Apple M5 Max.
- Protocol: functional Blake2s, PoW 10, blowup 1, three queries, fold step 1.
- Sampling: ten verified warmups and five measured proofs per lane and row.
- Scheduling: CPU/Metal lane order alternates by row; rows run sequentially
  with a one-second cooldown between lanes.
- Correctness: all 200 measured proofs and all warmups verified; CPU and Metal
  emitted identical canonical proof bytes for every row; the pinned real-AIR
  Rust Stwo oracle accepted every row in both revisions.
- Delta policy: an improvement or regression must exceed the sum of baseline
  and current MAD. A row is diagnostic-only if either run failed the ordered
  drift gate.

## Current results

`Total` is the complete request time: input construction, proving, canonical
proof encoding, and verification. MHz uses each workload's declared native
unit and is comparable only between lanes and revisions for the same row.

| Workload | CPU prove | CPU total | CPU MHz | Metal prove | Metal total | Metal MHz | Metal speedup | Evidence |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| Wide Fibonacci log14 x 32 | 15.188 ms | 16.171 ms | 1.079 | 18.099 ms | 19.040 ms | 0.905 | 0.84x | headline |
| Wide Fibonacci log16 x 64 | 90.187 ms | 103.177 ms | 0.727 | 82.520 ms | 95.792 ms | 0.794 | 1.09x | diagnostic |
| XOR log14 | 10.451 ms | 10.709 ms | 1.568 | 14.691 ms | 14.972 ms | 1.115 | 0.71x | headline |
| XOR log16 | 28.325 ms | 28.828 ms | 2.314 | 37.349 ms | 37.854 ms | 1.755 | 0.76x | headline |
| Plonk log14 | 11.037 ms | 11.347 ms | 1.485 | 14.865 ms | 15.171 ms | 1.102 | 0.74x | headline |
| Plonk log16 | 31.165 ms | 31.772 ms | 2.103 | 36.879 ms | 37.429 ms | 1.777 | 0.85x | headline |
| State machine log14 | 10.292 ms | 10.529 ms | 1.592 | 14.357 ms | 14.597 ms | 1.141 | 0.72x | headline |
| State machine log16 | 28.808 ms | 29.409 ms | 2.275 | 37.083 ms | 37.697 ms | 1.767 | 0.78x | headline |
| Blake log10 x 10 rounds | 24.374 ms | 28.024 ms | 0.420 | 21.109 ms | 24.725 ms | 0.485 | 1.15x | diagnostic |
| Blake log12 x 16 rounds | 72.019 ms | 100.647 ms | 0.910 | 71.815 ms | 99.937 ms | 0.913 | 1.00x | diagnostic |

## Delta result

Seven of ten rows are eligible for a performance claim in both runs. Across
those seven rows, every Metal prove-time delta is inconclusive inside the
combined MAD. The production AOT changes therefore have no measured effect on
this raw-Stwo hot loop, which is expected: they remove Cairo session setup and
runtime shader compilation rather than changing these proof kernels.

The current CPU lane is 9.15% slower on Plonk log16 and 2.82% slower on the
state-machine log16 row, both outside the combined MAD. These are candidate
regressions, not yet code-attributed regressions; confirm them in an independent
run before changing shared code. The three diagnostic rows retain their numeric
deltas but cannot support improvement or regression claims.

The older `370f8ef` report is preserved, but the delta tool rejects it as
incomparable. It used the historical synthetic Wide Fibonacci AIR and the
`cbe4d3f1...` oracle. The real recurrence AIR and `4d223c37...` oracle intentionally
produce a different proof identity.

## Evidence

- Current delta: `vectors/reports/native_proof_broad_delta_2026-07-17.json`
- AIR-transition rejection: `vectors/reports/native_proof_air_transition_delta_2026-07-17.json`
- Immutable history index: `vectors/reports/benchmark_history/index.json`
- Baseline report SHA-256: `fafc8ece59527351aa6a09045044ede36c338e840053abfe9646737a99d0971a`
- Current report SHA-256: `dc9d9db85c436b6eb1712831d46504d250788685fb2424ebcb2d507246d21971`
- Delta SHA-256: `49f5cdc7c7c447aa9b7fb932e628f909e4159ed9973bcc54b2386defb4290171`
