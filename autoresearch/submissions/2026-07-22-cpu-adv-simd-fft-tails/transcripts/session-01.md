# Session 01: PR6 Supremacy Gate

Model: GPT-5 Codex

## User objective

Build one clean `stwo-zig` candidate that is oracle-correct and at least 1.25x faster than ClementWalter/stwo commit `07ea1ccca13351028da94e66babf79e7ce91437f` at every directly comparable PR6 cell, for both verified-request and cold-process boundaries, with a 95% ratio-CI upper bound at most 0.90 and no broad portfolio regression. Missing or merely claimed cells are failures.

## Initial status

PR6 Supremacy is not achieved. The promoted frontier is `edb5be92ac09`, including the merged Metal mid-size recurrence crossover from PR #77. The repository CLI reports current at this commit. Two unrelated untracked researcher notes were temporarily removed for the refresh and restored unchanged.

## Research workflow

The repository's five skills are binding for this effort. Problem matching will formalize exact PR6 AIR/protocol equivalence before algorithm edits. Zig and Metal profiling will attribute remaining large-cell cost before optimization. The Metal design brief will prove resource ownership, dispatch epochs, ABI, and synchronization before backend edits. This transcript records hypotheses, rejected approaches, surprises, tests, and verdict evidence as the work proceeds.

## Immediate audit questions

1. Which required workloads and protocol parameters already exist exactly, and which are only similarly named?
2. Does the current peer runner pin and build PR6 immutably on the same host, and does it expose both verified-request and cold-process boundaries?
3. Is log22 x 100 admitted without weakening standard or large profiles?
4. Does a disabled `pr6_supremacy` board and its CI/judge policy exist?
5. Which mandatory raw sample fields, parity fixtures, mutation tests, Metal generic-path differential tests, and authenticated judged artifacts are absent?
6. After parity is exact, which largest cell dominates CPU and Metal, and what do counters/traces identify as the limiting architecture?

## Exactness audit result

The pinned PR6 checkout is clean at `07ea1ccca13351028da94e66babf79e7ce91437f`. Its benchmark source confirms five width-100 wide-Fibonacci points (logs 14 through 22), four full Blake points, three Plonk points, the fixed wide-Fibonacci loop over logs 4 through 8, and the log-8 state-machine test. Source comparison disproved an initially tempting shortcut: the current Zig `blake` workload is a 96-cell synthetic recurrence, current Zig `plonk` is a simplified single-constraint example without the PR6 interaction trace, and current Zig `state_machine` omits PR6's second component and global LogUp cancellation. They remain useful broad guards, but cannot be renamed as PR6 ports.

The old peer runner is also insufficient for a supremacy claim. It stops at log20, defaults to four rounds, uses a four-lane rotation rather than two ABBA halves, wraps warmup plus sample in its process-wall field, and exposes only wide Fibonacci. The retained historical peer series is diagnostic only.

## Fail-closed infrastructure slice

Added the explicit opt-in `extreme` resource profile with exact caps of 419,430,400 committed cells and 6,710,886,400 accounted bytes. Tests establish the inclusive log22 x width100 boundary, rejection of width101, checked arithmetic, and unchanged rejection under `large`. Native CLI parsing and help now expose the profile.

Added a non-scored `extreme` manifest class and a disabled, non-promotion-eligible `pr6_supremacy` board. The board enumerates all 18 exact cells, pins both the PR6 performance peer and repository Rust correctness authority, declares ten warmups and at least seven paired rounds, and requires the two timing boundaries, identity digests, Metal counters, admission/allocation state, peak RSS, and best-effort energy/instruction/cycle counters. Frozen Metal anchors now mechanically cover scored classes only, so staging the non-scored extreme class cannot change the live five-class score universe.

Updated `TASK.md` with the activation contract and explicit status. Validation passed: 30 manifest tests, `git diff --check`, and the ReleaseFast 158-source prover closure. This slice creates no performance claim and leaves the board dark until exact ports and oracle vectors exist.

## Peer-series v2 and first real-binary finding

The wide peer runner now requires logs 14, 16, 18, 20, and 22; ten verified warmups; at least seven independent CPU and Metal A-B-B-A rounds; separate verified-request and zero-warmup cold-process schedules; deterministic round-bootstrap confidence intervals; per-half wins; immutable executable/source/shader/toolchain identities; proof/protocol/statement identities; outer RSS/instruction/cycle measurements; and explicit missing synchronization evidence. The peer adapter's verified request now begins before input construction and includes deterministic serde-JSON proof encoding/hash and independent verification. A new schema preserves the historical v1 point rather than retroactively reinterpreting it.

