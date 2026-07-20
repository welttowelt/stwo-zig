# Site feed schema (v1) — the repo ↔ website contract

`stwo-perf feed` compiles every checked-in evidence source into one JSON
file: `autoresearch/site/feed.json`. The website renders feeds and nothing
else — GitHub files are the source of truth, and this schema is the entire
contract. It is project-generic: any future autoresearch project publishes
the same shape from its own harness.

Guarantees a producer must uphold (all testable):

1. **Committed inputs only.** The feed is a pure function of files in the
   repository. The producer refuses to run when any input path has
   uncommitted changes (`--allow-dirty` exists for local debugging only and
   stamps `provenance.dirty_inputs`; a dirty feed must never be published).
2. **Deterministic.** Same inputs → byte-identical output (sorted keys; the
   only timestamps are sourced from the inputs or the commit itself, never
   from the wall clock).
3. **Provenance-bound.** `provenance.inputs_sha256` digests every input that
   feeds numeric content — manifest, ledger, epochs, the history index, and
   the exact matrix report rendered (verified against the digest the index
   records for it). Note titles are display-only and not digested.
4. **Nothing invented.** Empty boards render empty; missing telemetry is
   omitted, never zero-filled.

**The one-commit lag, by construction:** a feed committed into the repo
names the commit it was generated FROM — necessarily the parent of the
commit that adds the feed, since committing the feed advances HEAD.
Verification therefore means "`inputs_sha256` matches the input files", not
"`repo_commit` equals the commit containing the feed". CI regeneration
gates must compare feeds with the `provenance.repo_commit*` fields
excluded, or regenerate at the recorded commit.

Top-level keys:

| key | contents |
| --- | --- |
| `feed_schema_version` | integer; consumers read per version |
| `project` | slug, display name, harness name, contract pointer |
| `provenance` | repo commit + commit time, input digests, determinism note |
| `anchor` | frozen flag, anchor commit, per-class anchor prove-ms |
| `epoch` | current measurement epoch and A/A dispersion (theta inputs) |
| `promotion_scope` | v2: the decided benchmark set — manifest workload groups (board, enabled, disabled_reason, per-workload class + native unit), `owned_boards`, `future_boards`, and committed baseline directories. A board in `future_boards` exists only as scoring universe; consumers render it as out-of-scope, never as empty-but-live |
| `boards` | per scoring board (schema/scoring.md): ledger entries + per-class frontier |
| `metal_resident_progress` | Board-4 progress metrics while the board is empty (fallbacks/proof, zero-fallback row count) |
| `latest_matrix` | the newest benchmark-history matrix run: per-row workload identity, headline eligibility, proof parity, and per-lane medians (prove ms, native MHz with its unit, request ms, peak RSS, fallback/dispatch counts) |
| `baseline_matrix` | the EARLIEST committed matrix run, same shape as `latest_matrix`: the fixed pre-optimization reference vector. Suite-level progress is the vector of per-workload time ratios (latest/baseline, paired by workload name, headline-eligible rows) aggregated by geometric mean — the only consistent mean for normalized ratios — with the worst component reported alongside so no single coordinate can be gamed |
| `history` | run index (ids, kinds, report digests) and comparison count |
| `submissions` | id, note title, outcome (or `pending`), judged R, `verdict_kind`, `workload_class`, `solver` (landing-commit author; GitHub noreply emails yield the exact login), full public `note` text, and digest-bound `transcripts` refs (label, sha256, captured_by, short leading excerpt) |
| `notes_count` | standalone note count |

Consumer rules: never upgrade a `claimed`/`pending` state to judged; always
display a lane and native unit beside a number; treat feeds from forks as
untrusted until `provenance` digests are verified against the repository.

Version history: v1 had no `promotion_scope`; v2 adds it and changes nothing
else. Consumers accepting v2 must use `promotion_scope.owned_boards` to decide
which boards to display as live.

Transport: the same document is served identically from the committed file
(`autoresearch/site/feed.json`, e.g. via GitHub raw) and from a running
project backend at `GET /v1/feed`. Consumers cache a fetched feed and treat it
as current until `provenance.inputs_sha256` differs — the digest set is the
supersession key, not timestamps or HTTP headers.
