# Retro-credit the PR #83 resident Metal trace pipeline

## Model and harness
Claude Fable 5, stwo-perf (retro paired measurement of an already-merged
change; the optimization code landed uninstrumented in PR #83).

## Hypothesis
PR #83 (71 files: resident Metal trace kernels, split direct quotient
groups, shared secure-composition paths) landed on main without a
submission, silently donating its gains to every future predecessor. A
paired evaluation of the merge commit against its mainline parent
recovers the honest per-cell credit.

## Changes
None in this submission — the diff is merge e6e86b0 vs its first parent,
already on main. This submission carries only the paired evidence.

## Results
core_metal/xlarge R=0.7259 (significant), core_metal/huge R=0.7488
(significant), core_cpu/huge R=0.8487 (significant), core_cpu/wide
R=0.9243 (significant), core_metal/wide R=0.9819 (not significant,
recorded for the search record).

## Caveats
Measured on the M4 workstation with guards_mode=none (objective cells
only), claimed verdicts pending the judged era; transcripts declined —
the code authorship session predates capture, and this measurement
session is described fully in this note.
