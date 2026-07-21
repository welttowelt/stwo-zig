# Open-PR promotion validation, 2026-07-21

## Request and scope

The user asked for every open draft or reviewable pull request to be judged quickly against the latest repository state, for stale or incorrect benchmark evidence to be refreshed, and for every genuinely promotable result to be merged into `main`. This is a validation and integration pass before resuming new autoresearch work.

## Initial audit and policy prerequisite

The initial GitHub audit found PRs 54, 55, 56, 60, and 61 open. PR 60 repaired a benchmark-harness policy bug: regression-guard paired measurements were not receiving the manifest's configured confidence level after the Metrics v2 refactor. Its diff was one policy propagation line plus a focused test, all checks passed, and it was cleanly mergeable. I merged it first because every refreshed performance verdict depends on correct guard confidence intervals.

The packaged evidence in the performance PRs was not sufficient for immediate promotion:

- PR 61 claimed a strong CPU-small result, but its submitted verdict failed G4 because three guards regressed. Green generic CI does not override a failed benchmark gate.
- PRs 55 and 56 were measured against an old predecessor and their verdicts failed G2 after later harness/governance changes. PR 55's package also names a source commit that is not the PR head, so provenance must be regenerated rather than hand-waved.
- PR 54's latest package was neutral and its deep measurement failed guards. It is a draft and has no present promotion claim.
- PR 56 is a draft with failing focused/static checks in addition to stale evidence.

The governing decision is therefore to transplant only each candidate's editable source delta onto fresh `main`, rebuild both arms, and use current paired S3 verdicts. Old ratios remain useful hypotheses, never denominators.

## Repository and benchmark grounding

The repository-resident CLI was updated after PR 60 merged. The canonical checkout fast-forwarded to `f89dd0e`; two unrelated untracked Metal research notes were moved aside and restored byte-for-byte, with their SHA-256 hashes unchanged. `stwo-perf benchmark` then confirmed the current five-class CPU and Metal proof matrix, the twelve-row guard contract, and 89 recorded promotions in epoch 2.

## Skills and technical model

All five repository skills were read and applied. The algorithm-matching gate is used to distinguish real algorithm changes from constant-factor scheduling or layout changes. The Zig and Metal profiling skills require attribution evidence before optimization claims; the promotion decision itself remains paired S3. The Metal design model prioritizes complete-proof work, dispatch and synchronization economics, resource ownership, and bit-exact proof parity. Submission evidence will retain hypothesis, rejected alternatives, failed gates, and fresh results rather than sanitizing away negative findings.

## Planned validation order

PR 55 is screened first because its old measurements suggested the largest broad CPU improvement and its source area is independent of the scalar quotient change. PR 61 follows against whatever frontier results from PR 55, because a scalar-small win must survive the new baseline. PR 56 is inspected for its CI failure and screened only if its source change is still independent and mechanically valid. PR 54 remains unmerged unless a fresh current-main run reverses its neutral/guard-failing result.

## PR 55 source review and current-main results

I transplanted only the four editable source files from PR 55 onto `f89dd0e`; I deliberately excluded its stale submission directory. The patch applies cleanly, `zig build test` passes the 361-source closure, `scheme.zig` is exactly at the 850-line ceiling, and the new module is 132 lines. The ownership review found that the first commitment's owned columns transfer to the worker, the worker reads only immutable scheme configuration and a borrowed twiddle tower, twiddle telemetry is atomic, `join` publishes the result slot, spawn failure takes the old sequential path, and deinitialization joins and destroys an unresolved result. All current Native and Cairo commit pairs are consecutive; RISC-V does witness generation between the two commits but does not touch the Fiat--Shamir channel, so root mixing still occurs before its first channel draw.

The first fresh CPU-deep screen measured `R=0.9694 [0.9419, 0.9943]`, which did not clear theta despite a favorable point estimate. Small was conclusively neutral at `1.0040 [0.9859, 1.0178]`. A promotion-grade CPU-deep rerun with the corrected guard confidence policy measured `0.956338`, portfolio CI `[0.948471, 0.966256]`, theta `0.018278`, with 7 paired rounds, 4.983 ms to 4.722 ms, G1--G5 green, all 13 regression guards green, fixed proof bytes, and candidate peak RSS ratio 1.0051. This current-main evidence replaces the old package's 11.5% deep and 10.7% small claims: only CPU deep is claimable now.