Real log14 smoke found that PR6's compiled `metal` feature deliberately uses its CPU-parallel trace generator below 2^16 (`generate_trace_cpu_metal` returns `None`). The device is still admitted and the exact peer proof is identical. The runner now records this pinned peer property explicitly instead of fabricating a Metal dispatch or rejecting an exact PR6 row. Zig Metal continues to require 22 dispatches and zero fallbacks at this shape.

The first four-lane smoke established exact protocol equality: Blake2s channel, PoW 10, blowup log 1, last layer log 0, three queries, fold step 1, 13 security bits. Peer CPU/Metal proof hashes match and Zig CPU/Metal canonical bytes match. Diagnostic log14 steady requests were already well ahead (roughly 14.2 versus 25.6 ms CPU and 16.3 versus 31.4 ms Metal), while first cold processes exposed Zig startup as the losing boundary.

## Cold-process architecture and measured win

Stage reporting showed warmed Metal source-JIT/session initialization at roughly 21 ms, insufficient to explain the recurring cold gap. Source inspection then found two synchronous post-proof child processes in every Zig report: `git rev-parse HEAD` and `git status --porcelain`. CPU and Metal product binaries already contain a generated identity binding commit, tree, dirty digest, Zig/target, protocol, runtime, SDK, and AOT identities.

Added an identity-bound provenance path: validate the embedded product identity, copy its immutable commit, retain runtime environment override capture, and skip the two Git children. Identity-free compatibility tools keep the exact old runtime-Git fallback. Dirty build identities remain dirty. No proof, transcript, Metal library, pipeline, dispatch, wait, buffer, or shader ABI changed. The PR6 CPU lane now uses the identity-bearing production CPU benchmark binary.

Seven cold ABBA rounds at log14 after this change pass both boundaries of the target:

| comparison | peer median | Zig median | ratio | 95% CI | half ratios |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU cold process | 41.797 ms | 26.265 ms | 0.6284 | [0.6088, 0.6545] | 0.6879 / 0.6478 |
| Metal cold process | 73.835 ms | 56.477 ms | 0.7649 | [0.7198, 0.7949] | 0.7898 / 0.7695 |
| CPU verified request | 23.326 ms | 13.269 ms | 0.5688 | [0.5608, 0.5798] | 0.5692 / 0.5684 |
| Metal verified request | 31.831 ms | 9.690 ms | 0.3044 | [0.2944, 0.3135] | 0.3147 / 0.2974 |

The first A process in each cold campaign paid a one-time system-code-cache outlier (roughly 250-275 ms); no sample was discarded. Round-bootstrap statistics and medians retained it. Both independent halves still pass comfortably. This closes only the log14 wide cell locally; it is not an all-matrix or judged supremacy claim.

## Wide-matrix screen and next bottleneck

A clean identity-bound diagnostic screen (one warmup and one sample, therefore not verdict evidence) exposed a sharp size crossover. At log16 the request ratios were 1.093 CPU and 1.027 Metal. At logs 18, 20, and 22 the Metal request ratios were 2.185, 2.768, and 3.286 even though the log20 Metal proving core itself was faster than PR6 (145.983 ms versus 188.615 ms). The request-minus-prove gap grew from about 89 ms at log18 to 379 ms at log20 and 1,604 ms at log22. Log22 also reached about 3.82 GiB RSS in Zig versus 7.68 GiB in the peer Metal lane.

Source attribution identified the cause: Zig constructs all 100 recurrence columns serially on the host, allocates and fills an explicit row-permutation table, and keeps two full temporary columns. PR6 assigns independent rows to CPU chunks/SIMD lanes or one Metal thread per row. The next design therefore treats witness construction as a typed backend capability, not a workload-name exception: contiguous storage positions derive their logical coset row, SIMD/threads fill disjoint ranges for the generic CPU route, and a governed Metal recurrence kernel writes coalesced columns through no-copy shared buffers. Admission will use structural arithmetic intensity, target and non-target shapes will be differentially tested, and an admitted Metal failure will fail closed rather than silently become a CPU fallback.

The single-sample screen is retained only to choose the architecture. It cannot satisfy an ABBA, confidence, oracle, or judged gate.

## Backend-shaped trace construction

The generic trace builder now derives the logical coset row directly from each contiguous storage index. It no longer allocates a full permutation table or two temporary columns. Native SIMD fills packed rows and the repository work pool partitions disjoint storage ranges. The Metal backend admits a quadratic-recurrence recipe from structural bounds (2 through 256 columns and at least 2^20 cells), binds a page-aligned contiguous arena without copyback, and launches one lane per stored row. The same recipe is exercised at a non-target width of 37 and compared element-for-element with the generic trace.

