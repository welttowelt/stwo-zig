# Autoresearch session 01 — largest RISC-V portfolio

## Objective and session contract

This iteration begins immediately after the AdvSIMD M31/FFT-tail submission
merged as PR #80. The standing objective is a repeated improvement -> claimed
verdict -> PR -> green CI -> merge loop, prioritizing the largest and longest
coordinates and especially the live RISC-V board. A result must preserve the
Native CPU, Metal, and RISC-V correctness and resource portfolios; a narrow
kernel result is not a submission.

The canonical checkout was updated from `354da109` to `9095ecec`, including
the recorded PR #80 promotion. Two pre-existing untracked Metal research notes
were moved aside during the fast-forward and restored unchanged afterward.

All five repository skills were loaded before measurement. Zig profiling is
the primary evidence route for this CPU/shared-prover iteration. Algorithm
matching gates any material replacement; Metal profiling and performance
design constrain shared changes so they preserve the compute-only Metal path;
the transcript is being captured contemporaneously. The Metal common-patterns
reference was read completely. Its render-only branch does not apply because
the prover contains no render pass.

## Prior evidence reviewed

The two most relevant promoted sessions are the cache-skewed shared-column
arena and the later hardware-page rotation. They established that large Native
composition was dominated by simultaneous column-major streams, but their
attempt to raise the combined-column ceiling did not admit the 617-column
RISC-V tree and was neutral on the existing 188-column tree. That experiment
was reverted. A whole-process SHA2-2048 sample instead identified
`quotient_tile_executor.execute` as the largest active top-of-stack frame,
followed by Merkle leaves, circle extension, constraint evaluation, and witness
ingestion. This iteration starts there rather than repeating the rejected
column-ceiling hypothesis.

No candidate source has been edited yet.

## Fresh current-main baseline

Current main `9095ecec` was built as the ReleaseFast `stwo-zig` product and all
seven deep RISC-V rows were run locally with one verified warmup and one timed
sample. The checkout reported dirty only because of the two preserved untracked
research notes; the executable and source commit are fixed. Every release-gated
artifact verified and was deterministic relative to its statement.

| workload | request | proving | witness | verification |
| --- | ---: | ---: | ---: | ---: |
| xorshift PRNG | 2.119 s | 2.018 s | 0.012 s | 0.079 s |
| iterative Fibonacci | 2.216 s | 2.113 s | 0.015 s | 0.081 s |
| Euclidean GCD | 2.242 s | 2.122 s | 0.030 s | 0.081 s |
| multi-shard ADDI | 2.173 s | 2.067 s | 0.012 s | 0.084 s |
| SHA2-512 | 3.236 s | 2.721 s | 0.417 s | 0.089 s |
| SHA2-1024 | 3.523 s | 3.015 s | 0.403 s | 0.089 s |
| SHA2-2048 | 3.844 s | 3.165 s | 0.572 s | 0.087 s |

The portfolio sums to about 19.35 seconds request and 17.22 seconds proving.
Even the simple programs spend roughly 2.0--2.1 seconds proving, confirming a
large shared-prover floor. SHA2 witness generation matters locally but cannot
explain the whole portfolio.

## Stage and stack attribution

The legacy compatibility profiler, run at the matching functional parameters,
reported approximate SHA2-2048 proving stages: FRI quotient build/commit 1.129
s, interaction commit 0.772 s, composition evaluation 0.709 s, main commit
0.152 s, preprocessed commit 0.084 s, and sampled values 0.034 s. Its standalone
verification ended in `LogupSumNonZero`, so these numbers are diagnostic only,
not correctness evidence.

A three-second macOS sampler was then attached to the release-gated product,
which completed and verified normally. Collapsing all threads by top frame gave:

| active frame | samples |
| --- | ---: |
| quotient tile executor | 3,261 |
| packed Merkle leaf updates | 738 |
| `memmove` | 717 |
| RISC-V LogUp pair constraints | 443 |
| SIMD Blake compression | 329 |
| fused circle-transform tails | 266 |
| parallel-four Blake compression | 234 |
| Poseidon2 full-round constraint evaluation | 211 |

