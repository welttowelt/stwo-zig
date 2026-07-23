# RISC-V system-level 2x autoresearch transcript

## Objective and invariants

The task is to reduce verified RISC-V proof latency by at least 2x across the
complete headline hash portfolio, not merely one selected input. The immutable
starting point is `2beae9d03b33bc9c5b0b21bb445439799786f2fb`; the development
branch starts from current main `799efe87a9eccd6ae9a2e19c815e82bfbf1d4198`.
The target host is the 18-logical-CPU Apple M5 Max with Zig 0.15.2 ReleaseFast.

CPU completion requires every SHA-256 128/256/512/1024/2048-byte point and the
Keccak-128 proof point to reach ratio at most 0.50 against the pinned baseline,
95% CI upper bound at most 0.55, both experiment halves winning, and at least
2x geometric-mean improvement in prove and complete-request time. The broader
RISC-V board must not regress, and proof identity, VM/AIR semantics, transcript,
security, oracle parity, proof size, resource telemetry, and timing boundaries
remain fixed. Keccak inputs at or above 256 bytes stay fail-closed until the
signed-mulh soundness limitation is independently resolved.

The subsequent Metal phase must be a real RISC-V backend, not the unrelated
native-example Metal path. It must retain the exact RISC-V AIR and canonical
CPU proof bytes, verify independently, report zero CPU fallbacks, use
identity-bound AOT shaders for cold evidence, and beat the optimized CPU at
512/1024/2048 bytes.

## Research method selected

The repository's algorithm-matching, Zig profiling, Metal profiling/design,
and submission-transcript skills are binding. The first action is therefore a
complete-request baseline and stage profile, followed by a written
problem-match/design brief. No prover source will be changed before the
fixed-cost hypothesis is measured. Complete-proof screens and paired ABBA
evidence, rather than isolated microbenchmarks, will decide which experiments
survive.

The canonical autoresearch CLI was fast-forwarded from `2beae9d03b33` to
`799efe87a9ec` before beginning. Three pre-existing untracked researcher notes
were temporarily stashed and restored with identical SHA-256 digests. A clean
branch `autoresearch/riscv-system2x-epoch1` was then created from current main.

## Initial hypotheses

The supplied latency curve grows far more slowly than guest steps, which makes
fixed proof-domain selection, component metadata/placement, trace commitment,
interaction setup, quotient/FRI, allocation, and synchronization credible
dominant costs. This is a hypothesis, not yet a conclusion. The first profiles
must distinguish:

1. genuinely fixed proof work caused by a common domain or component envelope;
2. repeated per-component setup/materialization that can be compiled or cached;
3. bandwidth-dominated FFT/Merkle/quotient passes that need fewer full-domain
   traversals or better batching;
4. guest execution and witness construction that scales with steps; and
5. verification/encoding work outside `prove_ms` that controls total request
   latency.

The strongest general architecture is likely a persistent immutable RISC-V
proof plan plus cross-component batched storage/scheduling, but that proposal
will be rejected if stage profiles do not show repeat setup, allocation, or
fragmented scheduling as a material fraction of the complete request.

## Prior-research audit

Current main already contains four cumulative RISC-V/shared-prover promotions,
so none may be counted again against the requested `2beae9d` baseline:

1. run-wise strength reduction over implicitly lifted quotient columns
   (`0.724575` proving ratio on the then-current deep portfolio);
2. worker-local register grouping by quotient source geometry (`0.958426`);
3. direct four-message BLAKE2 continuation from canonical column storage
   (`0.930236`); and
4. packed inversion, exact dot4/coordinate SIMD, normalized FFT tails,
   synthesized 2x LDE expansion, interleaved BLAKE2 dependency chains, and
   batch-major quotient denominators (`0.982416` final stacked ratio).

Their full transcripts were read. The following paths are established dead
ends and will not be repeated without new contradictory evidence:

- serial coefficient-weighted quotient materialization reduced instructions
  but lengthened the main-thread critical path;