To carry the arena through commitment without copying, prepared inputs can now transfer shared backing ownership into PCS. Generic, constant, and streaming paths detach safely; the combined Metal path adopts a single contiguous source arena as its coefficient arena and performs the circle IFFT in place. Allocation-error review found and fixed two ownership defects: backed-column detach failures now release their arena, and a commitment's no-copy Metal view is destroyed before its host backing is returned to the allocator.

Quick diagnostics reduced wide input construction from roughly 380 ms at log20 and 1.6 seconds at log22 to roughly 11 ms and 43 ms. CPU and Metal canonical proof digests remained identical at every log from 14 through 22.

## FFT and sampled-value experiments

The large combined circle transform was extended from two fused butterfly layers to an eight-value, three-layer radix schedule. Register-local radix-8 saved about 13 ms of device time at log22 while retaining exact coefficient, LDE, and proof bytes. A new forced-path differential test runs 64 columns at log16 and compares every in-place coefficient, every extended evaluation, and the final Blake2s Merkle root against the generic CPU path.

A competing sampled-value design grouped four polynomials sharing one basis into a single threadgroup. A clean rebuild showed that it doubled the sampled epoch at log22 from about 39 ms to 84 ms because the larger live register/threadgroup state outweighed basis reuse. That experiment was completely removed. This rejection was important: an earlier stale executable had made the grouped kernel look neutral.

## Resident quotient aggregation breakthrough

Profiling initially suggested that quotient construction was repeatedly streaming the wide trace. The first attempt consulted the runtime's single most-recent trace buffer and produced no gain. Instrumentation explained why: the four-column composition commitment had replaced the 100-column main commitment before quotient construction.

The retained architecture binds residency to live commitment-tree lifetimes. Each combined tree weakly registers its host range and no-copy Metal buffer with the runtime; quotient construction discovers all live arenas, translates logical flattened view offsets to each arena's physical padded offsets, and evaluates all 100 main columns in one numerator dispatch. The weak registry does not prolong tree or backing lifetime and supports multiple structurally admitted trees. Nonresident inputs retain the generic shared/copy route.

Observed log20 quotient device time fell from about 20 ms to 8 ms. At log22 it fell from roughly 96 ms to 30-34 ms. Five warmed log22 samples after removing the rejected grouping had a 539.061 ms verified-request median (529.499 ms minimum), versus roughly 658 ms before this work and a local concrete target near 569 ms. Peak physical footprint remained about 6.48 GB, all five proofs were 106,436 bytes with digest `2c0ca9f7a73ea80f4cc32f2e27785f9ccf6b11dc460a133ebc8f5cc441e76205`, and telemetry reported zero CPU fallbacks.

A three-sample candidate screen across the five Metal sizes measured request medians of 16.542, 22.800, 36.120, 134.650, and 523.441 ms at logs 14, 16, 18, 20, and 22. Every size used one trace-generation dispatch with zero copybacks and deterministic bytes. Matching CPU digests were exact, but CPU medians were 14.869, 27.678, 88.554, 369.446, and 1594.415 ms, so the CPU supremacy cells from log18 upward remain failures.

The Metal runtime identity previously hashed only `runtime.m`, even though that file imports the implementation closure. The same v2 product-identity field now digests the ordered umbrella, profile, ABI/compile headers, and every imported Objective-C runtime unit. Historical schema compatibility is preserved while runtime subfile drift is now observable.

ReleaseFast aggregate tests, Native CPU/Metal product tests, Metal AOT tests, formatting/source conformance, the 158-source prover closure, and the holistic native smoke matrix pass. These are pre-submission guards, not a judged PR6 verdict.

**PR6 Supremacy: not achieved.** Exact PR6 Blake, Plonk, fixed-wide-Fibonacci, and state-machine ports/oracle vectors are still missing; CPU large-wide cells remain slow; and the complete seven-round same-host verified/cold ABBA matrix has not yet produced an authenticated judged verdict.

## Retained diagnostic verdict and production block

The complete seven-round/two-boundary width-100 series for commit `330542ee484b3f8ae16b351ea18c48329ef164c0` is retained verbatim as `evidence/330542ee484b-wide-series-v2.json`. Metal verified-request passed at all five sizes: candidate/peer ratios were 0.2786, 0.5960, 0.5541, 0.6686, and 0.7921 for logs 14 through 22, with CI upper bounds below 0.90 and both ABBA halves winning. This is significant evidence that the resident trace/quotient architecture works. It is not promotion evidence: Metal cold process passed only log14, CPU verified request passed only logs14/16, CPU cold passed only log14, and exact non-wide ports and the judged oracle verdict remain absent.

Review also identified a production blocker in that commit: resident quotient inputs were discovered through a process-wide weak tree table and host-address matching. The commit remains an immutable diagnostic checkpoint and will not be proposed or merged as-is.

