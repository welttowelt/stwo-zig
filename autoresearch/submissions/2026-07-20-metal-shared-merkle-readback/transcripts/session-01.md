# Session 01 — Metal backend optimization

## Objective and user direction

The user requested a fresh autoresearch campaign focused on large Metal-backend performance improvements. The required sequence is: update the repository-resident CLI and frontier first; run the local benchmark suite before using prior research; then mine existing notes, submissions, transcripts, and ideas; profile real Metal execution; use critical analysis and visual design to propose new architectures; verify bit-exact correctness; and submit as soon as a significant result exists.

## Session start and contracts

- The canonical checkout was clean and `stwo-perf update` fast-forwarded it from `dc07e5c11d78` to `5d2eb59b2f9d` before any benchmark or source action.
- A clean worktree was created from that updated frontier specifically for this campaign.
- All five distinct repository skills were read completely: algorithm matching, Metal performance design, Metal profiling, submission transcripts, and Zig profiling. The compute-only common Metal patterns reference and the current task, manifest, and submission schema were also read before profiling or editing.
- The current manifest accepts only complete-proof S3 evidence on the `core_cpu` board, despite the requested Metal focus. This is an integration constraint to investigate rather than assume away: the campaign must determine whether the scored product invokes Metal, whether a production Metal S3 entry point exists outside the current board, and what evidence can honestly support a submission.
- Editable production code includes `src/backends/metal/**`; benchmark, build, conformance, vector, workflow, and autoresearch harness paths are locked.
- This is a compute-only workload. Render/TBDR guidance is intentionally out of scope unless profiling unexpectedly motivates a render pass.

## Evidence order

1. Run setup and the unmodified full local benchmark suite before reading earlier research results.
2. Preserve exact proof hashes and stage timing as the grounding baseline.
3. Read every relevant durable note and merged submission transcript, then inspect their diffs.
4. Map CPU/Metal product wiring and production admission requirements.
5. Capture device capabilities, a bandwidth ceiling, whole-command scheduling evidence where tooling permits, and kernel-specific GPU time/reflection.
6. Produce the required problem-match and Metal architecture briefs before any algorithmic or architectural production edit.
7. Validate parity and use paired, uninstrumented S3 evidence for any submission claim.

No production hypothesis has yet been selected and no editable-path source has been changed.

## Untouched local suite baseline

Setup built the manifest's only enabled benchmark product, `native-proof-bench-cpu`. The benchmark catalog itself confirms that the fixed acceptance suite is CPU-only. I then ran all three manifest invocations with the required 10 warmups and 3 samples, before reading prior research:

| class | prove median | request median | exact proof SHA-256 |
| --- | ---: | ---: | --- |
| small (`wf_log10x8`) | 2.153875 ms | 2.412917 ms | `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700` |
| wide (`wf_log14x32`) | 10.806750 ms | 11.815000 ms | `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374` |
| deep (`plonk_log14`) | 7.378042 ms | 7.707667 ms | `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf` |

All three samples in every workload verified and were byte-identical. The report correctly labels this direct dirty-worktree run as diagnostic/correctness-only because the transcript itself already exists; later paired verdicts will rebuild both arms and enforce the full acceptance gates.

## Prior research and product boundary

The five merged optimization submissions and their transcripts were read in full. They cover packed quotient accumulation, persistent/deeper Merkle worker pools, four-way FRI leaf hashing, packed sampled-value evaluation, and a linear FRI coset walk. None changes or measures the Native Metal backend. The reusable lesson is to preserve exact proof hashes, isolate the mechanism before pairing, and retain rejected measurements rather than combining unrelated tweaks.

The current source tree does contain a real production-shaped Metal product even though the autoresearch manifest does not score it:

- `native-proof-bench-metal` and `stwo-zig-native-metal` instantiate `MetalProverEngine` and reject CPU fallbacks on device-labelled requests.
- The compatibility benchmark accepts the same native examples and protocol arguments as the CPU benchmark, emits stage and backend telemetry, and produces the same proof bytes.
- The local path is `source-jit`: Zig embeds the MSL manifest, the Objective-C runtime calls `MTLCreateSystemDefaultDevice()` and `newLibraryWithSource:options:error:`, then caches pipeline states. Full Xcode and the offline `metal` executable are not required for this path. Backend initialization, including source compilation, is reported separately and excluded from post-warmup proof samples.
- Authenticated AOT metallib admission remains a CI/toolchain concern; the same macOS runtime can load an already-built metallib with `newLibraryWithData:`. No proposed resource-layout change alters shader source, shader ABI, library identity, or the source-JIT/AOT split.
- The missing full Xcode installation blocks only the requested `xctrace` Metal System Trace capture on this host. It does not block real device execution or command-buffer GPU timestamps.