- deferring every column to generic mixed-height Merkle commitment rebuilt
  whole leaf messages and regressed requests to about 1.22x;
- grouping existing incremental Merkle batches by height was neutral;
- worker-count/oversubscription sweeps did not improve the joined critical
  path;
- flattened direct quotient plans, generic QM31 SIMD, wider inversion stripes,
  and extra compact accumulators were neutral or spill-bound; and
- kernel fusion without demonstrated traffic/wait removal is not presumed to
  help.

The post-promotion profile frontier was four-message BLAKE2 compression,
`memmove`, locked RISC-V LogUp evaluation, quotient finalization, and forward
FFT tails. The editable-path policy excludes `src/frontends/riscv/**`, so any
CPU promotion must operate through shared field, crypto, PCS, polynomial,
lifted-VCS, AIR, or proof-session architecture and must preserve Native CPU and
Metal products.

## Pinned baseline build and headline reproduction

Detached baseline worktree `2beae9d03b33` and current-main worktree
`799efe87a9ec` were built separately as ReleaseFast `stwo-zig` products. The
baseline binary is clean and has SHA-256
`2f6fb505684aecf7a22f90c31edbd850539a39ba4487a094a2f03635ab0c860a`.
The host reports Apple M5 Max, 18 logical CPUs, 64 GiB memory, and no thermal or
performance warning.

The six headline baseline rows each ran ten verified warmups and five verified
samples. Times below are mean proving and median complete request:

| workload | steps | prove ms | request ms | witness ms | verify ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| SHA2-128 | 14,034 | 1,392.18 | 1,953.61 | 468.47 | 93.09 |
| SHA2-256 | 22,810 | 1,478.48 | 2,048.88 | 475.30 | 92.68 |
| SHA2-512 | 40,362 | 1,630.37 | 2,253.24 | 523.16 | 99.28 |
| SHA2-1024 | 75,466 | 2,006.55 | 2,613.00 | 484.41 | 98.90 |
| SHA2-2048 | 145,674 | 2,337.26 | 3,092.12 | 664.77 | 101.61 |
| Keccak-128 | 18,610 | 1,555.37 | 2,032.29 | 370.40 | 97.88 |

These are a locally reproduced grounding run, not a replacement for the frozen
authority values in the task. They confirm the supplied curve. SHA2-128 through
SHA2-1024 all commit 858 main and 408 interaction columns; SHA2-2048 rises only
to 895/444. The largest guest executes 10.38x as many steps as SHA2-128, but
locally proving grows only 1.68x. Thus the fixed-cost hypothesis is supported:
the shared proof geometry dominates, while guest execution itself is only
3.6--19.4 ms and cannot supply a 2x proof win.

## Complete baseline board

The other fourteen RISC-V rows were then measured with the same ten verified
warmups and five verified samples. Together with the six headline rows this is
the complete 20-program board. The compact programs expose the fixed floor most
clearly:

| workload | steps | prove ms | request ms |
| --- | ---: | ---: | ---: |
| ALU test | 8 | 947.88 | 1,030.33 |
| branch Fibonacci | 144 | 987.97 | 1,072.75 |
| declared region | 8 | 1,011.86 | 1,106.40 |
| JAL/JALR | 11 | 985.40 | 1,068.88 |
| memory load/store | 18 | 1,110.75 | 1,206.38 |
| shift/logic | 23 | 958.76 | 1,046.37 |
| memcpy loop | 2,126 | 943.08 | 1,035.72 |
| sieve primes | 2,792 | 966.35 | 1,050.12 |
| bubble sort | 9,462 | 1,038.15 | 1,115.50 |
| Collatz | 34,237 | 1,155.93 | 1,246.29 |
| xorshift PRNG | 65,544 | 1,319.56 | 1,415.14 |
| iterative Fibonacci | 102,408 | 1,500.67 | 1,603.69 |
| Euclidean GCD | 124,931 | 1,401.27 | 1,519.56 |
| multi-shard ADDI | 131,078 | 1,457.05 | 1,564.66 |

