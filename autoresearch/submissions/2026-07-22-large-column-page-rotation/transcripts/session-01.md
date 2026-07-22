# Autoresearch session 01 — RISC-V and scale portfolio

## Session start

The session began from promoted `main` at `e346656`, then ran the mandatory
`stwo-perf update` from a clean checkout. The update fast-forwarded to
`5bf964b78643`, which contains the backend restart fix from PR #70. Two
pre-existing untracked Metal notes were temporarily stashed and restored with
their original SHA-256 digests (`81263c43...81f3` and `7654c629...2bd`). They
are prior-research inputs, not candidate changes.

The objective is another complete autoresearch cycle: establish a fresh local
suite baseline before editing, profile the largest and longest workloads with
special priority on the live RISC-V board, implement only a mechanism supported
by measured attribution, run paired S3 verdicts for every moved board/class,
submit, and drive the PR through CI and promotion.

All five repository skills were loaded before the baseline:

- `match-algorithmic-problems` for any material algorithm replacement;
- `zig-profiling` and `metal-profiling` for S1 attribution before edits;
- `metal-performance-design` plus its required common-patterns reference for
  resource, ownership, ABI, dispatch, and architecture decisions; and
- `submission-transcripts` for contemporaneous reasoning and rejected ideas.

No source edit or performance claim has been made yet.

## Fresh full-suite baseline (before edits)

The repository inventory alone does not time workloads, so all three
ReleaseFast products were built and every manifest-owned scored row was run
locally with one verified warmup and one verified sample. This is diagnostic
grounding, not promotion evidence. Native CPU and Metal proofs were
byte-identical for every class, Metal reported zero CPU fallbacks, and all 20
RISC-V artifacts verified.

Native prove medians (ms):

| class | CPU | Metal | Metal dispatches | proof digest prefix |
| --- | ---: | ---: | ---: | --- |
| small | 1.526 | 6.919 | 18 | `91741aec9568` |
| wide | 7.164 | 12.189 | 22 | `57a7d291eb8a` |
| deep | 4.733 | 9.593 | 24 | `d63a2c928461` |
| xlarge | 167.371 | 163.914 | 26 | `f845568c1459` |
| huge | 683.905 | 587.854 | 28 | `e6609d0564a4` |

The full RISC-V basket took 10.111 s small, 16.845 s wide, and 20.121 s deep
when program request times are summed. Proving accounts for 9.615 s, 14.938 s,
and 17.841 s respectively. The slowest row is SHA2-2048 at 4.104 s total:
3.377 s proving, 0.617 s witness generation, and 0.091 s verification. Tiny
eight-step ALU/declared-region programs still take about 1.59 s, with roughly
1.50 s in proving. This rules out guest execution as the general bottleneck
and motivates profiling shared prover/PCS infrastructure first, while the
crypto-heavy deep tail also warrants a separate witness-generation check.

The Native results show the previously promoted skewed arena has closed the
xlarge CPU/Metal gap and made Metal the huge leader. Small Native classes are
still dispatch-economics dominated, but the objective prioritizes the longest
coordinates: RISC-V deep/wide and Native huge/xlarge.

## User steering and first architectural profile

The user explicitly challenged the small Metal/CPU gap and authorized a deeper
Metal architecture change. That concern is supported by the profile rather
than dismissed as generic GPU overhead. On huge wide Fibonacci, profiled CPU
prove was 705 ms and Metal 642 ms. Metal substantially accelerates stages that
actually run on device—main-trace commit 184 -> 91 ms and FRI 87 -> 39 ms—but
composition evaluation is 403 ms on the Metal product versus 341 ms on CPU.
It is 63% of Metal prove time. Metal uses 28 dispatches with zero fallback, so
the dominant gap is a host AIR stage between otherwise accelerated epochs.

The current type-erased component callback exposes only a whole-domain scalar
operation. Prior transcripts independently rejected a generic GPU rewrite:
the wide-Fibonacci recurrence lives in locked `src/examples`, the generic AIR
derive/vtable is also outside the editable surface, and identifying recurrence
semantics from an opaque context or trace shape would be unsound. A future
upstream interface should expose typed/batched constraint programs, but this
submission cannot weaken the editable-path contract to obtain that result.

