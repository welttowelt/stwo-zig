# Group lifted quotient contributions in worker-local registers

## Model and harness

Model: GPT-5 Codex. The repository-resident `stwo-perf` harness ran on the
designated Apple M5 Max in ReleaseFast mode. The clean claimed S3
`riscv/deep` comparison used immutable candidate `19ca3b8863ee` and current-main
predecessor `e20d72ac90af`, round-level A-B-B-A ordering, verified artifacts,
complete resource/mechanism telemetry, and the pinned Stark-V oracle. Every raw
A/B report records `implementation_dirty=false`.

The CLI's known automatic-guard classifier still parses Native guard IDs as
RISC-V and rejects their missing RISC-V-only admission token. The final local
verdict therefore sampled the objective with `--guards none`; aggregate,
RISC-V CPU, Native CPU, source-conformance, and device-only Native Metal product
checks were run separately. Promotion remains conditional on the remote judged
guard matrix.

## Hypothesis

After the promoted run-wise strength reduction, a fresh verified SHA2-2048
sample still put the quotient tile executor first with 1,705 top-of-stack
samples, ahead of packed Merkle leaves (749), `memmove` (708), and four-way
Blake compression (573). The live quotient plan had 2,162 contributions but
only 35 unique `(sample batch, source geometry)` groups.

Lifting is a linear index transform over exact M31 arithmetic. Contributions
sharing a batch and geometry can therefore be reduced before their repeated
output-row addition. The prediction was that one even/odd group reduction per
source run would replace per-contribution output additions while preserving the
AIR, transcript, proof bytes, contribution values, bounded ownership, and
parallel work distribution.

## Changes

Planning now creates a checked, immutable descriptor plan for every structurally
non-direct lifted contribution. Each group owns a slice of members; a member is
only a borrowed compact source column and its four M31 coefficients. The plan
is capped at 1 MiB, uses checked arithmetic, and is optional: allocation or
budget failure leaves every contribution on the unchanged direct/run-wise path.
No workload name, statement digest, input digest, benchmark size, or RISC-V-
specific key participates in admission.

Within each bounded quotient worker, all members in one group reduce into two
four-coordinate register accumulators for the current even/odd source pair.
The executor builds packed alternating values and adds the group once across
the lifted run. Multiplications remain parallel; output additions scale with
groups rather than contributions. Direct columns retain their packed path.
Scalar fallback, serial and parallel tile execution, retained-byte telemetry,
partial initialization cleanup, and direct fallback are all wired explicitly.

The compact reducer and direct planner were split into focused modules so the
tile scheduler remains below the repository's 850-line ceiling. Differential
tests cover shifts 2, 3, and 8 plus misaligned boundaries. A planning test
covers repeated geometry, multiple batches, direct exclusion, checked retained
bytes, and budget fallback.

## Rejected architecture

The first implementation materialized coefficient-weighted compact arrays for
27 high-shift groups. It used only 10.7 MiB and cut process instructions to
0.749x, but a process sample found 116 main-thread samples in serial plan
construction. It had moved products out of parallel workers and onto the
critical path; verified proving time did not improve. Full 35-group
materialization was also rejected at 153.3 MiB. Both dead ends and their
measurements are retained in the transcript.

## Results

The clean claimed proving-time portfolio ratio is **0.958426**, bootstrap 95%
CI **[0.954944, 0.962133]**. That is a 4.16% proving-latency reduction, above
the class's 1.2888% significance floor. Verified-request ratio geomean is
**0.964371**.

| workload | prove ratio | 95% CI | rounds | main | candidate | request ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| xorshift PRNG | 0.961191 | [0.954873, 0.966907] | 5 | 1468.060 ms | 1408.839 ms | 0.962210 |
| iterative Fibonacci | 0.960254 | [0.958887, 0.964196] | 3 | 1636.723 ms | 1569.976 ms | 0.962307 |
| Euclidean GCD | 0.959542 | [0.953218, 0.962870] | 5 | 1560.442 ms | 1494.326 ms | 0.961622 |
| multi-shard ADDI | 0.968090 | [0.959831, 0.976283] | 5 | 1620.772 ms | 1570.431 ms | 0.974301 |
| SHA2-512 | 0.945873 | [0.933950, 0.966858] | 5 | 1843.937 ms | 1756.293 ms | 0.962728 |
| SHA2-1024 | 0.954801 | [0.939027, 0.963837] | 5 | 2149.973 ms | 2051.770 ms | 0.964895 |
| SHA2-2048 | 0.959373 | [0.952284, 0.964520] | 5 | 2379.370 ms | 2292.504 ms | 0.962600 |

Every workload wins; no portfolio average hides a regression. Energy ratio is
0.834744 (upper CI 0.839936), peak RSS is 0.999729 (upper CI 1.000914), and
proof-size ratio is exactly 1.0. Candidate/epoch-anchor ratio is 0.6626.

## Correctness and validation

Every timed proof verified, cross-arm canonical proof digests are byte-identical
per round, mechanism telemetry is stable for 7/7 workloads, and the pinned
Stark-V oracle accepted 7/7. Statement and transcript digests match the current
main arm. The ReleaseFast aggregate test root, focused compact reducer/planner
tests, source conformance, RISC-V CPU product closure, Native CPU product
markers, Native Metal closure, and device-only Metal prove plus independent
verification all pass. The change introduces no Metal dispatch, CPU fallback,
resident object, synchronization point, shader, or ABI change.

## Caveats

This is a claimed same-host result; only the judge's rerun counts. Local
automatic guard expansion is absent because of the documented cross-board
classifier defect, so promotion remains conditional on remote aggregate CPU,
Metal, and RISC-V guards. This submission improves the shared CPU prover and
RISC-V portfolio, but it does not complete the exact PR6 workload, log22,
cold-process, and authenticated judged-evidence contract.

**PR6 Supremacy: not achieved.**