All proofs independently verified and all machine-readable reports and proof
artifacts are retained under `baseline-2be/full-board`. An eight-instruction
program still spends roughly one second proving; therefore a guest executor,
SHA instruction, or one selected input optimization cannot satisfy the
portfolio contract.

## Stage and process profiles

The repository's diagnostic stage recorder was run on SHA2-128 and SHA2-2048.
Its known final `LogupSumNonZero` makes these stage runs diagnostic only; the
successful production proofs above remain the correctness evidence.

| stage | SHA2-128 ms | SHA2-2048 ms |
| --- | ---: | ---: |
| guest execute | 4.9 | 19.6 |
| preprocessed commit | 88 | 88 |
| opcode/infrastructure trace generation | 221 | 282 |
| main commit | 49 | 56 |
| interaction generation and commit | 473 | 757 |
| composition evaluation | 718 | 744 |
| composition interpolate | 8 | 8 |
| composition commit | 25 | 26 |
| sampled values | 29 | 33 |
| FRI quotient build and commit | 94 | 99 |
| FRI decommit | 4 | 3 |

The committed-cell counts are 32,049,584 and 44,185,936 respectively.
Composition evaluation is an almost perfectly fixed 0.72--0.74 seconds.
Interaction generation/commit is the only dominant stage that scales
materially with the larger SHA input.

A separate three-second macOS process sample of the successful SHA2-2048
request is retained as `baseline-2be/profiled/sha2-2048.sample.txt`. During
composition the main thread spends 569 samples waiting for whole-component
workers to join. Active worker tops are led by `logup.pairConstraint` (460),
lookup denominator construction (267), Poseidon full-round evaluation (237),
hash-component constraint combination (142), and semantic evaluation. This
confirms a load-imbalanced component scheduler and scalar independent-row
secure-field arithmetic as the live frontier. Four-message BLAKE2 remains the
largest aggregate leaf/commit kernel, but the stage profile shows that Merkle
and FRI work is no longer the proof-wide floor.

## Problem match and first experiment

The measured problem is a heterogeneous bulk map/reduce over independent domain
rows followed by an exact random-linear-combination reduction. It is not a
graph search, sorting problem, or guest-instruction bottleneck. The closest
algorithmic matches are:

- SIMD structure-of-arrays field evaluation across independent rows;
- Montgomery batch inversion with several independent prefix chains;
- static weighted scheduling/tiling for heterogeneous data-parallel kernels;
- memoization of repeated pure inversions in padded domains; and
- persistent immutable setup for proof-invariant preprocessing.

The RISC-V frontend and AIR are outside the editable surface, so the first
candidate will operate only through shared field/prover primitives. A generic
three-batch SIMD implementation of dependent QM31 multiplication was already
rejected in the previous epoch; this experiment instead packs *independent
rows* inside batch inversion, the SIMD dimension that prior evidence explicitly
identified as sound. A one-entry thread-local inverse cache will be screened
separately because long padding runs repeat the exact same pure field inverse.
It carries no proof-session identity and cannot change results, but it survives
only if concurrency tests and complete-request counters show a win.

## Independent-row batch inversion

The first implementation transposes four adjacent AoS `QM31` values into four
AArch64 coordinate vectors, advances multiple independent Montgomery prefix
chains, performs the bounded tail inverse, and walks the chains backward. It
routes naturally at lengths divisible by 8, 16, or 32 and does not recognize a
workload, input, or benchmark size. Random nonzero vectors at lengths 8, 16,
32, 64, and 96 matched scalar inverses exactly, and the full 380-source
ReleaseFast test closure passed.

The complete-request screen was positive but modest. At SHA2-128 the recent
baseline/candidate medians were 1.8970/1.8539 seconds and mean proving times
were 1.3706/1.3400 seconds, about a 2.2% win. At SHA2-2048 request time was
effectively neutral (2.7639/2.7612 seconds) and proving improved about 0.6%
(2.0881/2.0766 seconds). This layer remains useful as a stateless,
general-purpose improvement, but it cannot explain the required system-level
gain by itself.

