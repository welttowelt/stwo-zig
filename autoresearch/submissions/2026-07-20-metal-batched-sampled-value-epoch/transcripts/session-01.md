# Session 01 — continuing Metal autoresearch after the resident FRI cascade

Date: 2026-07-21
Model: GPT-5 Codex

## Objective and process

Continue the optimization loop for the requested multi-hour window: update the
repo-resident CLI, benchmark the current merged frontier, profile and formalize
the next bottleneck, implement an exact Metal architecture, gather paired
evidence, package a transcript-bearing submission, open a PR, repair CI, merge
only when green, and repeat.

The canonical checkout and CLI were current at `bbb8c8823cca`, which contains
the merged resident line-FRI cascade from PR #25. A fresh worktree and branch
`autoresearch/metal-epoch2` were created from that exact recorded frontier and
`stwo-perf setup` passed before source work.

All five repository skills were read completely for this iteration. Algorithm
matching will gate any changed algorithm; Metal profiling supplies device-time
and submission evidence; Metal performance design supplies the resource,
ownership, ABI, and synchronization proof; Zig profiling is retained for any
host-side candidate; and this transcript is being captured before profiling or
editing. The required compute common-pattern reference was also read in full.
Render guidance is deliberately not loaded because the prover remains
compute-only.

## Untouched Native Metal baseline

No production source had been edited when this baseline was captured. The real
`native-proof-bench-metal` product was built in ReleaseFast and used the
source-JIT runtime, functional protocol, ten warmups, seven timed proofs, and
independent verification. Shader compilation and PSO initialization remain
outside the sampled proof interval. All samples verified, stayed byte-identical
within each run, reported `accelerated_without_fallbacks`, and used zero CPU
fallbacks.

| fixed class | median prove | median request | dispatches | FRI epochs | resident commits | proof SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| small, `wf_log10x8` | 6.351 ms | 6.555 ms | 19 | 1 | 12 | `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700` |
| wide, `wf_log14x32` | 12.614 ms | 13.588 ms | 23 | 1 | 16 | `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374` |
| deep, `plonk_log14` | 8.690 ms | 9.020 ms | 26 | 1 | 17 | `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf` |

The small samples drifted thermally from 7.48 to 4.51 ms, so its single-process
median is grounding evidence only. Any verdict must use counterbalanced fresh
processes. Wide and deep were substantially tighter.

Three-sample profiled medians on the current frontier were:

| stage | wide | deep |
| --- | ---: | ---: |
| main trace commit | 1.845 ms | 0.761 ms |
| composition evaluation | 2.644 ms | 0.145 ms |
| composition interpolate/split | 0.469 ms | 0.061 ms |
| composition commit | 1.393 ms | 0.849 ms |
| sampled-value evaluation | 1.355 ms | 2.111 ms |
| FRI quotient/build/commit | 4.209 ms | 4.641 ms |
| proof of work | 0.337 ms | 0.335 ms |
| all decommit stages | 0.182 ms | 0.219 ms |

FRI remains the largest common stage, but source inspection shows that the
sampled-value stage contains an immediately removable synchronization defect:
`evaluateCoefficientTreesWithBackend` calls the Metal runtime once per tree.
Telemetry observes two physical sampled-value dispatch epochs on wide and three
on deep, with no fallback. Each call independently packs descriptors, allocates
six Metal buffers, creates a command buffer, dispatches basis construction and
polynomial evaluation, waits for completion, and copies a small output.

The device is an Apple M5 Max on macOS 26.5.2 with unified memory, 1,024 maximum
threads per threadgroup, 32 KiB maximum threadgroup memory, and a 55.66 GB
recommended working set. The product policy is portable Metal 3.1 with a macOS
14 minimum. A Metal System Trace was attempted through `stwo-prof metal trace`
and failed because this host has Command Line Tools rather than full Xcode;
source-JIT execution remains valid through the macOS runtime compiler. A warmed
Debug diagnostic exposed approximately 0.43 ms of device time per deep tree,
while the three-call stage cost 3.78 ms in that diagnostic build. The absolute
Debug timing is not a ReleaseFast verdict, but it confirms repeated host/device
transaction overhead. A live-repo `stwo-prof zig` harness measured construction
of sixteen log-14 point-factor sets at 4.912 microseconds, 62.7k instructions,
14.95k cycles, and IPC 4.20, ruling factor math out as the millisecond-scale
target.

## Algorithmic problem match: segmented plan flattening

