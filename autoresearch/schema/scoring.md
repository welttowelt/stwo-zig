# Scoring boards (v1)

What "the score" means for stwo-zig autoresearch. Seven boards, one promotion
currency. A board defines a basket (which workloads), a lane (which backend
contract), a protocol (how it may be measured), and a display score. The
promotion math never changes per board: a submission is judged by the paired
ratio R of playbook F.1 over its declared basket; boards are baskets, not new
reward functions.

Inherited constraints (normative, from the performance program):

- no single MHz across AIRs — every rate names its native unit;
- cross-workload aggregation is geometric-mean time ratios, never averaged MHz;
- headline numbers come only from `verified_unprofiled` runs;
- backend identity is explicit; fallback counts are part of the result;
- timing scopes are named (prove vs request vs process vs queue).

## Board 1 — Core (the headline)

The "average across sizes" board, constructed so averaging is legitimate.

- **Basket:** the committed native matrix (Wide Fibonacci, XOR, Plonk, state
  machine, Blake, Poseidon at their two checked-in sizes — the 12 rows of the
  current matrix protocol), per lane.
- **Score:** `CoreIndex = geomean_i(prove_i / anchor_prove_i)` over all rows,
  against the frozen pre-optimization anchor. 1.00 = anchor; display as the
  speedup `x(1/CoreIndex)`. Sub-indexes per workload class (small/wide/deep)
  use the same construction over the class subset.
- **Why not an average of scores:** a mean of MHz overweights large rows and
  mixes native units; a mean of times is unit-nonsense across AIRs. The ratio
  geomean weights every row equally, is scale-free, and matches the existing
  2%/5% ratio gates.
- **Rules:** one lane per index (no mixing lanes across rows); the site
  headline is the best lane's CoreIndex with the lane named. Anchors are per
  row, frozen once (manifest `anchor_prove_ms` generalizes to per-row values
  at freeze time); a new anchor is a new epoch, never a comparison.

## Board 2 — Kernels (diagnostic, never promotable)

CPU optimization at instruction/kernel scope: S0/S1 of the scope ladder.

- **Basket:** the named hot kernels with pinned inputs and golden vectors:
  four-lane Blake2s compress (parents/s), M31/QM31 batch inversion (elem/s),
  packed FFT butterfly layer (cycles/butterfly), quotient tile execution
  (rows/s), FRI fold2/fold3 (elem/s).
- **Score:** primary observable is **counters, not wall time** — cycles and
  instructions per element (near-zero dispersion), plus achieved bytes/s as a
  **percentage of the measured host roofline** (the STREAM-triad and ALU
  ceilings of F.8 item 1). "% of roofline" is the honest "how much is left"
  number; ns/op is secondary and only with QoS pinned.
- **Hard rule:** kernel results never enter the promotions ledger and never
  aggregate into any other board. The acceptance floor is S3: a kernel 2x
  that moves no proof is recorded and closed (existing precedent). This board
  exists to generate hypotheses and to catch regressions, not to rank
  solvers — scoring it for promotion would invite Amdahl-blind gaming.

## Board 3 — CPU

- **Lane:** `cpu_native`. Basket and score identical to Core, restricted to
  the CPU lane; per-row native MHz (unit named) shown as drill-down.
- **Gate:** zero Metal dispatches in telemetry (trivially true), standard
  G1-G5.

## Board 4 — Metal (resident; zero fallback)

- **Lane:** `metal_resident` — the reserved name. **Eligibility, not just
  scoring:** a row qualifies only when telemetry proves real device dispatch
  AND `cpu_fallbacks == 0` for proving-stage work (host transcript
  observations and orchestration excluded by the architecture contract), and
  for the production class, AOT-admitted pipelines with no source JIT.
- **Score:** same construction as Board 3 once rows qualify. **The board is
  empty today** — the current metal lane performs host Merkle fallbacks and
  therefore belongs to Board 5. Until first entry, the board displays
  progress metrics instead of scores: GPU share of prove time (currently
  13-14%) and fallback count per proof (currently 16 -> 0), neither of which
  is a rankable score.
- **Why strict:** any laxer definition collapses this board into Board 5 and
  destroys the meaning of "Metal beat CPU".

## Board 5 — Hybrid (CPU+Metal)

- **Lane:** `metal_hybrid`, today's Metal lane: best-effort device scheduling
  with counted CPU fallbacks.
- **Score:** same construction as Board 3. **Mandatory context columns:**
  fallback count and GPU-time share render beside every hybrid score so a
  hybrid number can never masquerade as Board 4.
- The site headline "best score" per row = min over Boards 3/4/5 with the
  lane label attached.

## Board 6 — Heavy

Production-shaped and large-geometry work; separate because the measurement
protocol differs, not because the math does.

- **Baskets:** (a) large native geometries (wide rows at log18+, beyond the
  normal committed-cell guard) — cooled, three-sample bounded protocol;
  (b) Cairo programs (the nine-program matrix, Fib tiers first) and SN PIE
  blocks — absolute wall seconds per named workload; (c) the streaming queue
  (S5): sustained proofs/s, p50/p95 latency, retained bytes over the 10- and
  100-block gates.
- **Score:** per-workload absolute time (and proofs/s for streams) with
  **peak RSS and energy as first-class dimensions**, not tie-breakers — the
  17-18 GB Cairo RSS numbers are exactly what this board must keep visible.
  Ratio-to-anchor indexes appear only after a heavy anchor is frozen from the
  first controlled run of each basket.
- **Protocol:** judged heavy runs are scheduled on the labelled, thermally
  controlled machine (conformance-goal rule); they are never casually
  re-runnable, so heavy ledger rows are rarer and marked `heavy_*`.

## Board 7 — RISC-V

- **Lane:** the pinned Stark-V RV32IM adapter, measured in executed
  instructions and scored only against RISC-V workloads and anchors.
- **Isolation:** this board owns one workload group. Its workloads, A/A
  dispersion, anchor budgets, frontier, and promotion HEAD never pool with a
  native board, even when both use the same `small`/`wide`/`deep` class names.
- **Release condition:** the group remains disabled until the AIR, public I/O
  binding, oracle parity, and CLI adapter release gates are complete. Disabled
  means no measurements and no promotions; it never means a silent skip or a
  fabricated score.

## Ledger mapping

`promotions.tsv` carries a `board` column. A submission's declared objective
is `(board, workload_class, dimension)`. The board set is `core_cpu |
core_hybrid | core_metal | heavy_native | heavy_cairo | stream | riscv`.
Kernel results stay out of the ledger by rule; they live in the microharness
diagnostics reports.

## What is deliberately not scored

- No blended CPU+Metal index within one basket (breaks backend identity).
- No kernel aggregate feeding Core (double counting + Amdahl gaming).
- No cross-epoch or cross-anchor comparisons, ever.
- No single-number site score without its lane and basket named beside it.