A one-entry thread-local inverse memo was then tested. Its apparent improvement
was at most approximately 0.6% proving and was not robust relative to run
noise. Although a 10,000-iteration two-thread isolation test passed, the memo
introduced implicit state without a material payoff. It was removed from the
promotion candidate.

## Sparse extension-field preservation

Inspection of the dominant evaluator call paths revealed that the generic AIR
API promotes committed `M31` columns into `QM31` values. The representation
still contains the structural fact that three of four coordinates are zero,
but generic `QM31.mul` immediately discarded it and paid the nine-base-product
Karatsuba path. The accepted implementation checks this algebraic property and
uses full-by-base multiplication when either operand is structurally base.
Sparse squares likewise remain in the base field. This is an exact field
identity, applies to every caller and shape, and preserves the generic path for
two full-extension operands.

Randomized schoolbook-reference tests cover both operand orders and sparse
squaring. The full ReleaseFast closure passed. A two-warmup/three-verified-
sample screen produced the first large result:

| workload | baseline request | candidate request | ratio | baseline prove | candidate prove | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SHA2-128 | 1.8970 s | 1.3235 s | 0.698 | 1.3706 s | 0.8073 s | 0.589 |
| SHA2-2048 | 2.7639 s | 2.0920 s | 0.757 | 2.0881 s | 1.4326 s | 0.686 |

For SHA2-128 the measured instruction interval fell from 407.2 to 298.0
billion and energy from 130.8 to 106.3 billion nJ. For SHA2-2048 instructions
fell from 576.9 to 413.0 billion and energy from 188.0 to 152.0 billion nJ.
Statement and transcript digests remained identical and all retained proofs
verified independently.

The diagnostic stage profile explains the gain. SHA2-128 composition
evaluation fell from 718 to 276 ms, while interaction generation/commit fell
from 473 to 352 ms. The new process profile moves the top frontier to
four-message BLAKE2 compression, memory movement, FFT tail layers, and
remaining lookup/interaction generation. This is a proof-wide elimination of
unnecessary extension arithmetic rather than movement of work outside the
request boundary.

## Rejection ledger after the sparse-field win

Several seemingly natural extensions were measured and reverted:

- Vectorizing `QM31` subtraction/negation plus zero/one cases increased proving
  time about 2% and increased instructions.
- A dedicated base-by-base branch regressed SHA2-128 proving from about 0.807
  to 0.848 seconds.
- Zero/one recognition inside every `QM31.mul` similarly raised instructions
  and regressed proving to about 0.848 seconds.
- Converting the ten fully unrolled four-message BLAKE2 rounds to a compact
  runtime schedule loop raised SHA2-128 instructions from about 298.0 to 312.9
  billion and slowed proving from about 0.807 to 0.824 seconds. SHA2-2048
  proving similarly rose from about 1.433 to 1.464 seconds. The AArch64 spill
  hypothesis was therefore rejected despite the smaller static loop.

None of these rejected changes remains in the final candidate. The short
screen is significant checkpoint evidence, not the task's final 2x verdict;
the clean immutable candidate still requires the full paired board, oracle,
and confidence gates.

## Candidate narrowing and resource guard

The first clean candidate, `b85a64a48850`, combined sparse-field preservation
with the packed batch-inverse layer. All 20 RISC-V rows passed the pinned oracle
and byte-identical proof gate, and the three class proving ratios were 0.8584,
0.7480, and 0.7813 for small, wide, and deep. Its Native CPU small and wide
guards were neutral. Native deep Plonk, however, twice put the peak-RSS
confidence upper bound just above the 1.05 budget: 1.0536 and 1.0592. Median
RSS moved only 0.3--1.9%, but the gate is defined on the upper bound and was
therefore a real failure.