## Explicit proof-session residency and lifetime closure

The successor removes both runtime-wide mutable inputs: there is no weak resident-tree registry and no process-wide "last composition trace" buffer. The PCS scheme now derives a borrowed residency set from its own commitment trees and passes those opaque handles through the lazy quotient provider. Objective-C accepts only that call-local list, strongly retains it for the command, rejects trees owned by another runtime, and searches host ranges only inside the explicit proof session. Every Metal tree strongly retains its runtime owner; the shared-runtime resource counter still prevents teardown while a real resident tree lives. Recurrence composition binds its call-local trace instead of consulting runtime state.

New tests cover two simultaneous log17 x width64 proofs sharing one runtime, multiple concurrent resident trees, deterministic CPU/Metal proof-byte parity on that non-target shape, mixed host/resident handle sets, tree destruction followed by reuse of the identical page-backed host address, runtime shutdown with a live real tree, zero live resources after destruction, and an injected failure immediately after combined-backend ownership transfer. A source contract also rejects reintroduction of `residentTraceTrees` or `compositionTraceBuffer`.

Five warmed log22 samples on the explicit-session implementation had a 531.268 ms verified-request median, 524.322 ms minimum, the unchanged 106,436-byte proof and `2c0ca9f7...6205` digest, zero fallbacks, and about 6.48 GB lifetime peak footprint. The explicit API therefore retained, and slightly improved on, the earlier 539.061 ms warmed diagnostic.

## Cold-process semantic capability breakthrough

Profiling the fresh process found that residency was no longer the cold bottleneck. Both CPU and Metal secure-composition accelerators used a process-global hook and treated a vtable address as an untrusted runtime identity. The first proof therefore evaluated the entire composition twice: once through the accelerator and again through the scalar reference, caching acceptance only for later requests. At log22 this converted a roughly 0.53-second Metal request into roughly 1.8 seconds.

The runtime-learning mechanism is replaced by an explicit, versioned structural AIR capability on `ComponentProver`: `quadratic_sum_squares_v1` declares the complete consecutive-column relation and its trace-tree subspan. CPU and Metal select accelerators through the proof's backend type, not a process-global hook; unmarked/lookalike components stay on the reference evaluator. Secure-circle interpolation is routed the same way. This makes simultaneous CPU and Metal proofs backend-local and removes a hidden cross-request dependency. Correctness is locked by independent verification and canonical CPU/Metal proof parity on a non-target width64 shape, in addition to the existing forced combined LDE/Merkle differential.

After this change, five consecutive post-build fresh log22 Metal processes took 0.59--0.65 seconds wall time, versus the retained PR6 peer cold median of 0.914 seconds and the superseded candidate median of 1.910 seconds. The first newly linked binary invocation retained its uncensored 1.13-second system-code-cache outlier. A representative request took 535.240 ms, produced the unchanged proof digest, reported zero fallbacks, and reduced lifetime peak physical footprint from about 6.48 GB to about 3.13 GB because the duplicate scalar composition no longer exists.

Profiler evidence is retained as `evidence/explicit-session-cold-log20-metal-profile.ndjson`. With encoder timestamps enabled it records ten command buffers, ten waits, 129 dispatches, 38 compute encoders, one blit encoder, 120.62 ms aggregate host wait and 76.97 ms aggregate GPU time. The dominant device epoch remains combined circle LDE plus Merkle (49.62 ms GPU, 53.09 ms host wait); polynomial evaluation and quotient construction follow at 8.98 ms and 7.92 ms GPU.

**PR6 Supremacy: not achieved.** The clean successor still needs the complete ABBA rerun, current-main comparison, exact PR6 non-wide ports and oracle vectors, broad portfolio gates, and an authenticated judged verdict.

## Clean explicit-session series and the final Metal request miss

Commit 2a450042da88a6054ca68000a72b351b6034080c was the first clean
candidate with explicit proof-session residency, structural AIR capabilities,
backend-scoped acceleration, and the cold-process duplicate-composition fix.
Its complete seven-round series is retained as
evidence/2a450042da88-wide-series-v2.json (SHA-256
8dd9615cebc2f384ee2317143b5f7dce80d1a97b6f2098a68e74be8d34c1645a).

All five Metal cold-process decisions passed. Metal verified-request passed at
logs 14, 16, 18, and 20, but log22 remained a real miss:

| log | boundary | peer ms | Zig ms | ratio | CI high | halves | pass |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | :---: |
| 14 | request | 30.420 | 8.765 | 0.2881 | 0.3268 | 0.2927 / 0.2882 | yes |
| 16 | request | 37.651 | 24.361 | 0.6470 | 0.6701 | 0.6479 / 0.6503 | yes |
| 18 | request | 57.874 | 39.212 | 0.6775 | 0.7212 | 0.6552 / 0.7002 | yes |
| 20 | request | 200.851 | 146.134 | 0.7276 | 0.7428 | 0.7382 / 0.7278 | yes |
| 22 | request | 671.034 | 566.093 | 0.8436 | 0.8467 | 0.8449 / 0.8379 | no |
| 14 | cold | 71.402 | 52.267 | 0.7320 | 0.7561 | 0.7417 / 0.7006 | yes |
| 16 | cold | 86.273 | 67.357 | 0.7807 | 0.7924 | 0.7840 / 0.7758 | yes |
| 18 | cold | 120.369 | 83.030 | 0.6898 | 0.7151 | 0.6588 / 0.6980 | yes |
| 20 | cold | 275.627 | 188.525 | 0.6840 | 0.6972 | 0.6838 / 0.6817 | yes |
| 22 | cold | 889.280 | 637.490 | 0.7169 | 0.7387 | 0.7330 / 0.6994 | yes |

This result separated two questions that had previously been entangled. The
explicit residency API closed the lifetime and cross-request correctness
hazard, and the backend-local semantic capability closed the cold-process
penalty. Neither alone made the largest warmed request fast enough.

## Reusing the proof-session tree for composition

Commit 765b8c21d41f69a6f2e7e5f00ef2c476d8a2c944 removed another hidden
large-input cost. Recurrence composition had the correct explicit session
scope, but still created a call-local no-copy Metal alias over the multi-
gigabyte host trace. The PCS now preserves tree-index alignment in its
proof-session residency handles and passes the exact main-tree handle to the
composition capability. Objective-C validates runtime ownership and the
requested byte range before reusing the tree's existing resident buffer.
Nonresident traces retain the safe call-local alias; a wrong runtime or
out-of-range trace fails closed.

The ownership model after this change is:

    proof session
        |
        +-- PCS tree 0 --------> explicit resident handle ----+
        +-- PCS tree 1 --------> explicit resident handle     |
        +-- PCS tree N --------> null or resident handle      |
                                                           quotient
    structural AIR capability ----------------------------> composition
                                                           |
                                                           +--> same-runtime,
                                                                range-checked
                                                                Metal buffers

No process-global hook, weak tree registry, most-recent buffer, or
workload-name test participates. The runtime owner remains alive while a real
tree is alive, and the concurrency/address-reuse/failure tests from the
explicit-session checkpoint continue to cover this path.

A clean five-sample log22 screen measured a 550.23 ms request median
(522.02 ms minimum) and 496.62 ms prove median with the unchanged proof.
The retained pre-radix profile,
evidence/765b8c21d41f-log22-metal-profile.ndjson, records ten command buffers,
ten waits, 43 encoders, 307.18 ms total command GPU time, 265.12 ms attributed
encoder GPU time, and 422.05 ms host wait. The dominant epochs were:

| command | GPU ms | share |
| --- | ---: | ---: |
| combined circle LDE and Merkle | 198.323 | 64.56% |
| polynomial evaluation | 39.179 | 12.75% |
| quotient construction | 25.902 | 8.43% |
| recurrence composition | 6.360 | 2.07% |

This made the remaining architectural target unambiguous: the combined circle
transform streamed the full wide arena through too many global passes.

## Four-layer circle-transform fusion

Commit 42a550dce55e184d4a879dc667af700109aee59a extends the existing
two- and three-layer sparse transform kernel with a register-local sixteen-
value schedule. Bit 29 selects radix 16, bit 30 selects radix 8, and bit 31
selects inverse order. One thread owns a complete tuple, loads sixteen field
elements, performs four adjacent butterfly layers in registers, and writes
once. The inverse and extended forward schedulers use it only when four whole
layers remain, preserving the smaller schedules for tails.

The change removes one full base-arena pass and one full extended-arena pass at
log22. A profile screen reduced the combined command from 198.323 ms to
187.103 ms and its encoder count from 43 to 41. A clean ten-warmup,
seven-sample log22 request screen measured a 521.219 ms median
(518.063--534.718 ms, MAD 2.484 ms) and 468.851 ms prove median. All seven
proofs were 106,436 bytes with digest
2c0ca9f7a73ea80f4cc32f2e27785f9ccf6b11dc460a133ebc8f5cc441e76205,
zero CPU fallbacks, and about 3.13 GB peak physical footprint.

The forced combined-path differential at log16 x width64 compares every
coefficient, every extended evaluation, and the final Blake2s Merkle root with
the generic path. ReleaseFast aggregate tests, Native CPU and Metal products,
Metal AOT, formatting, source conformance, the 158-source prover closure,
25 proof-matrix tests, and all 13 holistic smoke rows passed before the clean
series.