## Untouched Native Metal baseline

The source-JIT Metal product was built in `ReleaseFast` and run with the same 10 warmups, 3 timed samples, functional protocol, included verification, and hash-only proof output as the untouched CPU baseline:

| class | prove median | request median | init | Metal dispatches/proof | resident commits | CPU fallbacks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| small | 7.376917 ms | 7.573125 ms | 26.270416 ms | 28 | 12 | 0 |
| wide | 17.142458 ms | 18.122708 ms | 18.420917 ms | 36 | 16 | 0 |
| deep | 14.113458 ms | 14.440375 ms | 18.013750 ms | 39 | 17 | 0 |

Every Metal proof verified, every repeated proof was byte-identical, and all three hashes exactly matched the CPU baseline. The classification was `accelerated_without_fallbacks`. At this scale Metal was nevertheless about 3.4x, 1.59x, and 1.91x the CPU prove time for small, wide, and deep respectively. Initialization is not the explanation because it is outside the measured proof interval.

The Metal profiler identified an Apple M5 Max with 32,768 bytes maximum threadgroup memory, 1,024 maximum threads per threadgroup, a 32-wide execution width for the isolated add kernel, unified memory, and a 55.66 GB recommended working set. A 1,048,576-element three-buffer add reached about 331 GB/s at threadgroup sizes 512 and 1,024; 256 reached about 319 GB/s. This is a ceiling measurement, not a claim that proof kernels have the same access pattern.

The first profiler invocation mistakenly used `--iterations`; the tool rejected it, and the corrected `--iters` run produced the numbers above. A full Metal trace was then attempted with `stwo-prof metal trace`; it failed because `xctrace` requires full Xcode while the active developer directory is Command Line Tools. A `/usr/bin/sample` attach to a 21-sample ReleaseFast proof run produced an empty call graph on this OS, so it cannot support attribution. Both failures are retained as dead ends; attribution below uses in-process stage timers, command-epoch counters, source-level wait topology, and Metal `GPUStartTime`/`GPUEndTime` timestamps.

## Stage and synchronization attribution

Seven profiled samples after five warmups produced these stage medians. Instrumented totals are diagnostic rather than verdict evidence:

| stage | wide | deep |
| --- | ---: | ---: |
| main trace commit | 1.232 ms | 0.676 ms |
| composition evaluation | 2.699 ms | 0.407 ms |
| composition interpolate/split | 0.482 ms | 0.055 ms |
| composition commit | 1.512 ms | 0.763 ms |
| sampled-value evaluation | 1.366 ms | 1.713 ms |
| FRI quotient build + all commits | 6.640 ms | 6.131 ms |
| FRI decommit | 2.509 ms | 2.470 ms |
| trace decommit | 0.383 ms | 0.558 ms |

FRI commit plus decommit therefore consumes about 52% of wide and 62% of deep prove time. Its near-constant cost across workloads is a stronger clue than raw workload size.

A diagnostic build exposed the existing per-operation GPU timestamps. For one warmed wide proof the quotient epoch used about 0.440 ms of GPU time, the initial circle fold about 0.032 ms, coordinate conversion about 0.013 ms, terminal line fold about 0.007 ms, and the twelve fused line-fold-plus-Merkle epochs summed to about 2.702 ms. Each of those twelve epochs already has one command buffer, one terminal wait, no intermediate wait, and between 5 and 16 dispatches. Thus roughly 3.2 ms of visible FRI GPU work sits inside a 6.64 ms ReleaseFast FRI wall stage; optimizing a sub-0.05 ms terminal fold kernel cannot recover the missing scheduling half.

The readback topology explains the separate 2.5 ms decommit plateau. Every resident tree batches all logical-layer hash reads into one blit command buffer, but FRI decommits its first tree and each of twelve inner trees sequentially. For each tree the runtime allocates a shared readback buffer, encodes many 32-byte private-to-shared blits, commits, calls `waitUntilCompleted`, and then copies into proof-owned host slices. Trace decommit repeats the same transaction once per committed trace tree. The functional protocol has only three queries, so the useful bytes per submission are tiny.

