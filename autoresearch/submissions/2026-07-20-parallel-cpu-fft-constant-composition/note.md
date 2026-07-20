# Parallelize large CPU FFT batches and fold constant composition columns

## Model and harness

Model: Claude Fable 5. Harness: repo-resident `stwo-perf` at current main
`5d2eb59b2f9d`, candidate `c7a214981b03`, Zig 0.15.2 and Python 3.12.12,
ReleaseFast on an Apple M4 arm64 macOS host. Every S3 run used the unchanged
current-main checkout as its paired predecessor. The final claimed verdict
uses the harness's default worker selection; a four-worker isolation replicate
is also recorded. A reasoning-first, sanitized session transcript is attached
as `transcripts/session-01.md`.

## Hypothesis

Large CPU circle transforms choose batches only from a 256 KiB cache target.
For Plonk's four same-size coordinate columns, that produces one work item and
runs interpolation or extended-domain evaluation sequentially despite the
resident worker pool. Capping the cache batch by the fair columns-per-worker
share should expose independent FFT tasks without changing field arithmetic.

Plonk also emits a constant secure composition column. Materializing that
column into a domain-sized accumulator makes the prover scan, interpolate, and
combine values that can instead remain one random-weighted scalar. Detecting a
truly constant column before bucket allocation should remove those passes while
preserving coefficient order and every resulting field value.

## Changes

For CPU transforms with at least two columns and 4,096 values per column,
batch length is now the smaller of the existing cache cap and
`ceil(column_count / worker_count)`. Small transforms retain the existing
batching, and backend-owned interpolation or evaluation hooks remain untouched.
A pure scheduling helper and unit test cover worker-count boundaries.

`DomainEvaluationAccumulator.accumulateColumn` now checks all four coordinate
planes for a constant value. A constant is multiplied by the same consumed
random coefficient and added to the existing constant bucket; any differing
cell immediately selects the original domain-column path. A focused test proves
that constant columns allocate no domain bucket, varying columns still do, and
the finalized values match the direct formula.

No transcript, protocol, hash, field operation, or proof format changed.

## Results

Final paired S3 `plonk_log14` deep/time after refreshing and rebasing onto the
latest predecessor: ratio **0.9097**, 95% CI **[0.8759, 0.9340]**, 15 rounds,
with predecessor and candidate medians of 9.269 and 8.738 ms. Every timed
proof verified and stayed byte-identical. A four-worker replicate reported
**0.8943 [0.8668, 0.9225]**, 10.051 to 9.078 ms.

ABBA profiled diagnostics tied the gain to both mechanisms. Preprocessed and
main-trace interpolation fell from 0.230-0.245 ms to 0.077-0.134 ms;
extended-domain evaluation fell from 0.279-0.315 ms to 0.168-0.231 ms; and
composition evaluation fell from 0.501-0.523 ms to 0.162 ms. The proof SHA-256
remained `d63a2c92...69dbaf`.

Regression S3 rows were not significant: wide ratio
**1.0298 [0.9915, 1.0895]** and small ratio
**1.0097 [0.9664, 1.0381]**. Both medians remain inside the 5% matrix-row
budget. The ReleaseFast core, prover, native CPU product, and downstream
package closures passed; the prover and native CPU closures covered 152 and
190 transitive Zig sources.

## Caveats

This is a local claimed verdict; the project judge's clean rerun is
authoritative. The benchmark host had sustained unrelated load, but both the
default-worker verdict and the four-worker isolation replicate cleared the
significance rule. The anchor is not frozen, so drift budgets and judged
promotion remain inactive. Constant detection adds a read pass, but varying
columns exit at their first differing coordinate. Mechanism telemetry is still
pending in the harness; stage profiles, differential tests, paired proof
identity, and repeated S3 results provide the current evidence.
