# Session 01 — paired CPU + Metal optimization

## Objective and constraints

The user resumed the autoresearch loop after PR #35 and added a strict rule:
every new submission must optimize both the `core_cpu` and `core_metal`
backends together. A backend-only win is therefore not eligible even if it is
statistically significant. The loop remains benchmark -> profile -> design ->
implement -> paired S3 evidence -> submit -> PR -> green CI -> merge -> repeat.

The canonical checkout was updated with the repository-resident `stwo-perf`
CLI from `91d18f7` through the current recorded main `7c7cc46`. Two pre-existing
untracked research notes were temporarily relocated and restored byte-for-byte
because `stwo-perf update` correctly refuses a dirty canonical checkout.

PR #35 (`metal-resident-fri-inverse-domains`) was verified to descend from the
current Metal class frontiers, merged as `6448467`, recorded as promoted, and
passed post-merge CPU, Metal, oracle, package, static, and RISC-V CI. This new
workspace begins at the resulting recorded main rather than an intermediate
source commit.

## Skills and initial decision

All repository skills were read before acting:

- `submission-transcripts`: this file is being maintained during the search,
  not reconstructed after success.
- `match-algorithmic-problems`: any algorithm replacement will first receive a
  formal problem-match brief with a falsifiable operation/traffic prediction.
- `zig-profiling`: CPU hypotheses must be attributed with live-code counters,
  sampling, or codegen evidence before edits.
- `metal-profiling`: Metal hypotheses must include device/runtime evidence and
  distinguish kernel time from dispatch/wait economics.
- `metal-performance-design`: the prover is compute-only; designs will follow
  its resource, ownership, dispatch, and ABI framework, including the required
  common-patterns reference. Render/TBDR advice is intentionally excluded.

The first architectural preference is a shared mathematical/dataflow change in
`src/core/**` or `src/prover/**` that reduces work in both implementations. If
the backend split makes that impossible, one submission may contain a paired
CPU specialization and Metal specialization only when both have independent
measured wins and share one semantic mechanism. Merely bundling unrelated wins
would make attribution and future lineage harder, so it is a fallback rather
than the starting point.

## Baseline plan

1. Build both enabled benchmark groups from this exact workspace.
2. Run fresh production-like CPU and Metal measurements for all three classes.
3. Mine prior notes/submission transcripts for remaining shared hotspots and
   rejected approaches.
4. Profile the best shared candidate at CPU S1/S2 and Metal kernel/trace scope.
5. Write the problem-match and Metal design briefs before editing algorithmic
   or backend architecture.

## Fresh S3 baseline evidence

`stwo-perf setup` built both enabled production groups (`native`, `metal`). Six
objective-only S3 A/A runs then exercised every scored class on both boards,
15 paired rounds each. Median-of-report-medians across the 30 A/B reports:

| class | CPU prove ms | Metal prove ms | Metal dispatches |
| --- | ---: | ---: | ---: |
| small | 1.572 | 2.588 | 18 |
| wide | 11.199 | 9.016 | 22 |
| deep | 6.828 | 5.011 | 24 |

Reported A/A ratio and bootstrap half-width:

| board/class | ratio | half-width |
| --- | ---: | ---: |
| CPU small | 0.99927 | 0.01570 |
| CPU wide | 1.01458 | 0.02616 |
| CPU deep | 0.99948 | 0.00629 |
| Metal small | 0.95971 | 0.03032 |
| Metal wide | 1.02110 | 0.02209 |
| Metal deep | 0.98530 | 0.01811 |

The Metal small A/A center is materially displaced from 1 despite identical
trees. This is evidence of order/thermal/runtime drift, not a software win.
Therefore absolute timings and unpaired before/after runs are diagnostic only;
all candidate decisions must use same-session interleaving, and a credible
dual-backend candidate should target more than the 1% floor on each board.

## Fresh stage attribution and first rejected hypothesis

Seven-sample profiled production runs show these dominant median stages:

| class/backend | composition eval | FRI build+commit | sampled eval | main commit |
| --- | ---: | ---: | ---: | ---: |
| CPU small | 0.040 ms | 0.832 ms | 0.089 ms | 0.265 ms |
| CPU wide | 2.717 ms | 3.249 ms | 0.751 ms | 2.014 ms |
| CPU deep | ~0.13 ms | 3.231 ms | 0.370 ms | 0.954 ms |
| Metal small | 0.038 ms | 2.698 ms* | 0.339 ms | 0.811 ms |
| Metal wide | 2.868 ms | 1.880 ms | 0.865 ms | 1.687 ms |
| Metal deep | 0.132 ms | 1.741 ms | 0.828 ms | 0.695 ms |

