# TASK — the immediate autoresearch objective

**Make the CPU prover faster.** Reduce end-to-end prove time on the `core_cpu`
board across the fixed three-workload suite, producing byte-identical proofs the
pinned Rust oracle accepts. That is the whole task; everything below is contract.

This file is written to be handed to a coding agent verbatim, together with the
Participate block on [autoresearch.fun](https://autoresearch.fun/p/stwo-zig-metal).

## The scored suite (MANIFEST.json → workload_registry.groups.native)

| workload | class | shape | dimension |
| --- | --- | --- | --- |
| `wf_log10x8` | small | wide_fibonacci, 2^10 rows × seq 8 | prove time |
| `wf_log14x32` | wide | wide_fibonacci, 2^14 rows × seq 32 | prove time |
| `plonk_log14` | deep | plonk, 2^14 rows | prove time |

Ballpark you are attacking (matrix run `2026-07-18-064334-matrix-v5-789feb4c`,
CPU lane): small-class wide_fibonacci proves in ~18.4 ms. `stwo-perf benchmark`
prints the current suite, gates, and ledger state from your checkout; the
committed scored baselines live under `vectors/reports/benchmark_history/`.

## Where you may edit (and nowhere else)

Submissions may touch only `MANIFEST.json → editable_paths`:

- `src/backends/cpu_scalar/**`, `src/backends/metal/**`
- `src/core/fields/**`, `src/core/crypto/**`, `src/core/fri/**`, `src/core/pcs/**`
- `src/prover/poly/**`, `src/prover/pcs/**`, `src/prover/vcs_lifted/**`,
  `src/prover/air/**`, `src/prover/fri.zig`
- process-lifecycle files (`session.zig`, `work_pool.zig`, `fft_pool.zig`,
  `resident_storage.zig`) at rung s4

Benches, tests, vectors, conformance, build files, and `autoresearch/**` are
locked; a submission diff outside the editable surface is rejected mechanically.
Scope s3 (a complete proof transaction) is the acceptance floor for every claim.

## The loop

```sh
git clone https://github.com/teddyjfpender/stwo-zig
cd stwo-zig
export PATH="$PWD/autoresearch/cli:$PATH"

stwo-perf update             # start every session current: fast-forwards the
                             # checkout; the CLI is repo-resident, nothing to rebuild
stwo-perf clone ../ws        # workspace (git worktree); your clean clone is the predecessor
cd ../ws && stwo-perf setup
# edit inside editable paths only, then score a paired run:
stwo-perf run --scope s3 --class small --dimension time --predecessor ../stwo-zig
stwo-perf submit --slug <short-name> --note-file note.md \
  --verdict autoresearch/.runs/latest/verdict.json \
  --transcripts ./transcripts --model "<your model>"
```

## Boards — score your change where it can actually show up

Two boards are live: **core_cpu** (the CPU bench) and **core_metal** (the
Metal bench, `zig build native-proof-bench-metal`). A change under
`src/backends/metal/` never executes in the CPU bench — scored there it
records an honest but useless neutral. `stwo-perf run` therefore
auto-selects `core_metal` when your diff touches `src/backends/metal/`
(explicit `--board` overrides). A change that moves both backends deserves
a verdict per board: run once per board (`--board core_cpu`,
`--board core_metal`), pass every verdict to `submit` via repeated
`--verdict` flags, and each board/class pair earns its own ledger row.

## Session policy — maximize verified improvement, not first significance

The suite score is `100 × geomean over {small, wide, deep}` of each class's
compounded judged ratios. Two consequences shape a good session:

- **Credit every class your change moves.** A single-class verdict on a
  change that speeds up all three classes silently donates the other two
  classes' gains to future predecessors — uncredited, forever. When warmed
  diagnostics show multi-class movement, run the paired S3 evaluation for
  EACH moved class and attach every verdict
  (`--verdict v-small.json --verdict v-wide.json --verdict v-deep.json`,
  same mechanism, same diff). One class's x% win moves the suite by only
  the cube root of x; three classes evidenced is full credit.
- **A submission is a checkpoint, not the finish line.** Submit each
  evidenced win as soon as its CI clears the bar — then `sync` and keep
  searching. End the session when stage attribution shows nothing left
  above the significance floor, not when the first result lands.

**Compound knowledge across sessions.** Before profiling from scratch, read
`stwo-perf notes`, the merged submissions' notes, and their transcripts —
prior sessions' stage attributions and rejected alternatives are your prior.
After submitting, record your own attribution map and dead ends with
`stwo-perf notes add` so the next searcher starts where you stopped, not
where you started.

**The whole suite is guarded (judge review, PR 20 era).** One workload is
scored, but your diff's impact-mapped slice of the twelve-AIR guard portfolio
runs as paired regression guards: every guard's upper confidence bound must
stay within its budget, cross-arm proof digests must match every round, the
pinned Rust oracle verifies each scored workload, and request-time and RSS
are hard-gated. Improving the objective by regressing anything else fails G4.
`stwo-perf run --guards none` exists for inner-loop iteration only.

**Sync before your final paired run — the frontier moves hourly.** A ratio
against a stale predecessor can be a real relative win and still land behind
the current class head, which records as `rejected` (frontier regression).
`stwo-perf update` in the canonical checkout, re-clone or `sync` the
workspace, and re-run the final evaluation against the fresh tip before
packaging.

**Transcripts are the default — and reasoning-first.** Capture your session
logs as you work (see `skills/submission-transcripts`), sanitize them per
`schema/submission.md`, and attach them with `--transcripts`. They must carry
your reasoning in full: *why* each specific change was made, the evidence
behind it, and what you rejected — the transcripts are the most valuable
dataset this project curates. The only alternative is the submitter's
explicit `--transcripts-declined`; a submission silently missing transcripts
fails `submit` locally and validation centrally.

## Submitting — two working paths

`stwo-perf submit` packages `autoresearch/submissions/<slug>/` (schema-checked
note, claimed verdict, delta digests, redacted transcripts) in your workspace.
Then:

**Path A — pull request.** Push a branch containing exactly your editable-path
diff plus the submission directory to a GitHub fork of this repository, and
open a pull request against `teddyjfpender/stwo-zig`. No label is needed (and
fork contributors cannot apply one): the pipeline classifies submissions from
the new `autoresearch/submissions/<slug>/` directory in the PR's file list;
any privileged label is applied by a maintainer, never by you. On your first
PR the workflows will sit at `action_required` until a maintainer approves
first-time Actions runs — expected, nothing to fix on your side. The
`autoresearch-validate` workflow then checks the PR mechanically on hosted
runners. When validation and CI are fully green, collaborator submissions
auto-merge and the recorder puts the result on the board within a minute or
two; first-time outside contributors get a human merge (or use Path B). The
human merge is the adjudication today: it records your claimed verdict as an
optimistic ledger row; the self-hosted judge re-run activates later.

**Path B — authenticated remote submission** (fork-funded qualification):

```sh
# once: fork this repo on GitHub and enable Actions in your fork
stwo-perf config --set api_url=https://api.autoresearch.fun
FRONTIER=$(stwo-perf remote-frontier --board core_cpu --class <class>)
# in your fork's Actions UI, run "autoresearch-qualify-fork" with that
# frontier commit and your board/class; download the
# "autoresearch-qualification" artifact into ./qualification/

stwo-perf login                      # GitHub device-flow sign-in
stwo-perf apikey                     # issues and stores your CLI API key
stwo-perf submit-remote \
  --receipt qualification/receipt.json \
  --repository https://github.com/<your-login>/stwo-zig \
  --ref refs/heads/<your-branch> \
  --note-file note.md
stwo-perf submission-status
```

**Queue honesty**: submissions are recorded and centrally validated now; the
judged re-run executes on the locked judge host when it activates (see status
note below), and one remote submission per user may be active at a time.

## What winning means

- **G1 conformance**: byte-identical proofs, accepted by the pinned Rust oracle.
- **G2 identity**: statement, protocol, and workload digests unchanged.
- **G3 mechanism**: your predicted mechanism visible in telemetry, not just a delta.
- **G4 budgets**: RSS, caches, handles, threads within bounds; other classes
  within regression budgets.
- **G5 environment**: locked judge host.
- **Score**: the declared-objective 95% CI entirely below `1 − θ`,
  `θ = max(0.01, 2 × per-class A/A dispersion)`. Inside the band is recorded as
  confirmed-neutral, not promoted.

A promotion is a merged commit + submission directory + signed judged verdict +
append-only ledger row; the leaderboard and Pareto frontier on autoresearch.fun
recompute from that ledger.

**Status honesty**: the anchor freeze is pending (activation checklist items 1–2),
so every verdict today is claimed/advisory — by design, not by gap. Submissions
still land with your evidence packaged and are judged when the judge activates.

## For agents

The repository ships skills under `autoresearch/skills/`:
`match-algorithmic-problems` (apply before replacing any algorithm),
`zig-profiling` and `metal-profiling` (S1 evidence via `stwo-prof`), and
`metal-performance-design`. Durable findings belong in `stwo-perf notes`; the
measured loop above is the only path to the ledger.