## Complete immutable width-100 series at 42a550dc

The full same-host run used the pinned PR6 commit
07ea1ccca13351028da94e66babf79e7ce91437f, Rust
nightly-2025-07-14, immutable release binaries, ten verified warmups, and seven
independent A-B-B-A rounds for each lane and boundary. Cold Metal includes
source JIT. The raw 2,046,059-byte artifact is
evidence/42a550dce55e-wide-series-v2.json with SHA-256
069b77658ba6dc0e6ef876262277d00978fd3a8a9081eb25ce1daf71788f8127.
It binds candidate commit 42a550dce55e184d4a879dc667af700109aee59a,
source tree 0fc65917020e480259ba106c0a016bb35a0ac2cc1c841561245cb4801d6cabb2,
and shader tree a49062045f0878012f1cb84a679705e3c3691165e79b95e3a393e52d14935afd.

Every Metal decision passes:

| log | boundary | peer ms | Zig ms | ratio | 95% CI | halves |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 14 | request | 28.461 | 8.921 | 0.3135 | [0.2958, 0.3287] | 0.3178 / 0.3285 |
| 16 | request | 38.095 | 23.917 | 0.6278 | [0.6054, 0.7021] | 0.6288 / 0.6160 |
| 18 | request | 63.087 | 37.602 | 0.5960 | [0.5785, 0.6110] | 0.6098 / 0.5828 |
| 20 | request | 198.151 | 142.064 | 0.7169 | [0.7056, 0.7257] | 0.7188 / 0.7154 |
| 22 | request | 691.854 | 546.295 | 0.7896 | [0.7760, 0.8086] | 0.7893 / 0.7854 |
| 14 | cold | 70.186 | 53.086 | 0.7564 | [0.6895, 0.7841] | 0.7672 / 0.7187 |
| 16 | cold | 89.609 | 67.378 | 0.7519 | [0.7296, 0.7757] | 0.7581 / 0.7684 |
| 18 | cold | 123.560 | 81.616 | 0.6605 | [0.6406, 0.6931] | 0.6629 / 0.6582 |
| 20 | cold | 266.202 | 184.142 | 0.6917 | [0.6701, 0.7045] | 0.7060 / 0.6770 |
| 22 | cold | 915.854 | 597.010 | 0.6519 | [0.6484, 0.6594] | 0.6582 / 0.6461 |

Metal verified-request geometric mean is 0.5814; Metal cold-process geometric
mean is 0.7011, only 0.0011 above the secondary 0.70 target; their combined
geometric mean is 0.6384. Relative to the clean explicit-session checkpoint,
log22 request improved 3.50% and cold process improved 6.35%.

The CPU decisions identify the next scope:

| log | request ratio / CI high | cold ratio / CI high | result |
| ---: | ---: | ---: | --- |
| 14 | 0.6017 / 0.6404 | 0.6619 / 0.6739 | both pass |
| 16 | 0.6641 / 0.6780 | 0.6621 / 0.6841 | both pass |
| 18 | 0.9450 / 0.9794 | 0.8109 / 0.8605 | both fail ratio |
| 20 | 1.0618 / 1.0791 | 1.0367 / 1.0384 | both fail; both halves lose |
| 22 | 1.1666 / 1.1840 | 1.1294 / 1.1396 | both fail; both halves lose |

Thus CPU fails six boundary decisions across three sizes, and the all-wide-
decision geometric mean is 0.7362 rather than at most 0.70.

The artifact contains 560 timed observations. None failed verification,
allocation, or a required timing field. At every size, Zig CPU and Metal
canonical bytes are identical and stable, the protocol and statement digests
are stable, and Metal reports zero CPU fallbacks. Candidate proof sizes are
48,180, 61,470, 74,328, 86,383, and 106,436 bytes. The log22 resource
descriptor records exactly 419,430,400 committed cells and 6,710,886,400
accounted bytes under the extreme profile.

## Interpretation, retained evidence, and production block

This clean series is significant evidence that the resident pipeline
architecture works: it passes every individual Metal request and cold-process
performance decision, including log22, without proof drift or CPU fallback.
It supersedes the unsafe weak-registry checkpoint as the implementation
evidence. It does not authorize promotion or a supremacy submission.

The recorded limitations remain material:

- CPU fails both boundaries at logs 18, 20, and 22.
- Exact PR6 Blake, Plonk, fixed-wide-Fibonacci, and state-machine ports and
  oracle vectors do not yet exist.
- The report explicitly marks Metal synchronization telemetry incomplete.
- Repository-pinned Rust-oracle acceptance has not been captured for every
  measured Zig proof.