**Task and required semantics.** Evaluate every retained coefficient
polynomial at its tree-specific sampled points, then return the same ragged
`tree -> column -> point` QM31 result. Polynomial coefficient order, point
normalization, output order, exact M31/QM31 arithmetic, transcript absorption,
proof bytes, and failure behavior are immutable.

**Inputs and model.** The production fixed shapes contain two (wide) or three
(deep) commitment trees. Each tree currently owns a homogeneous list of
coefficient columns, cached point-factor plans, and output slices. GPU tasks are
independent once those plans exist. The relevant model is a word-RAM host that
constructs descriptors plus a bulk-synchronous accelerator: arithmetic work and
bytes are important, but command-buffer submissions and blocking completion
rounds are measured first-class costs.

**Canonical match and mapping.** This is a ragged segmented-batch flattening
problem, equivalently CSR-style local-to-global index translation over a static
independent-task DAG. Tree-local coefficient and output indices become global
indices by prefix offsets; the inverse mapping is retained for the final host
scatter. The existing Metal basis/evaluation kernels already accept arbitrary
task arrays, so no new numerical algorithm is needed.

| candidate | relationship / guarantee | fit at measured scale | implementation and risk | decision |
| --- | --- | --- | --- | --- |
| Sequential per-tree calls | Exact baseline; O(T) submissions and waits | Measured T=2/3 | Existing, highest transaction cost | reject |
| Asynchronous per-tree command buffers, one final wait | Exact if all buffers live; O(T) submissions, O(1) host waits | Removes waits but not allocations/submissions | More ownership/error plumbing and queue transactions | reject |
| Persistent ICB or argument-buffer graph | Exact when fully prepared | Shapes repeat, but factors and coefficients change per proof | New feature gates and lifetime system; disproportionate for 2/3 trees | defer |
| Global segmented descriptor batch | Exact; O(total tasks) work and O(1) submission/wait | Existing shader grid already models independent tasks | Prefix offsets plus one call through existing FFI | select |
| Fuse sampling into later quotient shader | Potentially exact but transcript needs sampled values first | Could remove a larger boundary | Couples distinct kernels, output/readback and transcript ABI; much larger proof | defer |

Apple's command-buffer guidance is **sourced**: submit the fewest command
buffers possible without starving the GPU, because frequent submission can
cause CPU/GPU synchronization stalls. `waitUntilCompleted` blocking the host is
also **sourced** from the Metal API contract. The local-index prefix mapping,
unchanged arithmetic count, and exact scatter are **derived** from this source
tree. A 0.3--0.8 ms stage reduction and one physical sampling epoch are the
**hypothesis**.

Selected transfer: flatten all per-tree coefficient pointers, factor words,
basis tasks, evaluation tasks, and output slots into one runtime call. Reject
the change if any exact result differs, telemetry does not become one epoch,
peak memory becomes material, or a counterbalanced ReleaseFast interval does
not improve end-to-end proof time.

Primary references:

- Apple, *Metal Best Practices Guide: Command Buffers*:
  https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html
- Apple, `MTLCommandBuffer.waitUntilCompleted`:
  https://developer.apple.com/documentation/metal/mtlcommandbuffer/waituntilcompleted%28%29
- Apple, `MTLComputeCommandEncoder` (multiple compute commands per pass):
  https://developer.apple.com/documentation/metal/mtlcomputecommandencoder

## Metal architecture brief: one sampled-value epoch

**Workload and target.** Compute-only Native Metal proving on the measured M5
Max. The unit is all coefficient-polynomial samples in one proof. The oracle is
the existing CPU evaluator plus independently verified, byte-identical fixed
proof hashes.

**Measurement boundary.** ReleaseFast, source-JIT initialization excluded, ten
warmups, profiled diagnosis followed by uninstrumented counterbalanced A-B-B-A
runs. Local source-JIT and authenticated AOT both consume the same unchanged MSL
exports; this proposal changes neither shader source nor pipeline identity.

**Measured bottleneck.** Wide spends 1.355 ms over two synchronous evaluator
calls; deep spends 2.111 ms over three. Host factor planning is only
microseconds. The existing runtime performs one basis and one evaluation
dispatch per tree, and blocks after each command buffer.

**Feature/fallback contract.** No new Metal feature is required. The existing
device/runtime admission, shared/private choices, source-JIT/AOT paths, and CPU
fallback policy remain unchanged. The generic PCS code uses the batched hook
only when the backend declares it; all other backends keep the reference path.

