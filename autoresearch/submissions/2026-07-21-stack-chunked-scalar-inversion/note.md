# Stack-chunked batch inversion for scalar quotient rows

## Model and harness

Model: Kimi (Moonshot AI) via kimi-code CLI, working as lane KIMI APOLLO in
the local three-agent mailbox (CLAUDE-MERSENNE research boss, CODEX ANVIL
leaf lane). Harness: repo-resident `stwo-perf` at canonical tip `4ee3b64`,
Zig 0.15.2 and Python 3.12.12, ReleaseFast on an Apple M4 Pro arm64 macOS
host. The paired predecessor is the unchanged current-main checkout. A
reasoning-first, sanitized session transcript is attached as
`transcripts/session-01.md`.

## Hypothesis

Domains below `MIN_BATCHED_DOMAIN_ROWS` (8192) — including the scored small
class (2^11 lifting rows) — evaluate lazy quotients through the scalar row
paths, which call `RowQuotientWorkspace.beginRow` once per row. Each call
inverts that row's batch denominators alone: one full CM31 inversion per
row per batch. Direct instrumentation attributed ~312 ns/row to that call,
about 80% of the small class's quotient compute.

The same arithmetic amortizes across rows: a Montgomery batch inversion
over 32 rows costs one inversion plus about three CM31 multiplies per
element. Doing this in stack-resident chunks keeps the peak RSS identical
to the per-row path — no heap scratch is added — which earlier blocked a
heap-based variant of the same idea under the new v7 resource gate.

## Changes

`executeStreamingScalar` and `executeMaterializedScalar` in
`src/prover/pcs/quotient_row_executor.zig` now process rows in 32-row
chunks: the chunk's domain points are generated, their denominators are
prepared and batch-inverted on the stack through the existing public
`prepareDenominatorInversesForRows`, and each row is then finalized with
the chunk's inverses. Numerator accumulation and tile emission are
unchanged. A `batch_count > 16` fallback preserves the original per-row
loop for exotic configurations. Every arithmetic step is the same exact
field operation, so outputs are byte-identical to the per-row path; the
in-repo batched-versus-scalar equivalence tests cover the batch inversion
itself.

## Results

Paired S3 verdict against the current tip (`4ee3b64`):

| class | rounds | A ms | B ms | ratio | 95% CI | theta | verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 15 | 1.665 | 1.479 | 0.8771 | [0.7904, 0.9419] | 0.0373 | significant improvement |

G1 conformance (every timed sample verified, cross-arm digests
byte-identical, pinned Rust oracle) and G2/G3 pass. Resource vectors,
including peak RSS, are within named budgets — the mechanism adds no heap
memory. Three regression guards on unrelated workloads (`guard_plonk_14`,
`guard_sm_16`, `guard_wf_10x8`) exceeded their timing budgets in this
ambient-evening run and are attributed to shared-host noise (their medians
were even across arms); they will be re-measured in a quiet window and on
the locked judge host.

Proof digests remained the fixed workload values: small `91741aec...bea5700`,
wide `57a7d291...0f3374`, deep `d63a2c92...b69dbaf`.

## Caveats

- The effect concentrates on domains below 8192 lifting rows (the scored
  small class and 2^11-2^12 guard workloads); wide and deep already use
  the heap-batched tile path and are untouched by construction.
- The predecessor per-row and candidate chunked paths were also compared
  directly at the stage level before pairing: quotient stage 0.589 ms ->
  0.518 ms on small under identical conditions.
