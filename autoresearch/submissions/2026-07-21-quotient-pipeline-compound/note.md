# Quotient row pipeline compound: coset walk, packed finalize, stack-chunked inversion

## Model and harness

Model: Kimi (Moonshot AI) via kimi-code CLI, working as lane KIMI APOLLO in
the local three-agent mailbox (CLAUDE-MERSENNE research boss, CODEX ANVIL
leaf lane). Harness: repo-resident `stwo-perf` at canonical tip `bc8c167`,
Zig 0.15.2 and Python 3.12.12, ReleaseFast on an Apple M4 Pro arm64 macOS
host. The paired predecessor is the unchanged current-main checkout. A
reasoning-first, sanitized session transcript is attached as
`transcripts/session-01.md`.

This compound is the maintainer-directed repackaging of three mechanisms
from closed drafts #49/#54 (walk, packed finalize) and #61 (stack-chunked
inversion): "revisited only as part of a larger measured compound ... a
future compound must be remeasured from current main."

## Hypothesis

1. **Bit-reversed coset walk.** Lazy quotient rows computed
   `domain.at(bitReverseIndex(position, n))` per row via
   `CirclePointIndex.toPoint()` (~7.5 circle-group adds per row at log 15).
   Consecutive positions flip the c trailing ones of p-1, so in n-bit
   bit-reversed index space the delta is `2^(n-c) + 2^(n-1-c) - 2^n
   (mod 2^n)`; each row costs one group addition with a precomputed point
   delta plus sign-branch conjugation (CPU analogue of the landed Metal
   linear domain walk).

2. **Packed lane finalize.** The batched tile path repacked four M31
   numerator planes into a scalar `QM31` per row. `finalizeGroupVec4`
   evaluates the linear term and the denominator-inverse multiply with
   Karatsuba CM31 over Vec4 rows — the same exact field operations as
   scalar `finalizeRowQuotients` (S1: 30.35 -> 15.49 ns/op).

3. **Stack-chunked batch inversion.** Domains below 8192 lifting rows
   (including the scored small class) ran one full CM31 inversion per row
   in `beginRow` (~312 ns/row, ~80% of small's quotient compute). The
   scalar row paths now prepare 32-row chunks on the stack and invert them
   with the existing Montgomery batch inversion (one inversion + ~3 muls
   per element). Zero added heap: peak RSS matches the per-row path.

## Changes

New `src/prover/pcs/quotient_domain_walk.zig` provides
`BitReversedCosetWalk`; its call sites are the four hot point generators
in `quotient_tile_executor.zig` and `quotient_row_executor.zig`.
`quotient_tile_executor.executeBatched` also finalizes VEC_WIDTH rows per
pass via `finalizeGroupVec4` (scalar remainder tail). The scalar row
paths (`executeStreamingScalar`, `executeMaterializedScalar`) are
restructured into 32-row stack chunks with batch inversion and quad-lane
finalize (`finalizeQuadVec4`); `batch_count > 16` falls back to the
original per-row loop. Conformance tests: walks vs direct
`domain.at(bitReverseIndex)` at six log sizes; packed finalize vs scalar
`finalizeRowQuotients` at batch counts 1/2/3 in both executors.

## Evidence

- S1 isolates: walk 25.54 -> 4.45 ns/op (359.5 -> 56.1 instr/op); packed
  finalize 30.35 -> 15.49 ns/op (149.3 -> 63.9 instr/op); chained
  accumulators byte-identical for both. In-repo batched-vs-scalar
  equivalence tests cover the inversion; the walk carries conformance
  tests at six log sizes; the finalize carries packed-vs-scalar tests at
  batch counts 1/2/3.
- Maintainer's judge measurement of the stack-chunk alone on current main
  (closed draft #61): small R=0.9769 [0.9599, 0.9966] — a real ~2.3% that
  this compound builds on rather than resubmits alone.
- Paired S3 on tip `bc8c167` (this compound): see table below.
- Proof digests unchanged: small `91741aec...bea5700`, wide
  `57a7d291...0f3374`, deep `d63a2c92...b69dbaf`.

## Results

Paired S3 verdicts against the current tip (`bc8c167`). Every reported run
passed G1-G3 with byte-identical cross-arm digests; resource vectors
including RSS within budgets unless noted:

| compound | class | rounds | ratio | 95% CI | theta | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| walk+finalize+chunk | small | 15 | 0.9499 | [0.8745, 0.9772] | 0.0373 | not significant |
| walk+finalize+chunk | wide | 15 | 1.0057 | [0.9506, 1.0601] | 0.0293 | not significant |
| walk+finalize+chunk | deep | 15 | 0.9710 | [0.9538, 0.9885] | 0.0183 | not significant |
| + quad finalize (v3) | small | 15 | 0.9772 | [0.9543, 1.0036] | 0.0373 | not significant |

Reference points on quieter runs and the locked judge host: the
stack-chunk alone measured small 0.8771 [0.7904, 0.9419] locally (pre-
deferred-tree main) and 0.9769 [0.9599, 0.9966] on the maintainer's judge
(current main); walk+finalize measured deep 0.9611 [0.9149, 0.9884] on an
earlier tip. Evening host load (avg >20) widens every local CI; the locked
judge re-run decides.

## Caveats

- Mechanism 3 only affects sub-8192-row domains (small class and 2^11-2^12
  guards); wide/deep already use the heap-batched tile path.
- Local host A/A dispersion is high in the evening measurement windows; all
  runs are reported, including noise-shaped guard trips.
