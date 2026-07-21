# Overlap the first commitment-tree build without reordering the transcript

## Model and harness

Model: GPT-5 Codex. The original architecture and source delta came from PR #55 and its Claude Fable 5 transcript; this package is an independent current-frontier review and remeasurement. The repository-resident CLI was updated to `f89dd0e` after the guard-confidence fix merged. Paired S3 runs used ReleaseFast on an Apple M5 Max running arm64 macOS 26.5.2, with both arms rebuilt and interleaved on the same host. The claimed predecessor is exactly `f89dd0e` and the candidate is `c444404` before packaging.

## Hypothesis

The first two Merkle-tree contents are independent, while only their root-mix order is transcript-visible. Building the first tree on a worker while the main thread builds the second can recover the overlap interval without deleting work, changing proof bytes, or reordering Fiat--Shamir input. The expected effect is strongest for deep Plonk, where both trees contain substantial work. A small workload whose overlap is too short should remain neutral.

## Changes

- Add one bounded pending-commit slot. The first eligible non-empty commitment transfers its owned columns to a worker; allocation or spawn failure preserves the old sequential path.
- Join at the existing tree-append choke point, mix the pending root first, then append and mix the caller's tree. Clearing the slot before recursive append makes the ordering explicit and terminating.
- Restrict deferral to a borrowed, prebuilt twiddle tower and make twiddle telemetry counters atomic. Single-threaded builds and empty or ineligible commits remain sequential.
- Drain and destroy an unresolved worker result on scheme teardown. No Metal shader, resource storage mode, proof format, or backend ABI changes.

## Results

Current-main CPU deep is significant and fully green: `plonk_log14` moved from 4.983 ms to 4.722 ms, `R=0.956338`, portfolio 95% CI `[0.948471, 0.966256]`, theta `0.018278`, over 7 paired rounds. Every sample verified, cross-arm proof digests were byte-identical, the pinned Rust oracle passed, all 13 regression guards passed, and G1--G5 passed. Peak RSS ratio was 1.0051 and proof bytes were unchanged.

The current-main small result is neutral, `1.0040 [0.9859, 1.0178]`, so this package does not repeat the old PR's stale small claim. A Metal-deep diagnostic showed a strong relative result, 8.015 ms to 7.275 ms and `0.9026 [0.8939, 0.9136]`, with exact proofs, but G4 failed because the candidate is already 1.6021 times the frozen Metal anchor. That verdict is disclosed but not claimed.

`zig build test` passed the 361-source closure. The source applies cleanly to the current frontier and remains within the manual-source ceiling.

## Caveats

This optimization relies on the present prover contract that no channel operation occurs between the first two commits. Current Native, Cairo, and RISC-V orchestration was audited; RISC-V performs witness work between commits but does not draw or mix the channel. A future violation would fail proof verification rather than silently change an accepted proof, but this invariant should remain explicit in review.

The first CPU-deep screen had a favorable 0.9694 point estimate but a CI crossing the threshold; only the subsequent clean guarded result is claimed. The Metal result cannot be promoted until the board's cumulative anchor budget is repaired or the implementation recovers enough absolute performance to pass it.