The latest promoted arena already made a large architectural gain by placing
the 100 shared evaluation columns at `power_of_two_bytes + 64` byte strides.
That rotates cache-line set geometry. At huge, however, each logical column is
8 MiB: the 64-byte pad changes the virtual page only once per 64 columns, so
most of the 100 simultaneous streams retain a 2048-page stride and repeated
translation-set geometry. The next falsifiable layout experiment is an odd
page stride plus one cache line. I initially modeled a 4 KiB page here; the
real Apple-silicon host page was subsequently measured as 16 KiB. The live
implementation uses `std.heap.pageSize()`, so its actual pad is 16,384+64
bytes and adds about 1.55 MiB for 100 columns.
The CPU combined-arena upper bound is also currently 256 columns; RISC-V
reports 132 opcode plus 485 infrastructure columns, so raising the bound to
512 is the direct test of whether the same conflict-avoidance architecture
removes part of its fixed proving floor.

Real-device capability evidence: Apple M5 Max, 32 KiB maximum threadgroup
memory, 1024 maximum threads/threadgroup, 55.66 GB recommended working set,
unified memory. No optional Metal feature or new command is required by the
layout experiment.

A three-second whole-process sample of RISC-V SHA2-2048 additionally found
`quotient_tile_executor.execute` as the largest active top-of-stack frame
(1036 samples), with Merkle leaves, circle extension, constraint evaluation,
and witness ingestion behind it. `__ulock_wait2` counts are mostly idle pool
threads and are not treated as useful work. This makes quotient execution a
second candidate if the storage sweep is falsified.

## Problem-match and Metal design brief: translation-safe shared columns

```text
Task and required semantics:
  Place column-major M31 evaluations so the existing row-wise AIR evaluator,
  Metal commitment kernels, FRI aliases, and openings observe identical
  logical slices and proof order.

Inputs, scale, encoding, model:
  Native huge: 100 columns x 2^21 M31 evaluations after blowup (8 MiB/column).
  RISC-V: observed 132 opcode and 485 infrastructure columns across small
  quotient domains. Apple M5 Max UMA; cost model is cache-line and DTLB/set
  transfers plus unchanged arithmetic.

Constraints and structure:
  Each public column remains contiguous and original length; backing metadata
  is private to preparation/backend boundaries. Proof bytes, row order,
  dispatch order, AOT ABI, and completion ownership are invariant.

Candidate canonical matches:
  1. conflict-avoiding array padding/page coloring (exact layout transform);
  2. row-major transpose (exact, but breaks column-slice consumers);
  3. typed GPU constraint program (best long-term compute mapping, but locked
     AIR/vtable interface cannot describe it safely in this submission);
  4. tiled gather before composition (exact but adds a full 800 MiB pass).

Chosen variant and mapping:
  Conflict-avoiding padding of concurrent power-of-two streams. Change the
  physical stride from N+16 M31 words to N+(page_words+16), and let CPU groups
  through 512 columns use the existing combined arena. Logical recovery is
  identity slicing from the padded backing.

Complexity and limits:
  Work remains O(rows*columns). On this 16 KiB-page host, native 100-column
  storage overhead is ~1.55 MiB; a 485-column group adds <8 MiB. No extra pass
  or in-flight copy.

End-to-end prediction and falsifier:
  Huge composition should fall by >=10% if translation conflicts remain;
  xlarge and all guards should remain neutral or improve. RISC-V class time
  should move if its 485-column groups enter the combined path. Reject if
  composition does not move, RSS crosses its gate, any proof changes, or a
  guard regresses.

Metal resource/ownership plan:
  The existing shared evaluation arena remains GPU-produced and retained by
  commitment-tree owners through last use. Only offsets/size change. Existing
  command completion remains the CPU ownership boundary before composition.
  No new buffer class, encoder, pipeline, binding, wait, or feature fallback.

Validation:
  S1 live-field skew sweep, profiled huge CPU/Metal stages, full Native proof
  parity, exact RISC-V artifacts, ReleaseFast tests, AOT/source-JIT gates, then
  paired S3 only for classes whose diagnostics move.
```

## S1 result: page coloring is nearly neutral

The isolated live-field harness used the repository's `M31`/`QM31` types,
100 columns, a power-of-two logical stride, 16,384 sampled rows, and the same
98-term recurrence/secure-accumulation shape as the wide AIR. Five measured
rounds of two iterations gave:

| physical pad | median ns/op | min ns/op | instructions/op | cycles/op | IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16 M31 words (64 B) | 1.254 | 1.103 | 42.16 | 5.052 | 8.344 |
| 1040 M31 words (4 KiB+64 B probe) | 1.241 | 1.131 | 42.16 | 5.016 | 8.405 |

The approximately 1% median change was too small to support the predicted
translation-conflict mechanism at that displacement. The later `getconf
PAGESIZE`/`hw.pagesize` check returned 16,384 bytes: S1 had tested a quarter
page, while the repository implementation correctly used the real page size.
That mismatch explains why the full implementation produced a much larger
signal and is retained as an explicit experimental correction.

