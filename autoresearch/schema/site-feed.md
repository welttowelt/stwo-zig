# Site feed schema (v1) — the repo ↔ website contract

`stwo-perf feed` compiles every checked-in evidence source into one JSON
file: `autoresearch/site/feed.json`. The website renders feeds and nothing
else — GitHub files are the source of truth, and this schema is the entire
contract. It is project-generic: any future autoresearch project publishes
the same shape from its own harness.

Guarantees a producer must uphold (all testable):

1. **Committed inputs only.** The feed is a pure function of files in the
   repository (manifest, ledger, epochs, history archive, submissions,
   notes). No network, no local state.
2. **Deterministic.** Same commit + same inputs → byte-identical output
   (sorted keys; the only timestamps are sourced from the inputs or the
   commit itself, never from the wall clock).
3. **Provenance-bound.** `provenance.inputs_sha256` digests every input, and
   `provenance.repo_commit` names the commit, so any consumer can verify the
   feed against the repository.
4. **Nothing invented.** Empty boards render empty; missing telemetry is
   omitted, never zero-filled.

Top-level keys:

| key | contents |
| --- | --- |
| `feed_schema_version` | integer; consumers read per version |
| `project` | slug, display name, harness name, contract pointer |
| `provenance` | repo commit + commit time, input digests, determinism note |
| `anchor` | frozen flag, anchor commit, per-class anchor prove-ms |
| `epoch` | current measurement epoch and A/A dispersion (theta inputs) |
| `boards` | per scoring board (schema/scoring.md): ledger entries + per-class frontier |
| `metal_resident_progress` | Board-4 progress metrics while the board is empty (fallbacks/proof, zero-fallback row count) |
| `latest_matrix` | the newest benchmark-history matrix run: per-row workload identity, headline eligibility, proof parity, and per-lane medians (prove ms, native MHz with its unit, request ms, peak RSS, fallback/dispatch counts) |
| `history` | run index (ids, kinds, report digests) and comparison count |
| `submissions` | id, note title, outcome (or `pending`), judged R |
| `notes_count` | standalone note count |

Consumer rules: never upgrade a `claimed`/`pending` state to judged; always
display a lane and native unit beside a number; treat feeds from forks as
untrusted until `provenance` digests are verified against the repository.