`*` Profiling perturbs the short Metal-small process heavily (5.02 ms profiled
versus 2.59 ms unprofiled), so its absolute stage values are diagnostic only.

Wide composition evaluation is the first truly shared large stage: both
backends execute the same host AIR evaluator. Source inspection shows the wide
AIR is one component, so the existing component-level worker-pool split cannot
parallelize it. Its locked example loop performs 30 recurrence constraints for
each of 32,768 quotient-domain rows and accumulates a QM31 random coefficient
times one M31 constraint.

The first candidate was fixed four-limb SIMD for `QM31.mulM31` plus addition.
A `stwo-prof` live-module harness modeled the exact row recurrence and secure
linear combination. The initial root-module harness failed because the scratch
module did not inherit the repository's named `stwo_core` dependency; that run
was discarded and the harness was rewired directly to live `src/core/mod.zig`.
Fifteen ABBA rounds on the valid harness measured explicit SIMD/scalar:

- wall ratio 0.9790, 95% CI [0.9656, 0.9975];
- instruction ratio 0.9706;
- cycle ratio 0.9759; and
- baseline/candidate 51.64/50.51 ns per modeled row.

The mechanism is genuine but predicts only about 0.057 ms from a 2.7 ms stage,
or roughly 0.5% end-to-end. That is below the promotion floor and does not
justify a broad field-ABI edit as the primary architecture. It is retained as
a possible additive optimization, not implemented yet.

## Full-process sampling and second target

A five-second `/usr/bin/sample` capture of a larger ReleaseFast CPU wide proof
(`log_n_rows=18`, `sequence_len=64`, 10 warmups, 21 samples) attributed useful
top-of-stack samples as follows: `compressParallel4` 3,210,
`evaluateBuffersWithTwiddles` 2,861, Merkle leaf construction 1,560,
`quotient_tile_executor` 1,435, and
`CircleCoefficients.evalManyAtPointsWithFlatFactors` 1,428. The wide AIR
quotient evaluator itself accounted for 1,393 and IFFT workers 1,331. The
47,120 `__ulock_wait2` samples are collapsed idle worker time across all
threads, not proof work. This both validates the stage timers and shows that
coefficient sampled-value evaluation remains a first-order CPU target after
the already-merged SIMD work.

Metal capability discovery reports a real Apple M5 Max, 32 KiB maximum
threadgroup memory, 1,024 maximum threads per threadgroup, 55.66 GB recommended
working set, and unified memory. A Metal System Trace was attempted with the
repository profiler and failed because `xctrace` requires full Xcode while this
machine selects `/Library/Developer/CommandLineTools`. This is only a trace-
capture limitation: the benchmark uses the system Metal runtime compiler via
`newLibraryWithSource`, and the production command buffers expose GPU start/end
timestamps. Subsequent Metal attribution therefore uses real-device stage
timers, GPU timestamps, dispatch telemetry, and source dependency analysis.

## Problem-match brief: shared circle-basis materialization

**Problem and exact semantics.** For one circle point with factors
`f[0..log_size)`, evaluate many M31 coefficient vectors as QM31 values while
preserving the repository's coefficient ordering, field results, output order,
and proof bytes. Expanding the existing recursive/carry evaluator gives the
canonical subset-product linear form

```text
basis[0] = 1
basis[i] = product(f[bit] for every set bit in i)
value(column) = sum(coeff[column][i] * basis[i])
```

The identity is already independently embodied by the current Metal evaluator,
which materializes exactly this basis and dots it with every coefficient
column. This is therefore a representation/dataflow transfer, not a new
cryptographic algorithm or an assumption change; no external canonical
algorithm is required.

**Candidate mechanisms.** The current CPU direct-product carry evaluator is
excellent for few columns but performs one full packed QM31 multiplication per
coefficient and per native-width column batch. The current Metal basis kernel
reconstructs every basis element independently from all its set bits, averaging
`log_size/2` full QM31 multiplies. Alternatives considered were a serial basis
walk (poor GPU parallelism), one dispatch per basis level (log-size dispatch and
global synchronization cost), and a fused matrix kernel (larger ABI and
correctness surface before establishing the simpler mechanism). Selected:

- CPU: construct the basis once per point with
  `basis[i] = basis[i & (i - 1)] * f[ctz(i)]`, then reuse it across packed
  QM31-by-M31 dot products for every column;
- Metal: retain the current materialized-basis/evaluation ABI, but split the
  basis index into an 8-bit low part and a high block. Each lane constructs its
  low subset once; lane zero constructs one high subset per 256-entry block;
  every output then needs at most one low×high multiply.

**Falsifiable cost prediction.** At log14, 32 columns, one point, the CPU path
changes roughly eight packed full-QM31 coefficient reductions into one scalar
full-QM31 basis construction plus eight packed QM31×M31 dot products. The Metal
basis kernel changes about `2^14 * 7 = 114,688` full QM31 multiplies to roughly
`2^14 + 256*4 + 64*3 = 17,600`, with unchanged coefficient and output bytes.
The hypothesis is rejected if the CPU sampled-value stage does not improve, if
Metal GPU/stage time is neutral, or if any scalar/candidate result differs.

## Metal architecture brief: two-level reusable basis

**Target and boundary.** Compute-only Native Metal source-JIT/AOT-compatible
proving on the measured M5 Max. Compilation remains outside the ten post-
warmup samples. The oracle is the scalar CPU evaluator plus fixed proof hashes.

**Dependency graph.** The runtime ABI, command count, buffer ownership, and
failure path remain unchanged:

```text
host factors/tasks -> shared buffers -> basis kernel -> private QM31 basis
                                                   -> polynomial dot kernel
host coefficients -------------------------------^          |
shared output <------------------------------------------------+
                    one command buffer, one terminal wait
```

Inside the basis kernel only, the dependency changes from an independent
popcount product per global element to register/threadgroup reuse:

```text
lane low bits -> low product (register) ----\
                                             * -> basis[block*256 + lane]
lane 0 high bits -> block product (4 words)-/
                         barriers bound each block lifetime
```

**Resources and occupancy.** Each workgroup remains 256 threads and owns one
point. The design adds one 16-byte threadgroup QM31 value, far below the 32 KiB
limit; low products stay in registers. Private basis bytes, shared upload/output
bytes, number of tasks, command buffers, encoders, and in-flight proof count
are invariant. The final barrier prevents lane zero from overwriting the high
product while another lane still consumes it. No new Metal feature, math mode,
fallback, shader export, Objective-C selector, or pipeline-cache identity is
introduced, so source-JIT and authenticated AOT consume the same ABI-compatible
kernel.

**Validation ladder.** First add deterministic basis-vs-carry and packed-dot
tests, then existing prover/Metal polynomial tests, ReleaseFast product builds,
profiled sampled-stage/GPU telemetry, exact proof hashes, and uninstrumented
same-session CPU and Metal S3 A/B runs. A later fused matrix kernel is deferred
unless this lower-risk cut proves that basis generation/reuse is material.

## Implementation evolution and profiler feedback

The first implementation materialized one CPU basis per worker. Wide sampled
evaluation fell from 0.751 to 0.474 ms and Metal from 0.865 to 0.588 ms, proving
the mechanism, but CPU deep was near break-even. The design was then made
symmetric: all point bases are prepared once and shared read-only across CPU
workers, and the CPU builder uses the same 8-bit low/high split as Metal. That
moved profiled CPU sampled medians to 0.056 ms small, 0.338 ms wide, and 0.231
ms deep, versus 0.089/0.751/0.370 ms at the frontier.

A live-code `stwo-prof zig` harness then isolated the log14 basis builder at
4.318 ns/element, 68.15 instructions/element, 17.44 cycles/element, IPC 3.91.
Persisting the low tile in Karatsuba-ready packed form avoids recomputing its
operand sums for every high block and measured 3.902 ns/element, 68.55
instructions, 15.87 cycles, IPC 4.32: a 9.6% cycle/wall reduction. This is a
small integrated contribution but directly confirms the intended reuse.