## Problem-match brief: immutable Merkle point queries across UMA ownership

Task and required semantics:
Return exactly the requested 32-byte Merkle hashes, in request and index order, from immutable GPU-produced tree layers. Preserve the existing proof bytes, query order, tree roots, error behavior, device-labelled no-fallback classification, and deterministic verifier-visible transcript.

Inputs, measured scale/provenance, encoding, and computational model:
The fixed workloads use log sizes 10 or 14, blowup log 1, fold step 1, and three functional-protocol queries. Telemetry observes 12, 16, or 17 resident tree commitments and 8 or 12 FRI fold-commit epochs per proof. Each hash is eight `u32` words. The relevant model is a word-RAM point-query workload coupled to a CPU/GPU communication model on the measured unified-memory M5 Max: useful work is sparse immutable reads after a completed GPU producer epoch; submission and completion latency dominate transferred bytes.

Constraints, promises, invariants, and exploitable structure:
All requested indices are bounds-checked; logical layers may share one physical hash arena with per-layer offsets; GPU writes are complete before a tree root is returned and mixed into the channel; trees remain immutable until decommit and are retained through it; shared-buffer CPU access is legal only after GPU completion. The secure protocol can raise queries from 3 to 70, but remains sparse relative to layer cardinality. Apple documents `shared` buffers as CPU/GPU accessible and requires scheduled GPU changes to complete before the other processor accesses them.

Candidate matches, relationship, and evidence status:

| candidate | relationship | guarantee/complexity | fit at measured parameters | reusable implementation/license | risk |
| --- | --- | --- | --- | --- | --- |
| per-tree private-to-shared blit batch (current) | exact implementation | O(K) copied hashes, O(T) submissions/waits | poor: K is tiny, T is 12-17 | current project code | measured synchronization plateau |
| one cross-tree GPU gather/blit epoch | exact batched reduction | O(K) copies, O(1) submission/wait | strong and storage-neutral | would extend current runtime | invasive prover/backend batching API |
| shared immutable layers plus direct CPU gather | exact special case of static array point queries | O(K) CPU loads, zero post-producer GPU submissions | strongest on measured UMA target | Metal shared-buffer API, project gather loop | possible GPU penalty; gate by unified memory |
| eager whole-tree shared copy | exact relaxation of query knowledge | O(N) bytes | poor because K << N | standard blit | unnecessary traffic and memory |
| CPU hash recomputation | not equivalent to requested backend execution | O(N) hash work | invalid | existing CPU implementation | violates no-fallback intent |

Material status: the semantic equivalence and O(K) direct-addressing bound are **derived**; the storage/access contract is **sourced** from Apple; the absence of a GPU-throughput penalty and the end-to-end gain are **hypotheses** requiring measurement.

Chosen canonical problem and exact variant:
Static batched point queries over immutable arrays, specialized to multiple Merkle layers whose single GPU producer has already completed, on a coherent shared CPU/GPU buffer. This is a data-layout/communication variant, not a new Merkle algorithm.

Project -> canonical mapping and solution recovery:
Each `MTLBuffer` layer is an immutable array of 32-byte records; each validated hash index is a point query; each destination slice preserves request order. For a shared layer, recover the answer with `memcpy(destination + i*32, layer.contents + layer_offset + index*32, 32)`. For a private layer or non-unified target, retain the existing blit batch. Boundary counterexample: direct access before the producing command completes would race and is rejected by the mapping; current constructors synchronously complete before exposing a tree, so that counterexample does not apply.

Complexity/limits, named parameters, and citations:
With T trees, L_t requested logical layers, and k_tl hash indices, current and proposed useful byte work is 32 * sum(k_tl). Current synchronization is O(T); direct shared gathering adds no readback command buffers. Peak tree bytes remain the same; only storage accessibility changes and per-call staging disappears. Apple states that shared storage is accessible to both CPU and GPU, is the default buffer mode on integrated/Apple silicon GPUs, and requires one processor's changes to complete before the other accesses them: https://developer.apple.com/documentation/metal/mtlstoragemode/shared . Apple defines a completed command buffer as one whose GPU commands finished successfully: https://developer.apple.com/documentation/metal/mtlcommandbuffer/status .

