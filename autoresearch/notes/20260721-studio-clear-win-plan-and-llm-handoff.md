---
title: Studio clear-win plan and LLM handoff
author: welttowelt
created_utc: 2026-07-21T07:15:49Z
---

# Mission

Produce a clear `core_cpu` leaderboard win for `stwo-zig`, starting with the
`deep` class. A source merge, a strong microbenchmark, or a favorable paired
ratio is not sufficient by itself.

The operational success bar is all three of:

1. our landing commit receives a ledger row with `outcome=promoted`;
2. that row becomes the current class head;
3. the public leaderboard/API displays that head.

Record `verdict_kind=claimed|judged` separately. The repository describes a
signed judged verdict as the formal promotion record; do not blur that status
with a claimed public row.

# Live snapshot

Checked at 2026-07-21T07:15:49Z. These values are a dated snapshot and must be
refreshed before any edit, decisive benchmark, package, or merge.

- Upstream `main`: `86f9aa160e9ebd7ea2c0d12955898634d675be1c`.
- The public frontier endpoints return HTTP 200 for all three CPU classes.
- `remote-frontier` is usable at this snapshot.
- `stwo-perf sync` is still broken on current main: its CLI call supplies only
  class to a frontier view that requires board and class. Do not use it until
  issue #21 is demonstrably fixed.
- All current CPU heads are claimed promotions from
  `32ee7f2bbb10258c1bf8813073815bbc39e768c8`:

| class | live head | A/A dispersion | official CI-high ceiling | buffered median target | buffered CI-high target |
| --- | ---: | ---: | ---: | ---: | ---: |
| small | 1.539584 ms | 0.018654 | <0.962692 | <=1.508792 ms | <=0.9577 |
| wide | 10.752041 ms | 0.014645 | <0.970710 | <=10.537000 ms | <=0.9657 |
| deep | 7.456167 ms | 0.009139 | <0.981722 | <=7.307044 ms | <=0.9750 |

The primary internal deep target is point ratio `<=0.960`, CI high `<=0.975`,
and candidate median `<=0.98 * live_head`. Recompute the absolute target from
the live head rather than copying 7.307044 ms into a future verdict.

# Why the previous attempt missed

The earlier merged point-generation attempt showed a real paired improvement,
`R=0.909664 [0.875900, 0.934007]`, but its candidate median was 8.738417 ms.
The already-live head was 7.456167 ms. It therefore lost the absolute-head gate
and produced a rejected row. Never submit against a stale predecessor or call a
source-only merge a win.

# Preserved candidate source

Both archive branches are reference material based on
`c7a214981b032a07d658d8cd37795a4e34035125`. Never benchmark them directly and
never base the submission branch on them. Port each mechanism onto a fresh
current-main worktree.

## Primary: point successor

- Branch: `archive/points-successor-c7a2149-20260721`
- Commit: `bf0a892f84d138abac3a6c511e1cd60a9fd272c3`
- Source-only diff: two quotient executor files, 242 insertions and 18
  deletions.
- Proven S1 result: wall ratio 0.08784 with CI [0.07702, 0.09830], instruction
  ratio 0.07876, cycle ratio 0.07529.
- Proof and focused test closures were exact in the old worktree.
- It is not submission-ready: the row executor reaches 896 lines, above the
  850-line source-conformance ceiling.

Mandatory port shape:

- Move reusable sequence logic and differential tests into
  `src/prover/pcs/bit_reversed_domain_points.zig`.
- Add an internal `Materializer` that stores the domain, pair log size, and a
  bounded carry-delta table.
- Interface:
  - `Materializer.init(domain, log_size)!Materializer`
  - `Materializer.fill(out, start)!void`
- Initialize one materializer per materialized, streaming, or tile work item
  and reuse it across chunks.
- Preserve scalar fallbacks.
- Differential tests cover logs 1-30, every carry transition, partial chunks,
  bounds and overflow, canonical and noncanonical domains, shifted domains,
  and negative-step domains.

## Conditional fallback: FRI line twiddles