The wide host composition path exposed two additional ownership costs shared
by CPU and Metal proving. A newly allocated zero bucket receives one sequential
write per row, yet the generic accumulator loaded and added zero each time.
Afterward, finalization allocated another zeroed 512 KiB column and copied the
sole already-max-domain bucket into it. The implemented guard permits direct
first stores only while indices arrive exactly in fresh sequential order; any
repeat/out-of-order access permanently returns to additive semantics. When
there is exactly one max-domain bucket, finalization transfers its ownership
instead of copying. A dedicated test checks both repeated-index addition and
pointer-preserving final transfer.

Finally, the prior S1 four-limb result was integrated into `QM31.add`, `sub`,
and `mulM31`, mapping the four exact M31 coordinates to fixed Vec4 operations.
Wide composition fell by roughly another 0.06 ms while preserving the proof.

Rejected after measurement:

- Reducing once per four coefficient products was mathematically safe—four
  maximal canonical M31 products fit in `u64`—but made CPU sampled evaluation
  0.338 -> 0.349 ms and Metal 0.588 -> 0.604 ms. Both versions were removed.
- Lowering sampled-value worker grain from eight columns to four raised the
  nested tree/plan parallelism onto slower/overhead-dominated workers and was
  neutral/slightly worse (0.338 -> 0.344 ms); it was removed.
- The first official CPU screen improved wide by 2.21% but did not clear its
  conservative noise-adjusted band. Shared-basis ownership raised this to
  3.52%; the measured field-lane specialization supplied the remaining margin.
- Full Metal System Trace remains unavailable without Xcode; the failed
  `xctrace` command is retained above rather than represented as device data.

## Correctness, product gates, and paired S3 outcome

The scalar-vs-batched polynomial property test now covers the materialized
basis path, and source-JIT Metal execution independently checks the same basis
against CPU proof bytes. ReleaseFast `stwo_core` (70-source), `stwo_prover`
(152-source), and Native CPU (190-source) closures passed, as did Native Metal
product tests, Metal parity, AOT tooling contracts, formatting, and source
conformance. Source-JIT produced no CPU fallbacks and retained the expected
18/22/24 dispatch counts. Fixed proof hashes remained:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`;
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`;
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`.

Official same-session, uninstrumented wide S3 verdicts against untouched
`7c7cc46`, with objective-only local guards, are:

| board | predecessor ms | candidate ms | ratio | 95% CI | result |
| --- | ---: | ---: | ---: | ---: | --- |
| core_cpu | 10.739 | 10.246 | 0.9511 | [0.9329, 0.9609] | significant |
| core_metal | 9.363 | 9.105 | 0.9686 | [0.9502, 0.9881] | significant |

Both G1 exactness/oracle checks and G2 scope checks passed. The candidate is
frozen here because the user required immediate submission once one coherent
solution significantly improved both CPU and Metal.

## Current-policy rerun

Submission validation detected that origin had advanced five harness/history
commits after the initial measurements. The canonical CLI was updated from
`7c7cc46` to `3979c29` while preserving the two pre-existing untracked notes,
both workspaces were synchronized, and candidate `95f1740` was cleanly
reapplied as `61f233b`. No changed frontier file overlapped the six candidate
source files. Because the harness hash changed to `827c0794eea9`, both claimed
verdicts were rerun rather than reusing stale evidence:

| board | predecessor ms | candidate ms | ratio | 95% CI | result |
| --- | ---: | ---: | ---: | ---: | --- |
| core_cpu | 10.984 | 10.258 | 0.9331 | [0.9211, 0.9576] | significant |
| core_metal | 9.596 | 9.199 | 0.9533 | [0.9393, 0.9629] | significant |

These current-policy verdicts supersede the earlier local table. G1--G5 pass
for both, including exact cross-arm proofs, the Rust oracle, scope, and request
budgets.

## Policy-separated submission packaging

The first package attached both current-policy verdicts because the CLI still
describes board/class pairs as independently claimable. Central validation now
enforces one verdict per workload class within a submission directory, so it
rejected the CPU-wide plus Metal-wide pair as a duplicate `wide` claim. No
source or measurement was changed in response. The first package was
regenerated with only the requested Metal-wide verdict and passed validation.

After that Metal submission lands, the already-significant CPU-wide verdict is
being packaged in a second submission directory. This preserves one claim per
class per submission while retaining the exact source commit `61f233b`,
predecessor `3979c29`, harness `827c0794eea9`, and ratio 0.9331 with 95% CI
[0.9211, 0.9576]. The separation is an evidence-envelope constraint, not a new
optimization or a rerun with altered code.