Prior algorithms, solvers, and implementations:
Direct array addressing and batched gather are the canonical mechanisms. MPS/Metal Performance Primitives do not provide value for a few kilobytes of immutable 32-byte point queries, and adding a general primitive would preserve the submission cost. The current project already provides the exact private-buffer blit fallback and validation oracle.

Selected transfer, integration boundary, and rejected alternatives:
On unified-memory devices, allocate proof-lifetime Merkle hash storage as `MTLStorageModeShared` and directly gather requested hashes after producer completion. Keep private storage plus the existing GPU blit path elsewhere. Reject whole-tree copying and CPU recomputation; defer cross-tree GPU batching unless shared storage measurably slows commitment kernels.

End-to-end prediction, crossover, and falsifier:
Prediction: eliminate roughly one readback command buffer and blocking wait per resident tree, reducing FRI decommit from about 2.5 ms toward sub-millisecond and trace decommit by several tenths, with no high-level cryptographic dispatch change. Shared storage should win while saved submission/wait cost exceeds any GPU hash-write penalty. Falsifiers are a statistically clear increase in FRI/trace commit time that erases the decommit gain, changed proof bytes, any CPU fallback telemetry, or a gain confined to instrumented builds.

Correctness and benchmark plan:
Run Metal commitment/readback tests including invalid layers/indices; all Native Metal tests; CPU-vs-Metal exact proof hashes for small/wide/deep; profiled stage comparison; uninstrumented 10/21-sample Metal comparisons; and the locked CPU S3 suite to establish no scored regression. Exercise both shared direct and forced/private fallback behavior where existing tests permit.

Open uncertainty:
The runtime does not currently count decommit blit command buffers, so the exact eliminated count must be inferred from tree decommit calls unless telemetry is extended. The principal uncertainty is shared-vs-private hash-write throughput on this GPU; measurement decides whether to extend shared storage to all tree constructors or use the more invasive one-epoch cross-tree readback design.

## Metal architecture brief: proof-readable Merkle residency

Workload and target devices:
Compute-only Native Metal proof generation on the measured Apple M5 Max, macOS 26.5.2, Metal 3.1 compile profile, deployment floor macOS 14. The optimized branch is gated by `hasUnifiedMemory`; other devices retain private storage and blit readback.

Unit of work and equivalence oracle:
One complete, included-verification native proof request. The oracle is byte-identical proof SHA-256 versus untouched Metal and CPU for each fixed workload, plus zero CPU fallback counters.

Measurement boundary, build mode, and run conditions:
Verdict timing is `ReleaseFast`, warmed source-JIT, with backend initialization excluded and verification included. Stage profiles and debug GPU timestamps are attribution-only. Thermal comparisons use interleaved or immediately adjacent runs with identical workload/protocol parameters.

Measured bottleneck and evidence:
Wide/deep FRI decommit is 2.51/2.47 ms and FRI commit is 6.64/6.13 ms. Twelve already-fused FRI epochs expose only about 2.7 ms of GPU work; individual terminal kernels fall below the profiler's ~0.05 ms submission-economics threshold. Source inspection finds one allocation, blit submission, and terminal wait per tree readback.

Required features and fallbacks:
Required fast-path feature: `MTLDevice.hasUnifiedMemory` and buffer `MTLStorageModeShared`. Fallback: current private non-root layers and batched blit readback. No shader feature, argument-buffer tier, SIMD-width assumption, render pass, source JIT, or new AOT artifact is introduced.

Resource lifetime/storage table:

| resource | producer -> consumer | size/lifetime | current | proposed UMA | fallback |
| --- | --- | --- | --- | --- | --- |
| Merkle non-root hash layers | Metal leaf/parent kernels -> proof decommit | about 2N*32 bytes/tree, commit through decommit | private | shared, immutable after completed producer | private |
| root hash | final parent kernel -> transcript | 32 bytes/tree | shared or explicit readback | unchanged shared | unchanged |
| quotient contiguous hash arena | quotient/Merkle epoch -> FRI decommit | offsets cover all layers | private | shared | private |
| per-decommit readback staging | blit -> CPU proof assembly | 32K bytes/call | fresh shared allocation | removed on direct path | unchanged |
| evaluation/coordinate buffers | Metal folds -> later Metal/readback | proof lifetime | existing resident layout | unchanged | unchanged |

