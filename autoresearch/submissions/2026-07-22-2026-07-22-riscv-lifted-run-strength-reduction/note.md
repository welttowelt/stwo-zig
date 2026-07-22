# Strength-reduce repeated lifted quotient runs

## Model and harness

Model: GPT-5 Codex. The repository-resident `stwo-perf` harness ran on the
designated Apple M5 Max in ReleaseFast mode. The claimed S3 `riscv/deep`
comparison used immutable candidate `3084fe1985db` and current-main predecessor
`9095ecec918f`, round-level A-B-B-A ordering, verified proof artifacts, complete
mechanism telemetry, and the pinned Stark-V correctness oracle.

The first local run completed objective sampling but exposed a harness bug when
automatic guards were expanded: thirteen Native AIR guards were parsed as
RISC-V workloads and rejected for lacking the RISC-V-only `{admission}` token.
That attempt and all of its raw reports were archived. The clean objective run
was repeated with local guard expansion disabled; repository product gates were
run separately, and the submission still requires the remote judged guard
matrix before promotion.

## Hypothesis

A fresh seven-row deep baseline put 17.22 of 19.35 aggregate request seconds in
proving. A verified three-second macOS sample of SHA2-2048 attributed 3,261
active samples to `quotient_tile_executor.execute`, versus 738 in packed Merkle
leaf updates and 717 in `memmove`. The quotient executor was the dominant shared
prover frame.

For every non-direct lifted column, the source index is
`((position >> shift) << 1) + (position & 1)`. A structural `2^shift`-row run
therefore repeats one even/odd source pair, yet the scalar loop recomputed four
M31 coefficient products on every row. The hypothesis was that loop-invariant
product hoisting plus packed alternating broadcasts would remove most of that
arithmetic without changing contribution order, scratch bounds, proof bytes,
or protocol behavior. The falsifiers were any scalar differential mismatch,
proof-byte drift, oracle rejection, resource regression, or a portfolio result
below 3%.

## Changes

The quotient tile executor now routes every structurally non-direct input view
through a run-wise accumulator. For each source run and each of four extension
coordinates, it computes the even and odd M31 products once, builds two packed
alternating vectors, and adds them directly into the existing output-stationary
numerator planes. Misaligned boundaries and final lanes retain a scalar tail.

This reduces multiplication work per contribution from four products per output
row to eight products per source run—an approximately `2^(shift-1)` reduction—
while leaving additions and their order unchanged. It creates no combined
matrix, no second pass, no workload-name or size special case, and no new Metal
dispatch, synchronization, residency, or ABI state. Direct views retain their
existing packed path. A differential test covers shifts 2, 3, and 7 and aligned
and misaligned tile starts.

Alternatives rejected during design were a packed gather/multiply loop, which
kept the same field-operation count; full combined-column materialization,
which violated the bounded-memory design and added large traffic; and
cross-column coefficient aggregation, which introduced grouping/audit
complexity. The selected design is the narrowest general strength reduction.

## Results

The clean claimed verdict is a statistically significant improvement with
portfolio proving-time ratio **0.724575**, 95% CI **[0.723189, 0.726258]**.
That is 27.5% lower proving latency / 1.38x throughput. The verified-request
ratio geometric mean is **0.753773**, or 24.6% lower request latency.

| workload | prove ratio | 95% CI | main prove | candidate prove | request ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| xorshift PRNG | 0.7268 | [0.7241, 0.7314] | 2006.1 ms | 1456.3 ms | 0.7383 |
| iterative Fibonacci | 0.7690 | [0.7655, 0.7742] | 2119.9 ms | 1622.7 ms | 0.7790 |
| Euclidean GCD | 0.7397 | [0.7366, 0.7448] | 2097.8 ms | 1552.9 ms | 0.7542 |
| multi-shard ADDI | 0.7607 | [0.7542, 0.7670] | 2105.7 ms | 1602.5 ms | 0.7727 |
| SHA2-512 | 0.6693 | [0.6686, 0.6695] | 2759.2 ms | 1847.2 ms | 0.7262 |
| SHA2-1024 | 0.6996 | [0.6959, 0.7041] | 3103.9 ms | 2160.1 ms | 0.7458 |
| SHA2-2048 | 0.7120 | [0.7116, 0.7131] | 3394.4 ms | 2415.6 ms | 0.7616 |

Every individual row wins; no average conceals a regression. Energy has a
0.53736 portfolio ratio (upper CI 0.54104), peak RSS is 0.99978x (upper CI
1.00103), and proof size is exactly 1.0x for every workload. Candidate peak RSS
ranges from 1,265 to 1,499 MiB.

## Correctness and validation

Every timed sample verified. Cross-arm proof digests are byte-identical in
every round, all seven mechanism-telemetry records are present and stable, and
the pinned Stark-V correctness oracle accepted 7/7 workloads. Format, source
conformance, the aggregate ReleaseFast test root, the focused scalar lifting
differential, RISC-V CPU product closure, Native CPU product closure, and the
device-only Native Metal lifecycle all pass. Metal independently verifies its
proof and reports no CPU fallback.

## Caveats

This is a claimed local result; only the judge's rerun counts. Local automatic
guard expansion is absent from the verdict because of the recorded cross-board
parser defect, so promotion must remain conditional on the remote judged guard
matrix. The source change is shared and product correctness is green, but no
unmeasured Native performance claim is made here.

This result materially improves the RISC-V prover and reinforces the resident
Metal pipeline architecture, but it does not complete the exact PR6 workload,
cold-process, log22, and judged-evidence contract.

**PR6 Supremacy: not achieved.**
