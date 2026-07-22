# Autoresearch session 01 — post-run-strength-reduction RISC-V epoch

## Objective and inherited frontier

This iteration begins immediately after PR #81 merged and its claimed promotion
was recorded on canonical main `e20d72ac90af`. The standing loop is improvement
-> PR -> green CI -> merge -> repeat, prioritizing the largest and longest
coordinates and especially RISC-V. The promoted run-wise lifted quotient
accumulator reduced the `riscv/deep` proving-time portfolio to ratio 0.724575
with 95% CI [0.723189, 0.726258], preserved proof bytes and RSS, cut measured
energy to 0.537x, passed the pinned oracle for 7/7 rows, and cleared aggregate
CPU, Metal, and RISC-V CI before merge.

The current frontier still makes RISC-V deep the largest active portfolio
coordinate: candidate proving geomean is 1780.298 ms, versus sub-second Native
huge and approximately 157 ms for the best recorded Metal huge result. The next
iteration therefore remains on the shared CPU prover/RISC-V path unless fresh
profiles contradict that choice.

## Skills and method

All repository performance skills were reread from current main before action:
algorithm matching, Zig profiling, Metal profiling, Metal performance design,
and submission transcripts. The compute-only Metal common-patterns reference
was also read completely; render guidance is inapplicable. Their combined
contract is: profile the new frontier before editing; produce and retain a
problem-match brief before a material algorithm change; use counters and codegen
for CPU claims; use trace/dispatch evidence for Metal claims; preserve exact
proof/transcript behavior and broad product architecture; and record rejected
ideas and failures contemporaneously.

No epoch-two source has been edited. The first action is to build the clean
post-merge product, rerun the largest release-gated row, and sample its new hot
frames. The previous profile is not reused as current attribution because the
dominant quotient executor just changed by roughly 29%.

## Fresh baseline and profile

The clean post-merge SHA2-2048 request is 2.916904 s: 2.303770 s proving,
0.508096 s witness generation, and 0.086911 s verification. It embeds clean
commit `e20d72ac90af`, preserves statement digest
`6bc61b060cd26d38c7d620dc6b3f17829221d310b498e7c7c8e63a01f3e97e88`
and transcript state
`4ca8cf9f10ca8322420b8cec1bdcd426958ca06ad6371878c3ddbcbc2da5fac8`,
and verifies normally.

A three-second sample of that exact executable gives these useful top frames
after excluding idle worker waits:

| frame | top-of-stack samples |
| --- | ---: |
| quotient tile executor | 1,705 |
| packed Merkle leaf update | 749 |
| `memmove` | 708 |
| four-way Blake compression | 573 |
| RISC-V LogUp pair constraint | 406 |
| scalar/SIMD Blake compression | 366 |
| fused circle-transform tails | 353 |
| quotient denominator batch inversion | 187 |

Quotient execution remains the largest single ceiling, but is now much closer
to Merkle and memory movement. Disassembly confirms the remaining hot executor
contains both direct packed M31 multiplication and the non-direct run-wise path;
the latter still performs one output-plane addition per contribution per row.

## Compact-domain grouping hypothesis and first shape measurement

The algorithm-match brief formalizes quotient accumulation as a structured
sparse linear transform over the exact M31 plus-times semiring. Because lifting
is linear, contributions sharing one sample batch and source geometry may be
coefficient-combined before lifting. This preserves exact field values while
collapsing output additions from per contribution to per unique group. The
brief compares this with full materialization, cross-batch grouping, and a
future Metal port, and is retained through `stwo-perf notes`.

An initialization-only diagnostic counter (not a hot-loop change) then measured
the largest live quotient plan: domain 2,097,152 rows, 13 batches, 1,290 active
nonzero views, 2,162 contributions, but only 35 unique `(batch, geometry)`
groups. Contribution shifts are: shift1=40, shift2=16, shift3=18, shift5=291,
shift6=637, shift8=320, shift9=144, shift13=65, shift14=102, shift15=55,
shift16=91, and shift17=383. Thus the algebraic contraction is real and large.

Naively retaining four compact coordinate arrays for all 35 groups would cost
153,270,784 bytes, however, exceeding the brief's 32 MiB bound and likely the
portfolio RSS budget. That all-group materialization is rejected. The direct
and near-direct geometries dominate bytes, while the many high-shift groups
have tiny compact sources. The next diagnostic breaks unique-group bytes down
by shift so a structural, memory-bounded crossover can be selected.

## Selective crossover and implementation decision