Idle worker waits were excluded from useful work. The quotient executor is
therefore the first target, with Merkle/memory movement as the next independent
axis. The current direct bounded path already performs a tile-wide denominator
batch inversion and four-row finalization, so the next question is whether its
column-contribution traversal is doing redundant passes or using a poor layout.

## Run-wise lifted-column strength reduction

The non-direct quotient input view maps each output position with
`((position >> shift) << 1) + (position & 1)`. Therefore every structural
`2^shift`-row run repeats one even/odd source pair. The former scalar loop
nevertheless repeated four M31 coefficient products at every output row.

The candidate preserves the existing output-stationary numerator planes and
the exact contribution order, but computes each run's even and odd products
once for all four extension coordinates. It broadcasts those alternating
values through packed additions and retains a scalar boundary/tail. This is
ordinary loop-invariant code motion plus strength reduction: it applies to all
non-direct lifted views, is selected only from structural properties, adds no
materialized matrix or pass, and changes no Metal ABI, synchronization, proof,
or protocol behavior. A focused test covers shifts 2, 3, and 7 with aligned and
misaligned tile boundaries and compares every output coordinate to the scalar
lifting formula. The ReleaseFast prover closure passes.

The first release-gated SHA2-2048 screen used one verified warmup and one timed
sample. Request time fell from the fresh-main 3.843537 s anchor to 2.912426 s,
a 0.7578 ratio (24.2% lower latency / 1.32x throughput). Proving fell from
3.165494 s to 2.243519 s, a 0.7087 ratio (29.1% lower / 1.41x throughput).
The statement SHA-256 remained
`6bc61b060cd26d38c7d620dc6b3f17829221d310b498e7c7c8e63a01f3e97e88`,
the transcript state remained
`4ca8cf9f10ca8322420b8cec1bdcd426958ca06ad6371878c3ddbcbc2da5fac8`,
and the verified artifact remained
`e4ca968ae654b848c59c7911db5ce07e9a5aa96eb6af452b970f8ab1e3ce4b76`.
Peak physical footprint was 1,569,556,952 bytes. This is a diagnostic dirty-tree
screen, not the final verdict; the next step is the whole deep portfolio and a
clean predecessor/candidate measurement.

The complete seven-row diagnostic screen then verified every release-gated
artifact with one warmup and one sample per row:

| workload | main request | candidate request | ratio | candidate proving |
| --- | ---: | ---: | ---: | ---: |
| xorshift PRNG | 2.119153 s | 1.529049 s | 0.7215 | 1.433835 s |
| iterative Fibonacci | 2.216116 s | 1.668222 s | 0.7528 | 1.568753 s |
| Euclidean GCD | 2.241568 s | 1.603262 s | 0.7152 | 1.491254 s |
| multi-shard ADDI | 2.172536 s | 1.643628 s | 0.7566 | 1.544502 s |
| SHA2-512 | 3.236005 s | 2.285702 s | 0.7063 | 1.748794 s |
| SHA2-1024 | 3.522512 s | 2.536996 s | 0.7202 | 2.062210 s |
| SHA2-2048 | 3.843537 s | 2.947624 s | 0.7669 | 2.301461 s |

The request-time geometric-mean ratio is approximately 0.733. Every row wins,
so no portfolio average hides a loss. SHA2-2048 repeated within ordinary
single-sample host variance (2.912--2.948 s request) while retaining its exact
artifact digest. These remain screens; the source is frozen only after format,
conformance, and test roots pass, and the submission claim will use the clean
counterbalanced runner verdict.

## First official-run harness failure

