# Submission directory schema (v1)

This schema is the legacy PR envelope. Bot-promoted fork submissions use the
v2 envelope documented in [remote-submission.md](remote-submission.md); both
forms are immutable research records keyed by the promotions ledger.

A submission is one directory under `autoresearch/submissions/`, added by one PR:

```text
autoresearch/submissions/<utc-date>-<slug>/
  note.md          public note; required sections below, <= 10 KiB
  verdict.json     the submitter's claimed acceptance-rung verdict (schema/verdict.md)
  verdict-<class>.json  OPTIONAL CPU verdict, or verdict-<board>-<class>.json
                   for another board; one per additional board/class pair the
                   same change moves (same mechanism, same diff). Every moved
                   pair earns its own ledger row and suite-score credit
  delta.json       predecessor binding + content digests (schema below)
  transcripts/     sanitized agent session transcripts — the submission-flow
                   default (skills/submission-transcripts): at least one file,
                   every file digest-bound in delta.json. The only accepted
                   alternative is an explicit recorded declination
                   (`stwo-perf submit --transcripts-declined`, which sets
                   delta.json `transcripts_declined: true`); silent omission
                   is refused by `submit` and rejected by PR validation.
```

## note.md required sections, in order

```markdown
# <short title>

## Model and harness
## Hypothesis
## Changes
## Results
## Caveats
```

`stwo-perf submit` refuses a note missing any section. Notes are public: no secrets,
no local absolute paths, plain language.

## delta.json

```json
{
  "schema_version": 1,
  "predecessor_commit": "<40-hex or short hash of the promoted HEAD this diff was built on>",
  "declared_objective": { "workload_class": "small|wide|deep", "dimension": "time|rss|energy" },
  "declared_scope": "s3|s4|s5",
  "files": { "<repo-relative path>": "sha256:<hex>" },
  "transcripts": { "<transcripts/... path>": { "sha256": "<hex>", "captured_by": "harness|submitter" } },
  "transcripts_declined": false
}
```

`transcripts_declined: true` records the submitter's explicit decision not to
publish transcripts; it is mutually exclusive with a non-empty `transcripts`
map and renders as "transcripts declined" wherever the submission appears.

`captured_by: submitter` transcripts are labeled unverified everywhere they render.

## Transcript sanitization contract

Transcripts are the most valuable dataset the harness curates: they are how
observers and future researchers learn *why* the change works and how the
search can improve. Sanitization removes secrets, never reasoning.

**Keep — maximize this**: user prompts; the agent's articulated reasoning in
full — the hypothesis behind each specific change, the evidence and
measurements that drove each decision, alternatives considered and why they
were rejected, dead ends and surprises, and interpretation of every profiling
or benchmark result; tool summaries; test outcomes. Every editable-path edit
in the diff should be traceable to a stated *why* somewhere in the
transcripts.

**Drop — only this**: tokens/secrets, environment values, system prompts,
raw bulk tool-output dumps (summarize them instead), broad local paths.

`stwo-perf submit` scans for secret patterns and fails closed on a hit; scrub
and re-run, never bypass.