The second diagnostic resolved the unique-group storage by lifting shift as
`shift: groups / bytes`: 1:2/67,108,864; 2:3/50,331,648;
3:3/25,165,824; 5:3/6,291,456; 6:3/3,145,728;
8:3/786,432; 9:3/393,216; 13:3/24,576; 14:3/12,288;
15:3/6,144; 16:3/3,072; and 17:3/1,536. Selecting shifts at least
five therefore needs only 10,664,448 bytes, groups 2,088 of 2,162 live
contributions into 27 combined views, and leaves the 74 contributions in the
large shift-1..3 geometries on the promoted direct/run-wise executor.

This falsifies full grouping but strongly supports a hybrid. The implementation
will add a checked 32 MiB plan budget and a structural minimum shift of five.
The selective plan is attempted before building direct views; only after it is
fully admitted may those same high-shift columns be removed from the direct
plan. Budget exhaustion or allocation failure frees partial state and selects
the unchanged all-direct path, preventing double counting or missing work.
There is no workload name, statement digest, benchmark size, or RISC-V-specific
condition. At the hot loop, compact coordinate planes already contain the
coefficient-weighted field sums, so the tile executor lifts and adds each group
without multiplying again. Direct and scalar fallbacks remain supported.

The CLI refresh was also re-run before editing. Canonical main contained three
valuable untracked research notes, so they were temporarily stored as one
explicit Git stash, `stwo-perf update` confirmed main `e20d72ac90af` current,
and the stash was restored immediately without conflict. All five repository
skills and the compute-only Metal common-patterns reference were reread. Metal
guidance constrains this shared-prover change even though no shader changes:
proof identity and backend admission remain exact, no new dispatch, wait,
resident object, or lifetime system is introduced, and the complete Native
Metal portfolio remains a required regression guard.

## First implementation falsified: serial compact materialization

The first implementation reused the compatibility planner to materialize the
selected 27 compact coordinate groups, taught the bounded tile executor to lift
those arrays without coefficient multiplication, retained the 74 low-shift
direct contributions, added scalar/parallel plumbing and byte telemetry, and
passed the complete ReleaseFast test root. A full verified SHA2-2048 proof kept
the statement and transcript digests exact. Process counters moved strongly:
instructions were 0.749x and cycles 0.840x the clean-main process. Nevertheless,
the one-process proving time was 2.322 s versus the fresh 2.304 s baseline, and
request time was 2.965 s versus 2.917 s. The wall-time prediction therefore
failed despite less aggregate CPU work.

A three-second whole-process sample explained the contradiction. The main
thread accumulated 116 samples inside
`buildCombinedContributionPlanWithOptions` before quotient workers started.
The compatibility builder performs all compact coefficient products serially;
the promoted run-wise executor had distributed essentially the same products
across the proof worker pool. The implementation had shortened total work but
lengthened the critical path. This is retained as a rejected architecture, not
hidden as noise.

The revised transfer keeps the exact sparse-linear grouping but changes its
placement. Planning will retain only small immutable descriptors: groups keyed
by `(batch, source geometry)` and members holding a borrowed compact column plus
its four M31 coefficients. Inside each quotient worker and source run, the
members reduce into two four-coordinate register accumulators (even/odd), then
one packed alternating group value is added across the run. This keeps compact
multiplications parallel, collapses output additions from contribution count to
group count, removes the 10.7 MiB materialization, and preserves bounded worker
ownership. Descriptor admission remains checked and structural; allocation or
budget failure keeps every contribution in the existing direct path.

The first register-group screen validated the revision. SHA2-2048 proving fell
from the clean 2.303770 s baseline to 2.215191 s (ratio 0.96155), and verified
request time fell from 2.916904 s to 2.855866 s (ratio 0.97907). Statement and
transcript digests remained exact; process instruction and cycle ratios were
0.74191 and 0.87246. Because the descriptor plan is now tens of kilobytes rather
than compact-column megabytes, shift five is no longer a memory crossover. The
next screen groups every structurally non-direct view (shift at least two),
covering the remaining shift-2 and shift-3 contributions while preserving the
packed direct path for shift one.

## Frozen architecture and portfolio screen

The all-lifted policy improved the first SHA2-2048 screen to a 0.94821 proving
ratio and 0.96057 request ratio. A three-sample repeat after the source was
split into conformance-sized modules stabilized at proving ratio 0.95388 and
request ratio 0.97234, with per-proof instruction, cycle, and energy ratios
0.73346, 0.85705, and 0.81794. All three proofs were identical. Candidate-only
screens against the preceding promoted samples won on every deep workload:

| workload | diagnostic prove ratio | diagnostic request ratio |
| --- | ---: | ---: |
| xorshift | 0.95455 | 0.96048 |
| iterative Fibonacci | 0.94233 | 0.94420 |
| GCD | 0.91928 | 0.92278 |
| multi-shard ADDI | 0.93502 | 0.93589 |
| SHA2-512 | 0.93083 | 0.90585 |
| SHA2-1024 | 0.91045 | 0.91040 |
| SHA2-2048 | 0.90432 | 0.90351 |

Source conformance then rejected the 989-line tile executor against its
850-line ceiling. Rather than suppressing the gate, the register reduction and
its differential test moved to `quotient_compact_groups.zig`, and direct-plan
construction moved to `quotient_direct_plan.zig`. The scheduler fell to 796
lines and conformance passed. The split preserved the same mechanism and made
the compact kernel independently testable at shifts 2, 3, and 8. A planning
test covers multi-member grouping, exclusion of a direct geometry, checked
retained bytes, and budget-triggered direct fallback. The aggregate ReleaseFast
test root, RISC-V CPU product closure, source conformance, Native CPU product
markers, Native Metal closure, and the device-only Metal prove/independent-
verify lifecycle all pass.

## Clean S3 verdict and provenance correction

The frozen source commit is `19ca3b8863ee903daf0e52a8df08406fb804f8c2`.
The first official S3 objective series was significant at R=0.961478, but raw
reports exposed `implementation_dirty=true` in both arms because valuable
untracked autoresearch notes participate in build identity. That evidence is
retained under `dirty-provenance-register-groups` but rejected as promotion
evidence. Both note sets were stored in explicit path-scoped Git stashes, both
worktrees were verified empty, and the series was repeated. The first restart
stopped before timing because the harness correctly refused to overwrite old
proof artifacts; the complete prior raw directory was archived, not deleted.
The subsequent clean series rebuilt both binaries and every raw A/B report
records `implementation_dirty=false`. All notes were restored afterward.

The clean claimed S3 `riscv/deep` result is R **0.958426**, bootstrap 95% CI
**[0.954944, 0.962133]**, versus threshold 0.987112. Verified-request ratio
geomean is **0.964371**. Every row wins independently:

| workload | prove ratio | 95% CI | rounds | main prove | candidate prove | request ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| xorshift | 0.961191 | [0.954873, 0.966907] | 5 | 1468.060 ms | 1408.839 ms | 0.962210 |
| iterative Fibonacci | 0.960254 | [0.958887, 0.964196] | 3 | 1636.723 ms | 1569.976 ms | 0.962307 |
| GCD | 0.959542 | [0.953218, 0.962870] | 5 | 1560.442 ms | 1494.326 ms | 0.961622 |
| multi-shard ADDI | 0.968090 | [0.959831, 0.976283] | 5 | 1620.772 ms | 1570.431 ms | 0.974301 |
| SHA2-512 | 0.945873 | [0.933950, 0.966858] | 5 | 1843.937 ms | 1756.293 ms | 0.962728 |
| SHA2-1024 | 0.954801 | [0.939027, 0.963837] | 5 | 2149.973 ms | 2051.770 ms | 0.964895 |
| SHA2-2048 | 0.959373 | [0.952284, 0.964520] | 5 | 2379.370 ms | 2292.504 ms | 0.962600 |

The energy ratio geomean is **0.834744** (upper CI 0.839936), peak RSS is
**0.999729** (upper CI 1.000914), and proof bytes are exactly 1.0x. Every timed
sample verified, cross-arm proof digests are byte-identical per round, mechanism
telemetry is present for 7/7 workloads, and the pinned Stark-V oracle accepted
7/7. Candidate/epoch anchor is 0.6626. No average hides a losing workload.

Local automatic guard expansion remains affected by the already documented CLI
classifier defect: Native guard IDs are parsed as RISC-V and rejected for not
containing the RISC-V-only admission token. The clean objective verdict therefore
uses `--guards none`; shared product gates were executed separately, and the PR
must remain conditional on the authoritative remote aggregate CPU, Metal, and
RISC-V guard matrix. This optimization changes only bounded CPU quotient input;
the raw Metal backend, dispatch graph, residency, waits, and ABI are unchanged.

This is another material RISC-V improvement, but it does not supply the exact
PR6 all-cell, cold-process, log22, and authenticated judged evidence contract.

**PR6 Supremacy: not achieved.**