One guarded attempt was invalidated before verdict construction because the Rust-oracle artifact path from the prior screen already existed. I preserved that generated run directory, cleared only the harness's generated `latest` slot, and reran. It is not counted as evidence.

### Metal architecture review brief

Workload and target devices: complete `mplonk_log14` proof on Apple M5 Max, arm64, macOS 26.5.2; the generic scheduling change also reaches `MetalCommitBackend`.

Unit of work and equivalence oracle: one verified proof transaction; every timed proof must remain byte-identical cross-arm and pass the pinned Rust oracle.

Measurement boundary, build mode, and run conditions: paired ABBA S3, ReleaseFast, warm Metal source-JIT runtime initialization outside the timed samples, uninstrumented verdict mode. The absence of full Xcode prevents a Metal System Trace, so dispatch attribution relies on backend source/telemetry and the end-to-end paired result rather than invented counters.

Measured bottleneck and evidence: two protocol-independent tree builds were serialized before their ordered root mixes. The current paired Metal screen moved 8.015 ms to 7.275 ms, `R=0.9026 [0.8939, 0.9136]`; this is scheduling latency, not a faster shader.

Required features and fallbacks: multi-threaded Zig runtime, a borrowed read-only twiddle tower, and the existing Metal backend. Single-threaded builds, empty first trees, owned twiddle sources, allocation failure, or thread-spawn failure retain the sequential path.

Resource lifetime/storage table: the worker owns the first column slice and its prepared backing until join; the scheme owns the pending slot/thread; Metal resident trees retain the shared runtime through their existing resource counter; the second build uses its existing resources. No storage mode or shader ABI changes.

Peak working set and in-flight multiplier: at most the first and second commitment transients coexist. CPU S3 measured only a 1.0051 peak-RSS ratio; Metal resource vectors passed their named budgets. No unbounded queue or ring is introduced.

CPU-GPU and pass dependency graph: `spawn prepare0/build0` runs beside `prepare1/build1`; `append tree1` first joins tree0, then mixes root0, appends tree1, and mixes root1. On Metal, each commit uses the existing shared runtime lease and creates its own FIFO command buffer from the shared command queue; its synchronous root read completes before the worker publishes the tree. The root/channel order remains strictly 0 then 1.

Command-buffer and in-flight ownership plan: no wait is deleted. The worker shifts the first existing synchronous commitment onto another host thread so the two independent preparations/queues can overlap; join is the sole new completion boundary. Existing command buffers retain their resources through completion.

Binding and pipeline-compilation plan: unchanged. The run uses already-created cached pipelines; source-JIT compilation remains initialization-only and outside post-warmup samples.

Shader/threadgroup plan: unchanged, because the measured mechanism is host scheduling and independent submissions rather than kernel code.

Work/byte/dispatch budget: identical interpolation, hashing, proof bytes, and logical dispatches; only their host overlap changes. Any changed proof digest, dispatch omission, or material RSS increase falsifies the design.

Expected counter or trace changes: unchanged work/dispatch counts, lower wall latency, and an overlap interval between the first and second commitments. CPU stage telemetry intentionally moves the first build's elapsed work under the later join.

Correctness, ABI, and synchronization proof: the pending slot is read only after `join`; immutable configuration and borrowed twiddles are the only shared preparation inputs; atomic counters eliminate the prior telemetry race; `resolve` clears the pending pointer before recursive append; root mixes remain in original order. No ABI changes cross Zig/MSL.

Before/after validation plan: full Zig closure, CPU and Metal paired S3, byte-identical proofs, Rust oracle, guard portfolio, resource budgets, and current-main predecessor binding.

The Metal relative improvement cannot be claimed despite its strong CI: G4 reports candidate/anchor 1.6021 against the x1.02 cumulative budget. This is a frontier/anchor failure, not a relative A/B or correctness failure. I therefore exclude the Metal verdict from the submission and disclose it as diagnostic evidence.

## Promotion decision for PR 55

The correct replacement package claims only current-main CPU deep, includes the small neutrality and Metal G4 failure as caveats, and binds its delta to `f89dd0e`. Merging the original PR unchanged would preserve misleading predecessor and provenance data, so the safe path is a clean replacement PR containing the same source mechanism plus freshly generated evidence, followed by closing PR 55 as superseded.