- Current-main, holistic Native/Metal/RISC-V CI/RSS/energy protection and the
  authenticated locked-M5 judged verdict are absent.
- Thermal sensors were unavailable; the raw host load averages are retained.
- Peer and Zig use different canonical encodings, so cross-implementation
  proof-byte equality is not claimed; within Zig, CPU/Metal bytes are exact.

No submission or merge is made from this checkpoint. The next optimization
scope is the structurally shared CPU proving path, beginning with log22
profiling and then rerunning all five CPU sizes without hiding a losing cell.

**PR6 Supremacy: not achieved.**

### Clean CPU submission extraction

The policy warning on the cumulative branch was resolved without discarding
the evidence or rewriting its history. The arithmetic/FFT commit was replayed
onto current main in a dedicated worktree, its one transform-scheduler conflict
was resolved by retaining the active-layer-aware fused-tail selection, and the
test-only file outside the board policy was omitted. The resulting immutable
candidate `ee3316f3685f` changes only four admissible files under
`src/core/fields/` and `src/prover/poly/`.

Both ReleaseFast core and prover closure checks passed. A fresh S3 comparison
against `354da109e02a` then passed G1--G5, including a clean identity gate and
all 13 automatic regression guards. Its huge CPU result is 356.401 -> 332.792
ms, ratio 0.9239, 95% CI [0.9129, 0.9362]. Energy ratio is 0.9130 (upper
0.9158), RSS ratio is 0.9992 (upper 1.0097), and proof size remains 86,383
bytes. The reduction is smaller than the cumulative branch's 0.7556 result,
which quantifies the additional value of the earlier general batching and
layout work, but it is independently significant and immediately admissible.

This clean verdict is the one attached to the submission. The cumulative
result remains diagnostic evidence for the next policy-scoped submissions.

**PR6 Supremacy: not achieved.**

## CPU recovery after the Metal checkpoint

The next phase deliberately moved to the shared CPU proving path. The mature
PR6 peer already used parallel SIMD, so the search focused on reductions in
work, layout traffic, cache churn, and arithmetic latency rather than merely
adding threads. The working candidate accumulated three general mechanisms:

1. batching wide proving passes and selecting FFT schedules that keep large
   passes regular;
2. hashing equal-height leaf columns in their producer layout and batching
   secure composition work; and
3. replacing dense scalar M31 products with an exact four-lane AArch64 fold,
   while fusing only size-aligned transform tails.

### Iterations that did not survive

Several attractive ideas were falsified before the final run:

- A proposed direct 2x LDE reuse treated one half of the extended domain as
  the base domain. A deep coefficient-by-coefficient test failed at index zero.
  Inspecting the circle domains showed why: the canonical base and extended
  cosets are disjoint. The implementation was removed rather than guarded by a
  benchmark shape.
- A compact, partially unrolled Blake compressor eliminated a 464-byte spill
  frame, but static instruction count rose and whole-proof timing was neutral
  to worse. It was removed.
- Heterogeneous dynamic tiling of leaves, Merkle subtrees, and composition
  produced more scheduling flexibility but worse locality. It was removed.
- A packed radix-16 CPU FFT pass was correct but increased register pressure
  and regressed end-to-end time. It was removed.
- An earlier inline-assembly `sqdmull` attempt introduced volatile/barrier
  effects and worse code generation. It was removed. The final arithmetic
  mechanism is materially different: nonvolatile full-lane `mul.4s` plus
  `sqdmulh.4s`, followed by an exact Mersenne fold.

These failures reinforced a useful design constraint: on the M5 Max, reducing
passes helps only when the fused kernel still fits the machine's register and
cache behavior. Wider is not automatically faster.

### Exact four-lane M31 reduction

For canonical M31 inputs, AArch64 `mul.4s` supplies the low 32 product bits and
`sqdmulh.4s` supplies the doubled signed high half. Because inputs are below
2^31, these pieces can be recombined into the quotient and residue needed for
reduction modulo 2^31-1. A mask/fold sequence and `umin` canonicalize all four
lanes. The portable non-AArch64 route is unchanged.

The emitted clean benchmark binary contains 213 `sqdmulh` instructions. The
code-generation record is `evidence/0cca924-adv-simd-codegen.md`. This was
important evidence against the common failure mode where source-level vector
code quietly lowers back into scalar widening operations.

The transform change complements the field primitive. Three-, four-, and
five-layer fused tails are selected only when those exact whole-layer suffixes
remain. This leaves the preceding transform aligned to radix-8 passes and
avoids the register-pressure failure seen in the radix-16 experiment.

### Correctness closure and repository repairs