The first clean `s3/riscv/deep` invocation reached regression-guard expansion
but exited before producing a verdict. The CLI selected thirteen ordinary
Native AIR guards, beginning with `guard_blake_10x10`, then incorrectly applied
the RISC-V workload parser to them and rejected the first row because its
command did not contain the RISC-V-only `{admission}` placeholder. Exact error:
`guard_blake_10x10: RISC-V workload command lacks the required {admission}
token`. This is a board/guard classification defect in the local runner, not a
candidate proof, test, or benchmark failure. No output will be represented as a
verdict. The objective lane is rerun with local guard expansion disabled;
submission-side judged guards remain mandatory, and relevant Native/Metal and
RISC-V correctness products are run separately before promotion.

The generated `.runs/latest` directory from that failure contained the full
objective A/B reports and proof artifacts. It was moved intact into the session
evidence directory as `failed-auto-guard-run`; nothing was deleted. A later
`stwo-perf sync` unexpectedly detached the candidate worktree at current main.
The committed source was not lost: branch `autoresearch/riscv-quotient-layout`
still pointed to `3084fe1`. The worktree was switched back to that branch,
verified clean, and product setup rebound all identities before rerunning.

## Clean official result

The repeated S3 objective run used clean candidate `3084fe1985db` and clean
predecessor `9095ecec918f`. Every timed sample verified, cross-arm proof digests
were byte-identical in every round, mechanism telemetry was present and stable
for 7/7 rows, and the pinned Stark-V oracle accepted 7/7 artifacts.

| workload | prove ratio | 95% CI | rounds | predecessor | candidate | request ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| xorshift PRNG | 0.726846 | [0.724060, 0.731443] | 3 | 2006.122 ms | 1456.325 ms | 0.738316 |
| iterative Fibonacci | 0.768963 | [0.765468, 0.774236] | 3 | 2119.912 ms | 1622.725 ms | 0.778959 |
| Euclidean GCD | 0.739743 | [0.736568, 0.744811] | 3 | 2097.813 ms | 1552.882 ms | 0.754235 |
| multi-shard ADDI | 0.760715 | [0.754239, 0.766993] | 5 | 2105.685 ms | 1602.519 ms | 0.772699 |
| SHA2-512 | 0.669270 | [0.668619, 0.669534] | 3 | 2759.161 ms | 1847.157 ms | 0.726183 |
| SHA2-1024 | 0.699600 | [0.695874, 0.704104] | 3 | 3103.856 ms | 2160.110 ms | 0.745798 |
| SHA2-2048 | 0.712002 | [0.711626, 0.713093] | 3 | 3394.397 ms | 2415.601 ms | 0.761626 |

The proving-time portfolio ratio is 0.724575 with bootstrap 95% CI
[0.723189, 0.726258], and the verified-request ratio geometric mean is
0.753773. Energy falls to 0.537364x with upper CI 0.541043. Peak RSS is
0.999782x with upper CI 1.001021. Proof bytes are exactly unchanged for every
row. Candidate geometric-mean proving time is 1780.298 ms and total accepted
measurement time is 223.818 seconds over 23 workload rounds.

## Final validation and submission boundary

`zig build fmt source-conformance test -Doptimize=ReleaseFast` passes, including
the 365-source aggregate closure and focused lifted-run differential. The clean
candidate then passes `test-riscv-cpu-product`, `test-native-cpu-product`, and
`test-native-metal`: RISC-V closes over 340 sources; Native CPU over 198; Native
Metal over 240 and completes a device-only proof plus independent verification
with no fallback. All products embed clean commit `3084fe1` and tree
`2ae9ce544e9c0dd990d0254b33b9503ea36cd4aa`.

The submission claims only the significant `riscv/deep` improvement. The local
verdict is advisory and lacks automatic guards solely because of the recorded
runner classification bug; remote judged guards remain a hard promotion gate.
The exact PR6 matrix, both timing boundaries, log22 evidence, and authenticated
judge verdict are incomplete.

**PR6 Supremacy: not achieved.**

The first packaging invocation was rejected before writing repository files
because the note used the headings `Profile and hypothesis` and `Architecture`
instead of the schema's literal required `Hypothesis` and `Changes` headings.
The underlying content was unchanged; the headings were corrected and the
validator was rerun.