Peak working set and in-flight multiplier:
The synchronous native prover has one proof in flight. Changing storage mode does not duplicate tree storage; it removes transient readback buffers. Fixed-workload hash storage is on the order of single-digit MiB, far below the measured 55.66 GB recommended working set. Secure-query count changes sparse output bytes, not persistent storage.

CPU-GPU and pass dependency graph:

```text
CURRENT
GPU hash tree --commit/wait--> CPU reads root --> transcript ... draws queries
                                                     |
for each tree: CPU plan -> allocate shared staging -> GPU blit tiny slices
                                                     -> wait -> CPU memcpy -> proof

PROPOSED ON UMA
GPU hash tree into shared layers --same commit/wait--> CPU reads root --> transcript ... queries
                                                                    |
for each tree: CPU validates plan -> direct immutable sparse gather --------> proof
```

The existing producer wait is protocol-visible because the root is immediately mixed into the channel. Query readback occurs later, so it needs no additional GPU completion boundary.

Command-buffer and in-flight ownership plan:
Keep every producer command buffer and terminal error check unchanged. A tree retains its shared `MTLBuffer` objects through decommit. Direct reads occur only after constructor/fused-epoch completion and before tree destruction. Private trees keep the existing readback command and error propagation. No asynchronous reuse or new in-flight slot is introduced.

Binding and pipeline-compilation plan:
No binding or pipeline changes. The same cached PSOs, embedded source-JIT library, and authenticated-AOT load path execute identical kernels. Storage-mode selection is host resource policy only.

Shader/threadgroup plan:
No MSL edit. The isolated bandwidth sweep says kernel threadgroup tuning is not the headline mechanism, and sub-0.05 ms folds are submission dominated. Existing pipeline-derived widths remain intact.

Render-pass/tile plan (if applicable):
Not applicable; this is compute-only and introduces no render pass.

Work/byte/dispatch or attachment-traffic budget:
Hash computation and bytes stored are unchanged. Useful readback remains 32 bytes per requested hash. On the fast path, GPU readback traffic, one temporary allocation, one blit encoder, one command buffer, and one blocking wait per decommitted tree become zero; CPU performs the same final 32-byte copies directly from shared contents. High-level telemetry dispatch counts should remain 28/36/39 because cryptographic work is unchanged.

Expected counter or trace changes:
FRI and trace decommit wall time should fall; FRI/trace commitment GPU time must remain neutral within noise; proof hashes and dispatch/fallback counters must be unchanged. A future explicit readback counter would move from one per resident tree to zero on UMA. System Trace is unavailable locally, so source-level command counts and stage deltas are the proxy.

Correctness, ABI, and synchronization proof:
Buffer element ABI remains eight contiguous `u32` words per hash and existing layer word offsets are applied before index offsets. Bounds validation precedes access. Apple requires GPU changes to shared memory to complete before CPU access; every tree producer already calls `waitUntilCompleted`, verifies terminal status, and only then returns the tree/root. No CPU write follows and the tree is immutable. The fallback preserves current behavior. No Zig/MSL ABI changes occur.

Before/after validation plan:
First change only storage selection plus conditional direct copies. Build and run targeted commitment tests, Native Metal tests, and exact proof checks. Compare profiled stage medians and unprofiled 21-sample medians across all three workloads. If commit regression erases the readback win, revert shared layers and implement the deferred cross-tree single-blit epoch instead. Only an uninstrumented, repeatable end-to-end gain with exact parity survives.

## Implementation and measured outcome

The selected fast path was implemented in three editable Objective-C runtime files, with no MSL, protocol, ABI, benchmark, test, build, or harness edit:

- Generic Merkle and fused FRI tree constructors now select shared hash layers when `MTLDevice.hasUnifiedMemory` is true; non-unified devices preserve private non-root layers.
- The quotient tree's packed hash arena uses the same feature-gated policy.
- Single and batched selective-hash reads detect CPU-visible shared storage and gather the already-completed immutable hashes directly. Private storage retains the exact previous allocation, blit, wait, status check, and copy path.

This maps one-for-one to the brief: the cryptographic work and root synchronization remain unchanged, while readback-only command buffers disappear on UMA.

The first three-sample small run reported 9.45 ms and looked like a serious regression. It was not promoted or explained away. A subsequent 21-sample run had a 5.89 ms median with high dispersion, and clean baseline/candidate ABBA runs resolved the initial point as transient noise. This surprise is why the final evidence uses interleaved rounds rather than the favorable first successful sample.

