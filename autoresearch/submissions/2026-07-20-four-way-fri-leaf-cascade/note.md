# Extend four-way SIMD leaf hashing through the FRI cascade

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf`, updated before research
at current `main` (`95f32a8f9f6e`). ReleaseFast on arm64 macOS, paired S3
deep/time against the unchanged current-main predecessor. A reasoning-first,
sanitized transcript is attached as `transcripts/session-01.md`.

## Hypothesis

The functional protocol commits an inner FRI tree after every fold. The
existing four-message SIMD leaf builder was selected only at 16,384 leaves, so
the entire smaller-tree cascade fell back to constructing and finalizing one
incremental hasher per leaf. Warmed probes found the 8,192-leaf fallback tree
slower than the 16,384-leaf SIMD tree and attributed roughly 3 ms of wide/deep
proving to inner FRI Merkle commits. Extending the already-verified SIMD builder
through that cascade should produce a large end-to-end win without changing
hash order or proof bytes.

## Changes

The batched-leaf crossover is lowered from 16,384 to 256 leaves. On hashers
with the four-message API, `buildBatched` no longer allocates an unused
per-leaf incremental-hasher array and sizes each worker's scratch to exactly
four packed leaf messages. The generic non-four-way path retains its existing
batch storage and 256 KiB scratch policy. No field arithmetic, hash function,
transcript, protocol, or tree ordering changed.

## Results

S3 `plonk_log14` deep/time: ratio **0.8636**, 95% CI **[0.8587, 0.8708]** over
15 paired rounds. The predecessor median was 9.853 ms and the candidate median
was 8.521 ms. G1–G5 passed; every timed proof verified and remained
byte-identical.

Suite-wide warmed diagnostics also preserved the existing proof hashes and
measured 2.816→2.208 ms small, 16.469→12.589 ms wide, and 12.017→8.542 ms deep.
These unpaired values are mechanism/cross-class diagnostics, not promotion
scores. ReleaseFast prover and native-CPU product closures passed across 152
and 190 transitive Zig sources respectively.

## Caveats

This is a local claimed verdict; the locked judge rerun remains authoritative.
The anchor is not frozen, so drift budgets and judged promotion are inactive.
Mechanism telemetry wiring is still pending in the harness; the threshold
discontinuity, temporary per-layer probes summarized in the transcript, source
allocation change, identical proof hashes, and paired end-to-end result provide
the current mechanism evidence.