The candidate executable was 98,192 bytes larger than the predecessor. Packed
QM31 inversion contributed roughly 36 KiB of specialized AArch64 text while
its measured benefit was only 0--2%. It was removed. This retained the
dominant sparse-field mechanism, reduced the final diff to 32 lines in one
file, and eliminated a low-value resource and maintenance risk. The final
candidate is `963f30da163a`.

The narrowed candidate passed the 380-source ReleaseFast closure, the RISC-V
prove/verify suite, and source conformance. Explicit Native CPU paired guards
then passed:

| Native class | proving ratio | 95% CI | result |
| --- | ---: | ---: | --- |
| small wide-Fibonacci | 0.9984 | [0.9890, 1.0087] | neutral, resource-clean |
| wide wide-Fibonacci | 0.9920 | [0.9829, 1.0009] | neutral, resource-clean |
| deep Plonk | 0.9821 | [0.9518, 0.9934] | no regression, resource-clean |

This narrowing is why the final submitted SHA differs from the first clean
screen. The complete `b85a64a` artifacts are retained as rejected-candidate
evidence rather than discarded.

## Final immutable paired evidence

`stwo-perf` measured `963f30da163a` against the exact immutable task baseline
`2beae9d03b33` on the same M5 Max host. The runner used counterbalanced paired
processes and adaptive 3--5 rounds per RISC-V row. All 20 timed workload proofs
verified, all predecessor/candidate proof digests were byte-identical per
round, and the pinned Stark-V correctness oracle accepted 20/20 workloads.
Mechanism telemetry was canonical and stable; proof size was exactly
unchanged.

| headline workload | proving ratio | 95% CI | request ratio | energy ratio |
| --- | ---: | ---: | ---: | ---: |
| SHA2-128 | 0.6203 | [0.6056, 0.6486] | 0.7432 | 0.8332 |
| SHA2-256 | 0.6283 | [0.6256, 0.6299] | 0.7367 | 0.8343 |
| SHA2-512 | 0.6806 | [0.6686, 0.6934] | 0.7503 | 0.8297 |
| SHA2-1024 | 0.7029 | [0.6933, 0.7226] | 0.7658 | 0.8278 |
| SHA2-2048 | 0.7116 | [0.7037, 0.7241] | 0.7865 | 0.8312 |
| Keccak-128 | 0.6571 | [0.6517, 0.6666] | 0.7210 | 0.8329 |

The headline proving geometric mean is 0.6659, a 1.502x acceleration. The
headline verified-request geometric mean is 0.7503, a 1.333x acceleration.
Across all 20 RISC-V programs, the proving and request geometric means are
0.8142 and 0.8514 respectively. Every individual RISC-V row improves; the
non-crypto fixed-geometry rows improve roughly 10--13%, while the six
hash-heavy rows improve 29--38% in proving.

Final class verdicts are all significant:

| class | workloads | proving geometric mean |
| --- | ---: | ---: |
| small | 6 | 0.8893 |
| wide | 7 | 0.7645 |
| deep | 7 | 0.8039 |

All reported peak-RSS vectors pass their named budgets. Candidate proof bytes
match the predecessor exactly, and energy improves in every RISC-V row.

The automatic `--guards all` route was also tested. It failed before producing
a verdict because the harness parsed Native Blake/Plonk guard commands as
RISC-V commands and required a RISC-V `{admission}` token. The partial
artifacts were retained. Objective verdicts were rerun with `--guards none`,
and the affected Native CPU classes were then measured explicitly on the
correct board as shown above.

## Status and next frontier

This is a significant and general checkpoint, but the requested system-level
2x completion contract is not met: no headline proving ratio is yet at most
0.50, verified-request geometric mean is 0.7503 rather than at most 0.50, and
the complete-board ratios are 0.8142/0.8514. **System-level 2x: not achieved.**

The new profile says the next CPU epoch must attack the work now exposed by the
sparse-field elimination: BLAKE2 compression, full-domain memory movement,
FFT tail layers, remaining interaction generation, and scheduling imbalance.
The genuine RISC-V Metal phase has not yet been implemented or judged and
cannot be claimed from this CPU change.