Two uninstrumented 21-sample processes per arm in A-B-B-A order produced these run-level medians:

| class | baseline medians | candidate medians | ratio from averaged medians |
| --- | --- | --- | ---: |
| small | 6.997, 6.559 ms | 4.600, 4.553 ms | 0.675 |
| wide | 16.914, 17.144 ms | 14.761, 14.879 ms | 0.870 |
| deep | 14.081, 13.886 ms | 11.498, 11.206 ms | 0.812 |

A harness-shaped seven-round comparison then used exactly 10 warmups and 3 samples per process, alternating A/B order each round and applying the repository's Hodges-Lehmann/bootstrap statistics to candidate/baseline ratios:

| class | R | 95% bootstrap CI | speedup from R |
| --- | ---: | ---: | ---: |
| small | 0.755333 | [0.741314, 0.786567] | 32.4% |
| wide | 0.879952 | [0.860304, 0.907340] | 13.6% |
| deep | 0.735199 | [0.583555, 0.983817] | 36.0% |

The deep process timings were bimodal and its interval is consequently wide; the independent 21-sample A-B-B-A result is the more conservative 18.8% reduction. Even the seven-round upper bound remains below 0.99. The geometric mean of the three seven-round ratios is 0.787652, corresponding to about 21.2% less latency or 1.27x throughput at the suite level.

Stage attribution moved the predicted counters rather than unrelated work:

| class | FRI decommit before -> after | trace decommit before -> after |
| --- | ---: | ---: |
| small | 1.764 -> 0.093 ms | 0.333 -> 0.014 ms |
| wide | 2.509 -> 0.158 ms | 0.383 -> 0.026 ms |
| deep | 2.470 -> 0.158 ms | 0.558 -> 0.034 ms |

That is a roughly 93-96% reduction in both readback stages. High-level proof telemetry remains 28/36/39 Metal dispatches, because those counters represent cryptographic operations rather than the eliminated readback blit submissions. Every proof remains `accelerated_without_fallbacks` with zero CPU fallback counters.

### Rejected narrower variant

I temporarily restored private storage for generic trace/composition trees while keeping shared FRI quotient and inner trees. This tested whether shared GPU writes harmed the non-FRI commits enough to outweigh trace readback. Uninstrumented 21-sample medians worsened to 5.522 ms small, 14.988 ms wide, and 11.936 ms deep, versus about 4.576, 14.820, and 11.352 ms for all proof-lifetime Merkle layers shared. The all-shared UMA policy was restored. The experiment changed only the one storage-selection expression and did not survive in the diff.

## Correctness and release validation

- All three functional workloads produced exactly the untouched CPU/Metal hashes, verified every timed sample, and remained byte-identical across repetitions.
- A secure-protocol small proof with 70 queries and 26-bit proof of work also matched the untouched hash `2e058851cb4eb078c2f06e30460e1faff535d5674c89c2da8ab460f357494228`, verified all three samples, and used no CPU fallback. Its roughly 0.57 s proof time is dominated by proof of work, so no headline latency claim is made for that protocol.
- `test-native-metal` passed the product markers, device-only prove plus independent verify lifecycle, product closure, source-JIT identity, and no-fallback contract.
- The broad Metal suite passed 78 of 81 tests with two documented stress skips and one failure in `resident FRI folds and coordinate conversion match CPU`. The exact same test fails on an untouched clean baseline binary on this M5 Max, while the commitment/readback, fused FRI tree, and Native proof parity tests pass in both. It is recorded as a pre-existing host-specific failure, not attributed to or silently waived for this change.
- `git diff --check` passes. The non-unified private path remains source-identical after the storage-mode check and is compiled into the same runtime; this host cannot execute that device-feature branch.

## Submission-board constraint

The updated CLI accepts `--board core_metal`, but the current manifest has no workload group owning that board. A direct probe fails closed with `board has no workload group: core_metal`. The only enabled acceptance group is `core_cpu`; therefore the official CLI cannot honestly mint a Metal performance verdict for this result. The plan is to run the required CPU S3 suite as a no-regression/advisory packaging artifact, state the mismatch prominently in the submission note, and preserve the real Metal ABBA evidence here. No Metal verdict will be fabricated and no locked manifest or benchmark path will be changed.