- Branch: `archive/fri-twiddles-c7a2149-20260721`
- Commit: `a518953008828bc07e2b5fba9bb8bdb19eef7121`
- Source-only diff: eight files, 588 insertions and 177 deletions.
- Proven S1 result: wall ratio 0.643187 with CI [0.637543, 0.675693],
  instruction ratio 0.700823, cycle ratio 0.640824.
- Estimated standalone whole-proof ceiling is only about 0.10 ms. Do not submit
  it alone.
- Current main overlaps its `src/prover/fri.zig` changes and contains newer
  Metal dispatch. Port manually; never apply the old file wholesale.

Stack FRI twiddle reuse only when point successor passes the official gate but
narrowly misses the buffered target. Keep it only when a points-versus-stacked
ablation shows at least 0.08 ms marginal S2 saving, production logs through 15
are covered, and Metal dispatch, fallbacks, retained memory, proof bytes, and
slice lifetimes remain unchanged.

# Studio operating contract

Use the Studio M4 Max as the sole host for promotion-grade absolute evidence.
Local and Runpod systems may reject hypotheses, run correctness matrices, and
collect directional profiles, but their absolute milliseconds do not compare
to the Apple leaderboard.

Canonical locations on Studio:

- repository: `$HOME/stwo-zig`;
- append-only evidence and runner state: `$HOME/stwo-evidence/clear-win`;
- fresh SHA-named baseline and candidate worktrees beside the canonical clone.

Required toolchain:

- Python 3.11 or newer;
- Zig 0.15.2 ARM macOS archive, SHA-256
  `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`;
- Rust `nightly-2025-07-14`, minimal profile;
- session PATH containing the Zig bin directory and `$HOME/stwo-zig/autoresearch/cli`.

Do not persist credentials in the repo, evidence tree, shell history, or
transcript. Perform GitHub/device authentication interactively off-transcript.
Never record API keys, GitHub tokens, SSH material, environment dumps, cookies,
or raw authentication output.

# Exact restart order

1. Read every applicable `AGENTS.md`, current-main `autoresearch/TASK.md`, the
   current manifest, prior notes/submissions, and the repo skills for algorithm
   matching, Zig profiling, and submission transcripts.
2. Fetch upstream and the three fork handoff/archive branches.
3. Compare current local `HEAD`, `git ls-remote origin refs/heads/main`, the
   committed ledger, `remote-frontier`, and all three public frontier endpoints.
   Resolve disagreement before editing.
4. Install and verify the pinned toolchain. Configure only the public API URL;
   keep secrets out of logs.
5. Create the evidence root and begin a sanitized reasoning transcript before
   implementation.
6. Create fresh baseline and candidate worktrees from the same current upstream
   commit. Never reuse the archived c7 worktrees.
7. Port only the point-successor mechanism, perform the mandatory source split,
   and commit the candidate before final timing.

# Measurement funnel

## Host admission

- Studio on AC power with no competing build, benchmark, or agent job.
- Default worker selection; unset `STWO_ZIG_WORKERS`.
- `load1 <= 4` and nominal thermal/performance state.
- Run deep A/A before the candidate and again immediately before final evidence.
- Require `abs(aa_r - 1) <= 0.009139` and CI half-width `<=0.009139`.
- Retry a failed quiet window at most twice, then pause rather than manufacture
  a result from noise.

## Point-successor admission

1. Run 15 paired ABBA S1 rounds against current-main scalar generation.
2. Continue only if wall CI excludes 1.0 and wall, instruction, and cycle ratios
   are each `<=0.20`.
3. Profile current main and candidate. Require projected deep improvement of at
   least 3%.
4. Run source conformance, `git diff --check`, formatting checks without
   uncontrolled rewrites, focused core/prover/native closures, proof-byte
   parity for small/wide/deep, and the pinned Rust oracle.
5. Run preliminary Studio deep S3 without full guards. Advance only if point
   ratio `<=0.960`, CI high `<=0.975`, and median `<=0.98 * live_head`.
