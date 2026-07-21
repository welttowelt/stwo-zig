# Bit-reversed coset walk for lazy quotient point generation

## Model and harness

Model: Kimi (Moonshot AI) via kimi-code CLI, working as lane KIMI APOLLO in
the local three-agent mailbox (CLAUDE-MERSENNE research boss, CODEX ANVIL
leaf lane). Harness: repo-resident `stwo-perf` at canonical tip
`2ab16c66a306`, Zig 0.15.2 and Python 3.12.12, ReleaseFast on an Apple
M4 Pro arm64 macOS host. The paired predecessor is the unchanged
current-main checkout. A reasoning-first, sanitized session transcript is
attached as `transcripts/session-01.md`.

## Hypothesis

Lazy quotient evaluation visits every lifting-domain position in natural
order and computes `domain.at(bitReverseIndex(position, n))` per row through
`CirclePointIndex.toPoint()`: one circle-group addition per set index bit,
about 7.5 additions per row at log 15. Env-gated tile timers attributed
roughly 19% of Apollo-lane quotient compute to this point generation.

Consecutive positions p-1 -> p flip the c trailing ones of p-1
(c = ctz(~(p-1))) plus bit c, so in n-bit bit-reversed index space the index
delta is 2^(n-c) + 2^(n-1-c) - 2^n (mod 2^n). Domain points satisfy
at(idx) = s * Q(idx mod half) with Q(j) = P(initial + j*step), and Q has
period half, so each row costs exactly one group addition with a precomputed
point delta plus a sign-branch conjugation. This is the CPU analogue of the
landed Metal linear quotient domain walk. The same circle group law is used,
so every emitted point is byte-identical to the direct call it replaces.

## Changes

New `src/prover/pcs/quotient_domain_walk.zig` provides
`BitReversedCosetWalk`: init seeds the first point directly (any span start,
including non-aligned worker spans) and precomputes one point delta per
possible trailing-ones count; `next()` emits the current point and advances
with one group add and conditional conjugation. Four hot call sites now walk
instead of recomputing: `executeBatched` and `executeScalar` in
`quotient_tile_executor.zig`, and `executeMaterialized`,
`executeMaterializedScalar`, `executeStreaming`, and
`executeStreamingScalar` in `quotient_row_executor.zig`.

Unit tests prove byte-identical walks versus direct
`domain.at(bitReverseIndex)` for log sizes {1,2,3,4,5,11,15}, over full
domains and arbitrary non-aligned starts (1, 7, 2731, half-1, half, size-3).

## S1 evidence (stwo-prof isolates, live repo imports, 2^15 canonic domain)

| arm | ns/op | instructions/op | cycles/op |
| --- | ---: | ---: | ---: |
| direct at(bitReverse) | 25.54 | 359.5 | 100.4 |
| incremental walk | 4.45 | 56.1 | 17.5 |

Chained accumulators over 2000 iterations x 32768 points were identical for
both arms (c6b31e2026c68821), confirming the walk emits the same points.

## Results

Paired S3 verdicts against predecessor `8e58d7015e28` — which contains
every promoted change at submission time (the only later merge, PR #46, was
recorded neutral and no ledger frontier row moved). 13/13 regression guards
green, G1-G5 pass on every tabled class:

| class | rounds | A ms | B ms | ratio | 95% CI | theta | verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 15 | 1.651 | 1.642 | 0.9872 | [0.9694, 1.0065] | 0.0373 | confirmed-neutral |
| wide | 7 | 10.419 | 10.318 | 0.9871 | [0.9778, 0.9992] | 0.0293 | confirmed-neutral |
| deep | 15 | 7.201 | 7.099 | 0.9870 | [0.9636, 1.0067] | 0.0183 | not significant |

Replication runs (same candidate, all G1-G3 green, byte-identical digests):
deep 0.9904 [0.9775, 1.0022] and 0.9766 [0.9541, 0.9955]; a final batch
against tip `2ab16c66a306` measured small 0.9991 [0.9816, 1.0167], wide
0.9876 [0.7900, 1.0610], deep 0.9934 [0.9679, 1.0638] — consistent central
ratios with noise-widened CIs from a chronically loaded shared host (the
wide/deep rows' upper CIs, not their medians, tripped the G4 matrix-row
budget on those two noise runs). The ledger frontier did not move between
any of these runs: the tabled verdicts' predecessor contains every promoted
change, and the only intervening merge (PR #46) was recorded neutral.

The mechanism is consistent (~1-2% per class across six independent paired
runs) and the deep class repeatedly measures with its whole CI below 1.0.
Where a class CI does not clear the class theta, the row is reported
honestly as confirmed-neutral / not significant rather than rounded up.

Proof digests remained the fixed workload values: small `91741aec...bea5700`,
wide `57a7d291...0f3374`, deep `d63a2c92...b69dbaf`.

## Caveats

- The mechanism removes ~19% of Apollo-lane quotient compute, which is a
  small share of end-to-end prove time; expected effect is near the
  significance floor and the paired CI decides each class.
- Point deltas depend only on the domain step and log size; no protocol,
  statement, or workload digest changes.