## S3 diagnostic screen: full-domain geometry confirms the mechanism

Contrary to the deliberately smaller S1 harness, three alternated predecessor /
candidate huge runs showed a repeatable full-proof improvement. The larger
domain and real commitment/evaluator lifetime are therefore essential to the
effect:

| backend | predecessor prove range | candidate prove range | predecessor composition | candidate composition |
| --- | ---: | ---: | ---: | ---: |
| CPU | 679.18–679.87 ms | 600.15–608.98 ms | 327.30–330.03 ms | 269.90–271.60 ms |
| Metal | 585.82–591.76 ms | 503.26–513.61 ms | 363.25–370.89 ms | 285.69–289.10 ms |

Every run produced the canonical huge digest
`e6609d0564a47192212bec7973e2660c2eea88bef90c573c3df09569cc3c7e86`.
Metal retained 28 dispatches and zero CPU fallbacks. Its main-trace commitment
remained about 93–94 ms, isolating the gain to the host AIR traversal over
GPU-produced unified-memory columns. Candidate peak physical footprint was
within roughly 2 MiB of the predecessor in paired runs.

The separate CPU maximum-column experiment did not actually admit the
617-column RISC-V tree (and the already-admitted 188-column interaction tree
was neutral). Two paired ALU diagnostics were 1570.3/1571.7 ms predecessor
versus 1564.7/1579.4 ms candidate with identical artifacts, so that constant
is reverted. Only the evidenced physical-stride change remains.

## First official Metal huge verdict and guard-driven scale boundary

The five-round official S3 Metal huge objective was significant at ratio
0.8733, 95% CI [0.8640, 0.8832], 575.979 ms predecessor versus 507.800 ms
candidate. G1, G2, G3, and resource/request checks passed, but G4 correctly
rejected the broad page-padding policy: Blake guards regressed 8–10% and
Poseidon guards 12–16%. Those shapes have small physical columns, so a fixed
16 KiB pad is a large fraction of useful storage and defeats locality.

The refinement follows the measured cost model rather than naming AIRs:
columns below 2^18 M31 words retain the already-promoted 64-byte skew exactly;
only groups with at least 64 columns and at least 1 MiB of useful data per
column receive the page-plus-line rotation. This leaves every failing guard's
layout identical to the predecessor while selecting xlarge (2 MiB extended
columns) and huge (8 MiB extended columns). The official verdict is discarded
and will be regenerated with all guards.

## Final official verdicts

The scale-gated layout produced four clean, significant S3 verdicts against
exact predecessor `5bf964b78643` at candidate `bf7cf1849130`:

| board / class | predecessor | candidate | ratio (95% CI) | improvement |
| --- | ---: | ---: | ---: | ---: |
| CPU xlarge | 165.947 ms | 146.031 ms | 0.878534 [0.864409, 0.889791] | 12.15% |
| CPU huge | 687.070 ms | 601.631 ms | 0.878685 [0.875646, 0.883551] | 12.13% |
| Metal xlarge | 160.028 ms | 139.680 ms | 0.867736 [0.844552, 0.874057] | 13.23% |
| Metal huge | 565.486 ms | 495.138 ms | 0.880262 [0.868619, 0.888441] | 11.97% |

All four pass G1–G5, all 13 regression guards, request-time gates, resource
budgets, cross-arm proof equality, and the pinned oracle. Proof sizes remain
74,328 bytes at xlarge and 86,383 bytes at huge. Metal diagnostic runs retain
26/28 dispatches for xlarge/huge and zero CPU fallback.

The first two Metal-xlarge suites were not claimed: the objective was already
significant, but unchanged tiny Fibonacci guards exceeded their CI budget.
Subsequent clean sequential evidence passed without a source change. This is
recorded rather than hiding the retry.

The resulting dataflow is:

```text
Metal LDE writes contiguous logical columns into unified memory
                         │
                         ▼
  before: stride N + 64 B
          cache-line index rotates; most page/TLB geometry repeats

  large:  stride N + 16 KiB + 64 B
          page index rotates ───────┐
          cache-line index rotates ─┴─► CPU AIR row fan-in de-aliased
                         │
                         ▼
           identical logical slices, commitments, and proof bytes
```

This explains why Metal was only modestly ahead of CPU: the benchmark is a
hybrid prover, and huge composition remained a CPU traversal over 100
GPU-produced unified-memory columns. The GPU-owned stages were accelerated,
but the host traversal dominated. This change removes a large memory-system
penalty at that boundary; a future larger step would require a typed AIR
constraint representation that can safely execute composition itself on GPU.
