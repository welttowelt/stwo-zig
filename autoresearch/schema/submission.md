# Submission directory schema (v1)

This schema is the legacy PR envelope. Bot-promoted fork submissions use the
v2 envelope documented in [remote-submission.md](remote-submission.md); both
forms are immutable research records keyed by the promotions ledger.

A submission is one directory under `autoresearch/submissions/`, added by one PR:

```text
autoresearch/submissions/<utc-date>-<slug>/
  note.md          public note; required sections below, <= 10 KiB
  verdict.json     the submitter's claimed acceptance-rung verdict (schema/verdict.md)
  delta.json       predecessor binding + content digests (schema below)
  transcripts/     redacted agent session transcripts (may be empty ONLY if note.md
                   declares "Transcripts: none capturable" in Model and harness)
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
  "transcripts": { "<transcripts/... path>": { "sha256": "<hex>", "captured_by": "harness|submitter" } }
}
```

`captured_by: submitter` transcripts are labeled unverified everywhere they render.

## Transcript redaction contract

Keep: user prompts, assistant decisions, tool summaries, test outcomes.
Drop: system prompts, raw tool output dumps, reasoning traces, environment values,
tokens/secrets, broad local paths. `stwo-perf submit` scans for secret patterns and
fails closed on a hit; scrub and re-run, never bypass.
