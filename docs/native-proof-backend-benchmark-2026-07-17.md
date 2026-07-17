# Native CPU/Metal Backend Benchmark, 2026-07-17

Status: six-example real-AIR correctness baseline accepted; nine timing rows headline-valid.

This run measures the shared Zig proof transaction over Wide Fibonacci, XOR,
Plonk, state-machine, Blake, and Poseidon workloads. It is the broad Native Stwo
backend suite, not a Cairo or SN PIE claim.

## Contract

- Revision: `756afa46` (`Harden Native matrix evidence`).
- Build: Zig 0.15.2 `ReleaseFast`, parallel proving enabled, Apple M5 Max.
- Protocol: functional Blake2s, PoW 10, blowup 1, three queries, fold step 1.
- Sampling: ten verified warmups and ten measured proofs per lane and row.
- Scheduling: CPU/Metal lane order alternates by row; rows run sequentially with
  a one-second cooldown between lanes.
- Correctness: all 240 measured proofs verified and were byte-identical within
  each lane; CPU and Metal emitted identical canonical proof bytes for every row;
  the pinned real-AIR Rust Stwo oracle accepted every row.
- Resources: process peak RSS is captured with `/usr/bin/time -l` and normalized
  to KiB. Proof stability and oracle acceptance are derived from checked receipts,
  not controller assertions.
- Timing: a row is diagnostic-only when its ordered samples exceed the drift gate.
  Timing eligibility does not weaken exact proof acceptance.

## Current results

`Total` is the complete request time: input construction, proving, canonical
proof encoding, and verification. MHz uses each workload's declared native unit
and is comparable only between lanes for the same row. RSS is process peak RSS.

| Workload | CPU prove | CPU total | CPU MHz | CPU RSS | Metal prove | Metal total | Metal MHz | Metal RSS | Metal speedup | Evidence |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| Wide Fibonacci log14 x 32 | 16.606 ms | 17.683 ms | 0.987 | 24.6 MiB | 19.579 ms | 20.635 ms | 0.837 | 47.1 MiB | 0.85x | headline |
| Wide Fibonacci log16 x 64 | 89.445 ms | 103.295 ms | 0.733 | 82.7 MiB | 77.665 ms | 91.600 ms | 0.844 | 137.8 MiB | 1.15x | diagnostic |
| XOR log14 | 11.274 ms | 11.585 ms | 1.453 | 22.3 MiB | 15.399 ms | 15.696 ms | 1.064 | 42.3 MiB | 0.73x | headline |
| XOR log16 | 31.203 ms | 31.781 ms | 2.100 | 62.8 MiB | 38.808 ms | 39.355 ms | 1.689 | 72.4 MiB | 0.80x | headline |
| Plonk log14 | 12.017 ms | 12.379 ms | 1.363 | 23.5 MiB | 15.572 ms | 15.926 ms | 1.052 | 42.7 MiB | 0.77x | headline |
| Plonk log16 | 30.656 ms | 31.256 ms | 2.138 | 62.2 MiB | 39.102 ms | 39.693 ms | 1.676 | 75.7 MiB | 0.78x | headline |
| State machine log14 | 11.196 ms | 11.469 ms | 1.463 | 22.7 MiB | 15.467 ms | 15.732 ms | 1.059 | 41.8 MiB | 0.72x | headline |
| State machine log16 | 30.718 ms | 31.415 ms | 2.133 | 62.8 MiB | 38.163 ms | 38.830 ms | 1.717 | 71.9 MiB | 0.80x | headline |
| Blake log10 x 10 rounds | 25.509 ms | 29.492 ms | 0.401 | 38.2 MiB | 22.127 ms | 26.093 ms | 0.463 | 63.5 MiB | 1.15x | headline |
| Blake log12 x 16 rounds | 71.605 ms | 100.250 ms | 0.915 | 236.8 MiB | 72.696 ms | 101.105 ms | 0.902 | 195.2 MiB | 0.98x | headline |
| Poseidon log10 instances | 4.871 ms | 6.229 ms | 0.210 | 26.4 MiB | 8.172 ms | 9.556 ms | 0.125 | 41.3 MiB | 0.60x | diagnostic |
| Poseidon log13 instances | 33.200 ms | 40.946 ms | 0.247 | 54.0 MiB | 28.273 ms | 35.672 ms | 0.290 | 69.6 MiB | 1.17x | diagnostic |

## Interpretation

All 12 rows satisfy the proof-stability contract: each CPU and Metal lane
produced ten verified, byte-identical measured proofs, both lanes agreed exactly,
and Rust accepted the artifact. Nine rows also satisfy the ordered timing gate.
Wide Fibonacci log16 and both Poseidon rows remain diagnostic because one or both
ordered prove-time series drifted by more than five percent.

Metal is faster on the two widest large rows, Wide Fibonacci log16 and Poseidon
log13, and on bounded Blake log10. Most narrow rows remain CPU-favored. The Metal
lane still reports explicit CPU fallbacks and is therefore correctly named
`metal_hybrid`; this Native matrix establishes backend semantic conformance, not
the no-fallback production Cairo contract.

The schema-v3 to schema-v4 transition is intentionally incomparable. Schema v4
raises the minimum from five to ten measured verified proofs per lane, adds peak
RSS, validates the exact Rust binary and artifact receipts, and adds Poseidon.
A performance delta across those contracts would be misleading, so the delta
artifact preserves both inputs and records the incompatibility instead.

## Evidence

- Transition delta: `vectors/reports/native_proof_v4_transition_delta_2026-07-17.json`
- Immutable history index: `vectors/reports/benchmark_history/index.json`
- Current report SHA-256: `4f7a234ffe2d6fde65a01173d12becbb7b9aa8ab4cfcab3c322ba13a78ff353d`
- Current report: `vectors/reports/benchmark_history/reports/native_proof_cross_backend_matrix_v4/4f7a234ffe2d6fde65a01173d12becbb7b9aa8ab4cfcab3c322ba13a78ff353d.json`
- Transition delta SHA-256: `f0ea216717483515d3af831d40d60e16e060bc51e5a636d3313c334e02efd6c8`
- Native Rust oracle revision: `a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`
- Rust oracle binary SHA-256: `4d223c37e85b96f61dccc684f2897c82d2d55f6c50b59616a69cc5cc70d2ccf8`