**Resource lifetime and storage.**

| resource | producer -> consumer | storage | lifetime/change |
| --- | --- | --- | --- |
| coefficient columns | retained PCS trees -> eval kernel | existing host slices copied/no-copy wrapped into shared input | all trees held until terminal wait; bytes unchanged in aggregate |
| point factors | CPU plan -> basis kernel | shared upload | concatenate all plans; aggregate bytes unchanged |
| basis/eval task descriptors | CPU prefix flatten -> kernels | shared upload | one pair of buffers instead of T pairs |
| basis values | basis -> eval | private | sum of per-tree basis counts in one buffer |
| sampled outputs | eval -> CPU scatter/transcript | shared | sum of output counts; read only after terminal wait |

Peak Metal transient bytes change from the largest tree's buffers to the sum of
two or three trees' buffers during the call. At log 14 this is bounded by the
already-live proof coefficients plus low-single-digit MiB of GPU-visible data,
negligible against 55.66 GB. There is still only one proof in flight, so the
in-flight multiplier is one.

**Dependency and ownership graph.**

```text
current
  CPU plan tree 0 -> allocate/copy -> GPU basis 0 -> GPU eval 0 -> WAIT -> scatter 0
  CPU plan tree 1 -> allocate/copy -> GPU basis 1 -> GPU eval 1 -> WAIT -> scatter 1
  CPU plan tree 2 -> allocate/copy -> GPU basis 2 -> GPU eval 2 -> WAIT -> scatter 2

candidate
  CPU build all plans -> prefix-map/pack once -> GPU basis(all)
                                           -> GPU eval(all) -> one WAIT
                                           -> exact segmented scatter
```

One command buffer owns every temporary Objective-C buffer through completion.
Basis production precedes evaluation in command order; the existing separate
compute encoders preserve that producer/consumer dependency. The host touches
output only after successful completion. An allocation or Metal error returns
through the existing error path; there is no partial result or silent fallback.

**Binding, shader, and compilation plan.** Add one backend batch hook and a
runtime host flattener. Reuse the existing C ABI and call it once; do not edit
Objective-C, MSL, pipeline creation, threadgroup widths, math mode, or AOT
manifests. Local tree indices are translated with checked prefix offsets while
packing tasks. Final outputs are scattered with the retained offsets.

**Budget and prediction.** Arithmetic work, task count, factor bytes,
coefficient bytes, and output bytes are invariant. Sample-evaluator command
buffers/waits and basis/eval dispatches should change 2 -> 1 on wide and 3 -> 1
on deep. Metal buffer objects should fall from 12/18 to 6. Prediction: reduce
the sampled stage by 0.3--0.8 ms and total wide/deep proof latency by roughly
2--8%; small may be neutral because it has fewer columns and lower absolute
work.

**Correctness and validation.** Add a generic batching equivalence test with
ragged tree shapes and duplicate point plans; run sampled-value/backend tests,
the complete Metal suites and AOT contract probes, exact CPU-vs-Metal proof
hashes, no-fallback telemetry, one-epoch mechanism telemetry, profiled stage
medians, uninstrumented counterbalanced proof timings, and the official locked
CPU S3 suite as a no-regression control.

## Implementation and first falsification pass

The selected architecture was implemented without changing Objective-C, MSL,
the C ABI, shader exports, or compilation identity. The generic PCS evaluator
builds every tree's existing cached plan and exposes one optional backend batch
hook. The Metal runtime counts aggregate resources, assigns checked global
coefficient/output prefixes, concatenates factors and basis/evaluation tasks,
calls the existing evaluator FFI once, then scatters results through the saved
prefixes. The old single-tree runtime entry point is retained as a one-element
wrapper, and all non-Metal backends retain the sequential reference route.

A two-tree device test gives both trees local column index zero, evaluates them
in one epoch, and compares every result against scalar circle-polynomial
evaluation. This specifically catches the dangerous mapping error where the
second tree could otherwise read the first tree's coefficient or overwrite its
output.

The first ReleaseFast profiled candidate pass used ten warmups and three timed,
verified proofs per class:

| class | baseline sampled stage | candidate sampled stage | reduction | candidate proof | sampled epochs |
| --- | ---: | ---: | ---: | ---: | ---: |
| small | not isolated in the initial profile | 0.377 ms | pending paired verdict | 6.639 ms | 1 |
| wide | 1.355 ms | 0.800 ms | 41.0% | 12.162 ms | 2 -> 1 |
| deep | 2.111 ms | 0.661 ms | 68.7% | 7.569 ms | 3 -> 1 |

