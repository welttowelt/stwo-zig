---
name: submission-transcripts
description: Capture, sanitize, and attach the agent session transcripts that produced an optimization — the default part of every stwo-perf submission flow. Use from the moment work begins (capture as you go, not after) and always before `stwo-perf submit`, which refuses to package unless transcripts are attached or the submitter records an explicit declination.
---

# Submission transcripts

The sessions that produced a change are part of the research record: how the
hypothesis formed, what was measured, what was rejected. The submission flow
acquires them by default. The only accepted alternative is the submitter's
explicit, recorded declination — silent omission fails `stwo-perf submit`
locally and PR validation centrally.

## Capture as you go

Start the transcript directory at the beginning of the effort, not
retroactively:

```sh
mkdir -p ./transcripts
# append each session log as you work: session-01.md, session-02.jsonl, …
```

One file per session, numbered. If your harness exports conversation logs,
export them raw into `./transcripts` and sanitize in place afterwards. What
must survive is the decision trail: prompts, choices, and the measurements
that drove them.

## Sanitization contract (schema/submission.md)

Keep: user prompts, assistant decisions, tool summaries, test outcomes.
Drop: system prompts, raw tool output dumps, hidden reasoning traces,
environment values, tokens/secrets, broad local paths.

`stwo-perf submit` runs a fail-closed secret scan over the directory: on any
hit, scrub the file and re-run. Never work around the scan.

## Attach at submit time

```sh
stwo-perf submit --slug <short-name> \
  --note-file note.md \
  --verdict autoresearch/.runs/latest/verdict.json \
  --transcripts ./transcripts \
  --model "<your model>"
```

The packager copies each file into the submission's `transcripts/` directory
and digest-binds it in `delta.json` (`captured_by: submitter`; rendered as
unverified until harness-captured transcripts exist). PR validation rejects a
submission whose transcript files are missing from the delta, or whose delta
names files that do not exist.

## Declining (explicit, recorded — never silent)

If the human you work for denies publishing the sessions, record that
decision instead of omitting the flag:

```sh
stwo-perf submit ... --transcripts-declined
```

This sets `transcripts_declined: true` in `delta.json`; the submission then
renders as "transcripts declined" wherever it appears. An agent must never
choose declination on its own — it is the submitter's call, made explicitly.
