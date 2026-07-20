# Use the resident pool deeper into Merkle trees

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf` updated at the start of the session, ReleaseFast on arm64 macOS, paired S3 small/time against current promoted `main`. The reasoning-first submitter transcript is attached as `transcripts/session-01.md`.

## Hypothesis

Current Merkle scheduling leaves most of the installed 16-worker prover pool idle below the largest tree layer: it requires 4,096 parent hashes per worker and stops parallel hashing below 8,192 parents. Full-proof sampling showed four-way BLAKE2s compression as the hottest executable frame while worker threads waited. Reducing task granularity should reuse the already-resident pool deeper into each tree, cutting repeated Merkle fixed cost without changing hash order or proof bytes.

## Changes

Lowered the lifted Merkle parallel threshold from 8,192 to 2,048 parent nodes and the minimum chunk from 4,096 to 1,024 parents per worker. No hashing, field arithmetic, transcript, or protocol logic changed; only the number of independent parent ranges scheduled onto the existing pool changed.

## Results

S3 `wf_log10x8` small/time: ratio 0.8710, 95% CI [0.8625, 0.8780], 15 paired rounds. The predecessor median was 2.723 ms and the candidate median was 2.379 ms. Every timed proof verified and remained byte-identical.

Unpaired warmed diagnostics also preserved the existing proof hashes and measured 13.70 ms for the wide workload and 9.78 ms for the deep workload, indicating that the scheduling mechanism is not small-only. These are diagnostics, not claimed promotion scores.

## Caveats

This is a local claimed verdict; the locked judge rerun is authoritative. The anchor is not frozen, so drift budgets and judged promotion remain inactive. The threshold is tuned from profiling and full-proof evidence on the current 18-CPU arm64 host; other CPU topologies may select fewer workers through the existing capacity and CPU-count caps, but cross-host efficiency still belongs to judge and holdout validation.
