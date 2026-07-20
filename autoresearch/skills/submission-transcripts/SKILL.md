---
name: submission-transcripts
description: Capture, sanitize, and attach the agent session transcripts that produced an optimization — the default part of every stwo-perf submission flow, and the most valuable dataset the harness curates. Use from the moment work begins (capture as you go, not after) and always before `stwo-perf submit`, which refuses to package unless transcripts are attached or the submitter records an explicit declination. The transcripts must carry the agent's reasoning in full: why each specific change was made, what was measured, what was rejected.
---

# Submission transcripts

Transcripts are the most valuable dataset this harness curates. A diff shows
*what* changed; the judged verdict shows *that* it worked; only the
transcript shows **why** — and the why is what observers and future
researchers (human or agent) mine to make the search better. The submission
flow acquires transcripts by default; the only accepted alternative is the
submitter's explicit, recorded declination — silent omission fails
`stwo-perf submit` locally and PR validation centrally.

## Capture as you go

Start the transcript directory at the beginning of the effort, not
retroactively:

```sh
mkdir -p ./transcripts
# append each session log as you work: session-01.md, session-02.jsonl, …
```

One file per session, numbered. If your harness exports conversation logs,
export them raw into `./transcripts` and sanitize in place afterwards.

## Reasoning completeness — the bar

Maximize extracted reasoning; a transcript that reads as a list of actions
has failed. Before packaging, check every item:

- **Every editable-path edit maps to a stated why**: the hypothesis behind
  that specific change, in the agent's own words, at the moment it was made.
- **Evidence is cited**: which profile, counter, or benchmark number drove
  each decision, and how the agent interpreted it.
- **Alternatives are recorded**: what else was considered and why it was
  rejected — rejected approaches are as valuable as the promoted one.
- **Dead ends and surprises survive**: reverted attempts, wrong hypotheses,
  and measurements that contradicted expectations stay in the record.
- **The narrative connects**: hypothesis → evidence → decision → result, per
  session, so a reader can replay the search, not just the outcome.

## Sanitization contract (schema/submission.md)

Sanitization removes secrets, never reasoning.

Keep — maximize: user prompts; the agent's full articulated reasoning (the
why of every change, evidence, rejected alternatives, dead ends,
interpretation of results); tool summaries; test outcomes.
Drop — only: tokens/secrets, environment values, system prompts, raw bulk
tool-output dumps (summarize instead), broad local paths.

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