6. If this clears, stop adding mechanisms and enter final validation.
7. If the official gate passes but only the buffered target misses, test the
   FRI stack under the ablation rules above.
8. If point successor fails the official gate in two clean Studio attempts,
   pivot structurally to cached canonical circle-y inverses. Require S1 saving
   of at least 0.35 ms or projected deep gain of at least 4%, retained storage
   `<=64 KiB` at log 14, and whole-run RSS ratio `<=1.05`.

# Final acceptance

Immediately before final evidence, refresh upstream, API, ledger head, epoch,
and thresholds. If main or the head moved, recreate/rebase both worktrees and
discard the earlier final verdict.

Commit the candidate before final benchmarking and make no source edits after
the first final run. Run two independent deep S3 evaluations with all guards;
use the worse result. Both must satisfy:

- G1-G5 and all 12 AIR guards pass;
- proof bytes are identical across arms in every round;
- the pinned Rust oracle accepts the candidate;
- point ratio `<=0.960`;
- CI high `<=0.975` and below the refreshed official threshold;
- candidate median `<=0.98 * refreshed_live_head`;
- request ratio, RSS ratio, and every guard CI high `<=1.05`;
- targeted anchor ratio `<=1.02`.

Profile every affected class. Run official S3 evidence for each class that
moves and attach each independently promotable verdict so the suite receives
full credit.

An independent verifier must recompute the Hodges-Lehmann ratio and deterministic
bootstrap interval from raw evidence, hash all reports, confirm exact frontier
ancestry and editable paths, inspect the source line limit and Metal behavior,
and require `promotion.decide_outcome(verdict, live_head) == promoted`.

# Submission and closure

Use the fork PR route after final evidence. Package the structured note, final
reports, hashes, and sanitized transcripts with `stwo-perf submit`; do not hand
assemble a verdict or bypass its secret scan.

Recheck upstream and the live head immediately before opening the PR and again
before merge. If a new head removes the absolute buffer, hold and rerun.

After merge, verify:

1. the ledger row names our landing commit and says `outcome=promoted`;
2. the row is the current class head;
3. the public leaderboard/API shows it;
4. claimed versus judged status is stated explicitly.

# Bounded research rules

- One iteration lasts at most 30 minutes or 15 agent rounds.
- Every iteration produces a verified finding, metric improvement, falsified
  hypothesis, or concrete blocker.
- Two stale iterations force a structural pivot.
- Four clean S3 misses stop autonomous search and produce a report rather than
  another patch pile.
- Keep raw evidence and mutable JSON/JSONL state outside the tracked worktree.
- Attach only sanitized transcripts through the eventual submission package.

# Paste-ready kickoff message

```text
Resume the stwo-zig Studio clear-win effort.

First read every applicable AGENTS.md, current autoresearch/TASK.md, the current
manifest, and the durable note on fork branch
handoff/studio-clear-win-20260721:

autoresearch/notes/20260721-studio-clear-win-plan-and-llm-handoff.md

Fetch these reference-only source archives:

- archive/points-successor-c7a2149-20260721 at bf0a892f84d138abac3a6c511e1cd60a9fd272c3
- archive/fri-twiddles-c7a2149-20260721 at a518953008828bc07e2b5fba9bb8bdb19eef7121

Do not base a candidate on the handoff or archive branches. Create fresh
baseline and candidate worktrees from current upstream main and port the point
successor mechanism. Treat every SHA, head median, API result, and threshold in
the note as a dated snapshot; refresh them before editing or timing.

Use the Studio as the only absolute benchmark host. Do not use stwo-perf sync
until issue #21 is confirmed fixed. Start with read-only preflight and report
current main, API/frontier agreement, live class heads, toolchain versions,
Studio load/thermal state, and deep A/A admission before modifying source.

The objective is not merely a merge. Finish only when our landing commit has a
promoted ledger row, is the current public class head, and appears on the
leaderboard. Record claimed and judged status separately. Do not expose
credentials, skip full guards, or submit without both independent final runs
and the separate verifier pass.
```