The first apparent aggregate test success was incomplete: convenient build
aliases did not execute `src/stwo_deep.zig`. The actual protocol-root runner,
`python3 scripts/zig_protocol_test.py src/stwo_deep.zig -OReleaseFast`, exposed
pre-existing branch drift. Test doubles lacked the newer `commitWithBacking`
contract, broad inferred error sets became recursive, and Metal shader export
counts were stale. Those closure defects were repaired separately in
`ba3be71`, after which the canonical root passed 122/122 and the deep root
passed 323/323.

Source conformance then caught two overgrown implementation files: the Blake
backend was 919 lines and the FFT kernel file was 929. Tests were split into
dedicated existing test modules, producing final sizes of 803 and 849 lines
and no new conformance findings. The first holistic smoke invocation also
refused to overwrite a populated output directory. The old artifacts were
preserved under a timestamped name and the rerun completed all 13 rows.

Final validation covered the focused M31 differential (24/24), FFT kernels and
the new fused-tail differential, core and prover roots, Native CPU, Native
Metal, and RISC-V products, and the holistic Native matrix. Every holistic
proof verified; CPU and Metal canonical bytes were identical; Metal reported
zero CPU fallbacks.

### Clean screens and sustained exact-PR6 evidence

One warmed immutable CPU process, with ten warmups and seven measured samples,
reported these verified-request medians:

| width-100 size | median |
| ---: | ---: |
| 2^14 | 10.876 ms |
| 2^16 | 20.534 ms |
| 2^18 | 69.962 ms |
| 2^20 | 268.833 ms |
| 2^22 | 1145.818 ms |

All repeated proofs were deterministic. The log22 extreme descriptor admitted
exactly 419,430,400 committed cells and 6,710,886,400 accounted bytes with
checked arithmetic. Its approximately 6.89 GB peak footprint remains an
operational concurrency constraint.

The subsequent complete peer series intentionally used a harsher sustained
ABBA schedule. Its raw artifact is
`evidence/0cca92428973-wide-series-v2.json`, SHA-256
`a173dbb969d093dcd851ee9b2c5af95967af646d9d0f8678d92de37a33e3c0c0`.
It binds the pinned PR6 peer, all five sizes, CPU and Metal, verified request
and complete cold process, ten warmups, seven counterbalanced rounds, stable
proofs, and zero Metal fallback.

The current CPU decision table is:

| log | cold ratio / CI high | request ratio / CI high | result |
| ---: | ---: | ---: | --- |
| 14 | 0.6359 / 0.6516 | 0.5327 / 0.5501 | pass/pass |
| 16 | 0.5603 / 0.5785 | 0.5517 / 0.5614 | pass/pass |
| 18 | 0.6915 / 0.7145 | 0.7371 / 0.7735 | pass/pass |
| 20 | 0.8043 / 0.8091 | 0.8023 / 0.8127 | ratio miss/miss |
| 22 | 0.8411 / 0.8460 | 0.8666 / 0.8714 | ratio miss/miss |

Both ABBA halves favor Zig in every CPU cell and every upper confidence bound
is below 0.90. Logs 20 and 22 therefore show convincing improvement but miss
the contract's absolute 0.80 median threshold. Metal passes nine of ten cells;
only log22 verified request, at ratio 0.8065 and CI high 0.8258, misses that
same median threshold.

The previously reported 132--135 ms at log20 and 523--539 ms at log22 were
reconciled rather than hidden: they were Metal verified-request measurements.
They were never comparable CPU figures. Earlier same-series CPU request
medians at the prior checkpoint were 417.29 and 1790.20 ms. Under sustained
ABBA, the current log20 CPU request median is about 310.87 ms and log22 is
about 1494.71 ms, substantial improvements at the same boundary.

### Repository S3 verdict and submission decision

After updating the installed CLI and freezing current main at `354da109e`, an
S3 `core_cpu/huge` run compared candidate `0cca92428973` on the repository's
normal log20 x100 workload. The result was 356.318 -> 271.970 ms, ratio 0.7556,
95% CI [0.7465, 0.7639]. It is a significant 24.4% proof-time improvement.
Energy ratio is 0.6529 with upper CI 0.6560, RSS ratio is 1.0003 with upper CI
1.0113, and proof bytes remain exactly 86,383. All 13 automatic regression
guards passed. Every timed proof verified, cross-arm digests were identical,
and the pinned Rust oracle accepted the scored workload.

The verdict is still local and claimed. Its identity gate accurately records
that this long-lived PR6 branch contains inherited Metal/task-support files
outside the narrow CPU board's editable set. That policy limitation is retained
in the verdict and submission note; it does not erase the measured CPU result,
but only the locked judge can promote it to judged evidence.

The complete required PR6 workload ports, all oracle vectors, synchronization
telemetry, and the remaining log20/log22 thresholds are not complete.

**PR6 Supremacy: not achieved.**