All nine candidate proofs independently verified, were byte-identical per
class, matched the fixed hashes above, reported one physical sampled-value
epoch, and used zero CPU fallback evaluations. This confirms the mechanism and
exceeds the predeclared stage prediction. The single-process proof medians are
still diagnostic: final performance evidence must compare fresh clean commits
in counterbalanced process order.

Validation at this freeze point passes `zig build test`, `test-native-metal`,
`metal-check`, both authenticated-AOT tooling/probe suites, source conformance,
formatting, and diff checks. The broad `metal-test` result is 80/83 with two
expected skips and the same one resident-FRI parity failure documented on the
untouched predecessor; the newly added batch test passes. Changed production
owners remain below the 850-line ceiling (762 sampled-value scheduler, 823
Metal backend, 619 polynomial runtime).

## Counterbalanced end-to-end Metal verdict

The source candidate was frozen, and clean `bbb8c8823cca` (A) and candidate
`f58bab07f67c` (B) binaries were rebuilt in ReleaseFast. Seven round pairs per
class alternated A-B / B-A process order. Every process performed ten warmups
and seven timed verified proofs under the functional protocol. Ratios below
use the repository's round-median Hodges--Lehmann estimator and a deterministic
100,000-resample bootstrap interval.

| Metal class | predecessor median | candidate median | B/A HL (95% CI) | latency reduction |
| --- | ---: | ---: | ---: | ---: |
| small, `wf_log10x8` | 3.078 ms | 2.874 ms | 0.9187 [0.6642, 0.9289] | 8.13% |
| wide, `wf_log14x32` | 12.563 ms | 11.894 ms | 0.9517 [0.9357, 0.9678] | 4.83% |
| deep, `plonk_log14` | 8.668 ms | 7.603 ms | 0.8767 [0.8742, 0.8789] | 12.33% |

The three-class geometric-mean ratio is 0.9152: about 8.48% less latency and
1.093x throughput. All seven per-round ratios favor the candidate in every
class. Small's wide interval reflects two baseline-first low-frequency process
outliers. A second seven-round experiment symmetrically ran an untimed
ten-warmup process immediately before each measured arm; it independently
measured small at 3.042 -> 2.825 ms, HL 0.9225 [0.8290, 0.9442], or 7.75% less
latency. The claim therefore uses the more conservative interpretation: a
repeatable roughly 7.8--8.1% small win, not the outlier-amplified tail.

Across the primary paired suite, all 294 timed proofs independently verified,
were byte-identical within each process, and matched across arms. A scripted
audit checked every report's fixed hash, verification count, fallback counter,
and mechanism counter. Sampled-value physical epochs were exactly 2 -> 1 on
small/wide and 3 -> 1 on deep in every sample; CPU sampled-value fallbacks were
zero throughout. The changed work is therefore the predicted transaction
collapse, not reduced proof work or a backend escape.

## Official harness controls and packaging correction

The autoresearch manifest still enables only `core_cpu`, so the Metal result
cannot honestly be recorded as a scored Metal board verdict. Fresh S3 CPU
controls were run for all three moved classes against the current canonical
frontier. Every verdict passed G1--G5, the pinned Rust oracle, cross-arm proof
digest checks, request/RSS budgets, and all 12 impact-mapped regression guards:

| CPU control | ratio (95% CI) | classification |
| --- | ---: | --- |
| small | 0.9896 [0.9724, 1.0009] | confirmed neutral |
| wide | 0.9924 [0.9783, 1.0028] | confirmed neutral |
| deep | 1.0009 [0.9901, 1.0083] | confirmed neutral |

The first small control attempt correctly failed G2 because this working
transcript had temporarily been committed at root-level `transcripts/`, which
is outside the optimization allowlist. The transcript was removed from the
source commit, preserved as an untracked sanitized attachment, and the control
was rerun clean; G2 then passed. A second attempt stopped before verdict because
the previous ignored Rust-oracle artifact already existed. Only that exact
reproducible artifact was deleted, and the successful clean rerun followed.
These packaging failures produced no claimed performance evidence.

Immediately before packaging, the canonical updater confirmed that
`bbb8c8823cca` remained current. The final source diff contains only the five
allowed production/test files and does not include this root-level attachment;
the submitter will copy the sanitized transcript into the schema-approved
submission directory.
