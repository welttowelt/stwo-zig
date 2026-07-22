# Bit-reversed coset walk and packed finalize for lazy quotient evaluation

## Model and harness

Model: Kimi (Moonshot AI) via kimi-code CLI, working as lane KIMI APOLLO in
the local three-agent mailbox (CLAUDE-MERSENNE research boss, CODEX ANVIL
leaf lane). Harness: repo-resident `stwo-perf` at canonical tip
`2ab16c66a306`, Zig 0.15.2 and Python 3.12.12, ReleaseFast on an Apple
M4 Pro arm64 macOS host. The paired predecessor is the unchanged
current-main checkout. A reasoning-first, sanitized session transcript is
attached as `transcripts/session-01.md`.

## Hypothesis

Lazy quotient evaluation is a row pipeline: per row it generates the
bit-reversed domain point, builds batch denominators, accumulates column
contributions into numerator planes, and finalizes one quotient. Two parts
of that pipeline carry avoidable instruction counts, and on a saturated
out-of-order pipeline removing instructions anywhere lifts the whole loop:

1. **Point generation.** Every row computed
   `domain.at(bitReverseIndex(position, n))` via
   `CirclePointIndex.toPoint()`: one circle-group addition per set index
   bit (~7.5 per row at log 15). Consecutive positions p-1 -> p flip the c
   trailing ones of p-1 (c = ctz(~(p-1))), so in n-bit bit-reversed index
   space the index delta is `2^(n-c) + 2^(n-1-c) - 2^n (mod 2^n)`, and each
   row costs exactly ONE group addition with a precomputed point delta plus
   a sign-branch conjugation (CPU analogue of the landed Metal linear
   quotient domain walk).

2. **Finalize.** The batched path repacked four M31 numerator planes into a
   scalar `QM31` per row, then evaluated the linear term and multiplied by
   the denominator inverse with scalar QM31/CM31 operations. Keeping
   numerators in coordinate planes and finalizing VEC_WIDTH rows per pass
   with Karatsuba CM31 multiplies over Vec4 lanes removes the repack and
   widens every arithmetic step.

Both mechanisms use the identical field operations (the circle group law;
the same Karatsuba formula), so every emitted point and quotient is
byte-identical to the code they replace.

## Changes

New `src/prover/pcs/quotient_domain_walk.zig` provides
`BitReversedCosetWalk`: init seeds the first point directly (any span
start) and precomputes one point delta per possible trailing-ones count;
`next()` emits the current point and advances with one group add and a
conditional conjugation. Four hot call sites now walk instead of
recomputing: `executeBatched` and `executeScalar` in
`quotient_tile_executor.zig`, and `executeMaterialized`,
`executeMaterializedScalar`, `executeStreaming`, and
`executeStreamingScalar` in `quotient_row_executor.zig`.

`quotient_tile_executor.executeBatched` also finalizes VEC_WIDTH rows per
pass via the new `finalizeGroupVec4` (plane-native; scalar remainder tail
for odd row counts). `executeScalar` and the row executors keep their
scalar finalize.

Conformance tests: walks are byte-identical to direct
`domain.at(bitReverseIndex)` at log sizes {1,2,3,4,5,11,15} over full
domains and arbitrary non-aligned starts; `finalizeGroupVec4` matches
scalar `finalizeRowQuotients` exactly at batch counts 1/2/3.

## S1 evidence (stwo-prof isolates, live repo imports)

| mechanism | arm A (current) | arm B (candidate) | equivalence |
| --- | --- | --- | --- |
| point walk | 25.54 ns/op, 359.5 instr/op | 4.45 ns/op, 56.1 instr/op | chained ACC identical over 2000x32768 pts |
| packed finalize | 30.35 ns/op, 149.3 instr/op | 15.49 ns/op, 63.9 instr/op | chained ACC identical |

Falsified companions (kept out): batch-fused numerator accumulation
(ALU-port saturated at IPC ~4.8, cycles tied), 4-chain parallel-scan batch
inversion (-12% cycles on a ~2% slice), packed denominator values (34.1 ->
30.9 instr/op, cycles within noise).

## Results

Paired S3 verdicts against predecessor `8e58d7015e28` — which contains
every promoted change at submission time (the only later merge, PR #46, was
recorded neutral and no ledger frontier row moved). 13/13 regression guards
green, G1-G5 pass on every tabled class:

| class | mechanism | rounds | ratio | 95% CI | theta | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| small | walk (finalize n/a: row path) | 15 | 0.9872 | [0.9694, 1.0065] | 0.0373 | confirmed-neutral |
| wide | walk | 7 | 0.9871 | [0.9778, 0.9992] | 0.0293 | confirmed-neutral |
| deep | walk | 15 | 0.9870 | [0.9636, 1.0067] | 0.0183 | not significant |
| deep | walk + packed finalize | 15 | 0.9611 | [0.9149, 0.9884] | 0.0183 | not significant |
| wide | walk + packed finalize | 15 | 0.9874 | [0.9710, 1.0043] | 0.0293 | confirmed-neutral |

Replication runs (same candidates, all G1-G3 green, byte-identical
digests): walk deep 0.9904 [0.9775, 1.0022] and 0.9766 [0.9541, 0.9955];
compound batch on tip `2ab16c66a306` (ambient host noise; two regression
guards tripped with even medians — treated as noise per project ops
guidance). Central deep effect is -3.9% for the compound; the local host's
A/A dispersion, not the effect size, keeps the CI from clearing the class
theta. The judged re-run on the locked host decides.

Proof digests remained the fixed workload values: small `91741aec...bea5700`,
wide `57a7d291...0f3374`, deep `d63a2c92...b69dbaf`.

## Caveats

- Small-class quotient execution uses the row-executor (non-batched) path;
  it receives the walk but not the packed finalize.
- Deep-class CIs from this shared host are wide; two deep compound runs
  agree on a ~2-4% central effect with CIs spanning the gate.
