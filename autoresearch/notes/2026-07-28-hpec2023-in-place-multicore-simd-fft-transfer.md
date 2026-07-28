# HPEC 2023 in-place multicore SIMD FFT: transfer into the STWO circle-transform lane

status: completed paper-to-levers digest  
frontier reviewed: `f51e6bb9f0b71d68ccdca4b0c72f2f92a7a2a959`  
discovery: authenticated Elicit paper search, followed by primary-source review  
reviewed on: 2026-07-28

## Bottom line

Do not port the paper's complex-DFT sample-sectioning algorithm into STWO as
written. The paper solves an ordinary floating-point complex FFT on a four-core
Kalray MPPA3 with a multi-banked local memory. STWO requires an exact M31
circle-domain transform with canonical proof bytes on Apple AArch64. The
algebra, twiddle representation, memory hierarchy, and externally observable
ordering are different.

The useful residue is narrower:

- the paper corroborates in-place, transpose-free, aligned SIMD traversal;
- those mechanisms are already present at `f51e6bb9` through packed M31
  butterflies, radix-8 grouping, fused 3/4/5-layer tails, and outer
  column-level work-pool parallelism;
- its one potentially open shadow is conditional within-column partitioning of
  the highest circle-FFT layers when the outer column queue cannot occupy the
  pool;
- that shadow is **PARKED**, not a candidate, until a no-code occupancy trace
  shows fewer runnable column batches than workers while FFT work remains
  material.

The cheapest falsifier is therefore telemetry, not a new FFT implementation.
On the exact frontier, record for `deep`, `xlarge`, and `huge`:

1. number and sizes of `FftEvalWorkItem`s;
2. active/idle global-pool workers during interpolation and extension;
3. time in circle transform versus Merkle work;
4. whether the first three high layers expose enough independent blocks to
   fill otherwise idle workers.

Reject the lever if the outer queue already keeps all workers busy, or if the
serial/idle FFT fraction is below 2% of complete prove time. Preregister a
single high-layer split only if both conditions survive.

## Provenance and artifact status

Primary paper:

- Benoît Dupont de Dinechin, Julien Hascoët, and Orégane Desrentes,
  "In-Place Multicore SIMD Fast Fourier Transforms," IEEE HPEC 2023,
  DOI `10.1109/HPEC58863.2023.10363536`.
- Author manuscript: <https://inria.hal.science/hal-04240798v1>
- The HAL manuscript is six technical pages and is distributed under CC BY
  4.0.
- OpenAlex work `W4390188054` reported one citation when checked on
  2026-07-28. Citation count is context, not evidence of transferability.
- The paper and HAL record do not link an implementation artifact. This digest
  is reproduce-from-text-only; no paper code was imported.

The paper was read in full. Figures 1-2 and Algorithms 1-7 were visually
checked against the rendered primary PDF, not only extracted text.

## Campaign frame

### Hard gates

Any implementation must preserve:

- exact M31 field semantics and the circle-domain transform;
- statement, protocol, transcript, commitment, and canonical proof bytes;
- deterministic proof identity across candidate and predecessor;
- pinned Rust Stwo verification;
- the editable-path contract in `autoresearch/MANIFEST.json`;
- complete-proof scope `s3`, resource budgets, and the secret holdout.

A paper result is hypothesis supply only. Promotion requires a signed central
judgment, merge, append-only ledger row, and authoritative leaderboard update.

### Significance floor

The repository's promotion rule is a declared-objective 95% confidence interval
entirely below `1 - theta`, where
`theta = max(0.01, 2 * per-class A/A dispersion)`.

For triage, a mechanism whose complete-proof ceiling is below 1% is parked.
The tighter current telemetry falsifier uses 2% to pay for new parallel
scheduling, synchronization, and proof-identity audit burden.

### Evidence locations

- current source reviewed in this worktree at `f51e6bb9`;
- campaign measurements under the machine-local `work/autoresearch/evidence/`;
- complete-proof gauntlet through `stwo-perf`;
- authoritative remote state through `api.autoresearch.fun`;
- this note records literature transfer only and is not benchmark evidence.

## Problem-match brief

### Task and required semantics

Compute STWO's forward and inverse circle-domain transforms over M31 buffers,
including 2x extension from coefficient buffers, while preserving exact output
ordering and all downstream proof bytes.

The output is an exact transformed buffer, not an approximation. Parallel
execution may change scheduling but not arithmetic inputs, twiddle selection,
field values, ordering, or observable proof artifacts.

### Inputs, measured scale/provenance, encoding, and computational model

The live native suite includes:

- `small`: wide Fibonacci, log rows 10, width 8;
- `wide`: wide Fibonacci, log rows 14, width 32;
- `deep`: Plonk, log rows 14;
- `xlarge`: wide Fibonacci, log rows 18, width 100;
- `huge`: wide Fibonacci, log rows 20, width 100.

The designated judge is Apple M5 Max AArch64 with 18 logical CPUs. This local
screening Mac exposes 10 CPUs and is diagnostic only.

Transform values are exact 31-bit-prime field elements. Current kernels use
four-lane AArch64 SIMD packing and precomputed exact M31 twiddles. Cost is
complete-proof wall time under cache, memory, work/span, RSS, and energy gates.

### Constraints, promises, invariants, and exploitable structure

- sizes are powers of two;
- each buffer is transformed in place;
- butterfly blocks within one layer are disjoint;
- layers have dependencies, while blocks within a layer and distinct columns
  are independent;
- width-100 large workloads offer substantial outer column parallelism;
- the global work pool is shared with Merkle and other proving phases;
- proof identity makes a final layout conversion part of the correctness
  contract, not an incidental permutation.

### Candidate matches and relationship

| Candidate | Relationship | Guarantee / cost | Fit at live parameters | Reusable artifact | Risk |
| --- | --- | --- | --- | --- | --- |
| Paper's complex Cooley-Tukey sample sectioning | Analogy only | Exact for its complex DFT apart from floating-point rounding | Different transform, field, twiddles, output contract, and memory hierarchy | No code artifact linked | Very high |
| Paper's SIMD lane slicing | Analogy / vein confirmation | Aligned vector lanes, in-place | Current M31 code already packs butterflies and fuses tails | Text only | Low value |
| Parallelize disjoint blocks of high circle-FFT layers | Exact scheduling decomposition of the existing local layer graph | Same arithmetic if each block keeps the same twiddle and join barrier | Useful only when outer column tasks underfill the pool | Implement locally if telemetry passes | Nested scheduling and barrier overhead |
| Outer parallelism across same-size columns | Exact and already implemented | Independent in-place buffers | Strong fit for width-100 `xlarge`/`huge` | Existing source | None; baseline |

### Chosen canonical problem and exact variant

The project problem is not the paper's complex DFT. It is an exact,
power-of-two circle-domain FFT network over M31 with a fixed twiddle tree and
canonical output layout.

The only selected transfer is a scheduling decomposition:

> For one existing circle-transform layer, execute its disjoint
> `(block, twiddle)` operations in parallel, retain the exact per-block kernel,
> and join before the next dependent layer.

This is a special-case parallel scheduling of the existing butterfly DAG, not
a replacement transform.

### Project to canonical mapping and solution recovery

- project `values` buffer -> vertices holding M31 values;
- project butterfly invocation -> a DAG operation labeled by its exact twiddle;
- disjoint `h` blocks in one layer -> independent tasks;
- layer boundary -> mandatory barrier;
- recovered solution -> the same `values` buffer after the same labeled
  operations, with no permutation or conversion.

The mapping fails for the paper's Algorithm 7 because its initial radix-c DIF
stage, complex roots of unity, and final bit-reverse unscramble are not shown
to equal STWO's circle-domain network.

### Complexity and limits

Both the current transform and any layer-parallel schedule perform
`O(n log n)` field work and `O(n log n)` memory traffic absent cross-layer
fusion. Parallelizing a layer can reduce span only when it has multiple blocks
and idle workers. It adds at least one barrier per split layer.

The crossover is governed by:

- buffer size;
- number of independent outer column batches;
- pool width;
- block count at the chosen layer;
- task and barrier cost;
- cache interference with simultaneous columns.

No asymptotic improvement transfers from the paper.

### Prior algorithms, solvers, and implementations

At `f51e6bb9`, STWO already has:

- `fftLayerLoopForwardM31`: packed, four-way interleaved butterfly work;
- `fft_radix8.zig`: three-layer packed grouping;
- fused bottom 3/4/5-layer kernels selected to avoid residual full-buffer
  passes;
- exact precomputed forward and inverse twiddle trees;
- `circle_transforms.zig`: contiguous column batches and global-pool
  parallelism across independent work items;
- a direct 2x-extension candidate in a separate lane that removes the
  zero-fill and degenerate first layer without changing transform semantics.

These are materially closer to the live problem than the paper's complex-FFT
implementation.

### Selected transfer, integration boundary, and rejected alternatives

Selected, conditionally:

- **PARKED**: use existing pool telemetry to identify outer-queue starvation;
- if present, split only the topmost circle-FFT layer with enough disjoint
  blocks, using the existing exact kernel and a single join;
- never recursively spawn from a worker already executing a column task.

Rejected:

- ordinary complex sample sectioning as an algorithm replacement;
- floating-point trigonometric recurrences for exact M31 twiddles;
- matrix transposition removal as a new lever, because current code is already
  in place and transpose-free;
- a new final bit-reversal pass, because it adds a full memory pass and risks
  canonical layout;
- unconditional within-column parallelism on width-100 workloads, because
  outer parallelism is already abundant.

### End-to-end prediction, crossover, and falsifier

Prediction, explicitly a hypothesis:

- if a target class has fewer runnable column batches than pool workers and at
  least 2% of prove time is idle-serial circle FFT, one high-layer split may
  recover part of that fraction;
- otherwise the complete-proof ratio should be neutral or worse due to task,
  barrier, and cache costs.

Cheapest falsifier:

1. collect one profiled, untimed diagnostic per target class;
2. record work-item count, worker occupancy, and transform stage time;
3. park immediately if occupancy is already saturated or the ceiling is under
   2%;
4. only then preregister a one-layer implementation screen.

### Correctness and benchmark plan if the telemetry gate passes

1. Freeze exact frontier, file list, patch hash, workload, and one-layer
   scheduling rule.
2. Differential-test every transformed buffer against the serial path across
   boundary log sizes and random M31 inputs.
3. Require candidate/predecessor complete-proof byte identity and pinned Rust
   verification.
4. Run one quiet-host S1 attribution screen.
5. Continue only if the measured stage movement matches the predicted
   occupancy mechanism.
6. Run paired `s3` for every moved class with full guards; submit only after the
   confidence and resource gates pass.

### Open uncertainty

- The current profiler does not yet expose per-phase pool occupancy in the
  evidence reviewed here.
- The exact number of work items for `deep` may differ materially from the
  width-100 Fibonacci classes.
- A nested split may disturb cache locality even when idle workers exist.
- No claim is made that the paper's performance curve predicts Apple M31
  behavior.

## Claims ledger with axis discipline

| Paper claim | Paper evidence | Baseline / axis | Transfer verdict |
| --- | --- | --- | --- |
| SIMD lane-slicing and sample sectioning outperform the six-step implementation | Figure 1, cycles divided by transform size | Authors' C implementations on four 1 GHz MPPA3 cores, 3 MB shared local memory, 1 MB L2 | CORROBORATION only; no quantitative transfer |
| Sample sectioning is slightly faster than lane slicing | Figure 1 | Same host and complex FP implementation; the authors note lane slicing was not also applied to sectioning Step 1 | CORROBORATION only |
| The approaches avoid matrix transpositions and sample twisting between steps | Algorithms 5-7 and conclusion | Ordinary complex radix-4 DFT, in-place, bit-reversed output | ALREADY-IMPLEMENTED shadow: STWO is already transpose-free |
| Parallel chunks can seed independent twiddle recurrences | Section IV and Figure 2 | Floating-point complex recurrence with measured numerical error | DO-NOT-ADOPT for M31; exact twiddles already exist |
| The bit-reverse unscramble loop is parallel | Algorithm 1 proof | Ordinary injective bit reversal | BLOCKED as a new pass until circle-layout equivalence is proven; likely negative due full-buffer traffic |

The paper reports no exact speedup ratio in a table and gives no uncertainty
interval or repeated-run dispersion for Figure 1. The plotted ordering is
evidence about the authors' machine only.

## Mechanism verdicts

### SIMD lane slicing

Verdict: **VEIN-CONFIRMED / ALREADY-IMPLEMENTED**

STWO already replaces scalar M31 butterfly work with packed SIMD operations and
interleaves independent multiplies. Its fused bottom tails go further by
retaining multiple layers in registers.

### Sample sectioning into independent subtransforms

Verdict: **BLOCKED as a direct port**

The paper's decomposition is derived for complex roots of unity. A name-level
"FFT" match is insufficient to establish equality with the circle-domain M31
transform. Porting it without a derivation would put exactness and proof
identity at risk.

Gate-legal shadow: **PARKED** high-layer block scheduling using the existing
circle butterfly DAG and exact twiddles.

### Eliminate transposes and remain in place

Verdict: **ALREADY-IMPLEMENTED**

No new work.

### Generate twiddles by recurrence

Verdict: **DO-NOT-ADOPT**

The paper explicitly studies floating-point recurrence error. STWO needs exact
field elements and already amortizes precomputed twiddle trees. Replacing exact
twiddles with a floating recurrence is inapplicable; adding a field recurrence
would trade predictable reads for serial dependencies and requires a separate
algebraic case.

### Final bit-reversal loop

Verdict: **PARKED / likely negative**

The loop is parallel in the paper, but it adds a complete pass. STWO's current
layout is already integrated with downstream commitment order. No pass should
be added unless a larger transform rewrite removes more traffic and proves
canonical equality.

## Merkle-paper cross-check

The same Elicit refresh surfaced El-Hindi, Ziegler, and Binnig, "Towards Merkle
Trees for High-Performance Data Systems," VDBS 2023,
DOI `10.1145/3595647.3595651`.

Its reverse latch coupling addresses concurrent mutable leaf updates whose
paths contend at a shared root. STWO constructs immutable commitment levels
bottom-up, so that mechanism is an analogy only. Its splitting technique
creates multiple authenticated roots, changes tree height, and reduces hashes;
that changes STWO's commitment/proof contract and is **BLOCKED**. The
gate-legal residue - parallel independent subtrees followed by deterministic
parents - is already the family implemented by the current Merkle pool.

No new Merkle candidate is added from that paper.

## Lever-library delta

### PARK

`cpu-circle-fft-high-layer-idle-worker-split`

- owner: STWO CPU performance lane
- frontier: `f51e6bb9`
- expected value: ungraded until occupancy and stage-share telemetry exists
- discharging test: show outer FFT work items underfill the pool and idle-serial
  circle work is at least 2% of complete prove time
- implementation boundary: one existing layer, existing exact block kernel,
  one join, no nested spawn from pool workers

### ALREADY-IMPLEMENTED

- aligned packed lane processing;
- in-place transpose-free transform;
- independent outer column batches;
- multi-layer register fusion.

### DO-NOT-ADOPT

- floating trigonometric recurrence for M31 twiddles;
- ordinary complex-DFT sample sectioning without an exact circle-transform
  derivation;
- multiple Merkle roots or reduced tree height;
- reverse latching for immutable bottom-up tree construction.

## 30-second fleet summary

HPEC 2023 is useful as corroboration, not a drop-in FFT. Its headline is on a
four-core Kalray complex-FP FFT; STWO is an exact M31 circle transform on Apple
AArch64. Packed lanes, in-place traversal, transpose elimination, column
parallelism, and fused tails already exist at `f51e6bb9`. Direct sample
sectioning and floating twiddle recurrences are rejected. One shadow is parked:
parallelize a single high circle-FFT layer only if telemetry first proves outer
column tasks leave workers idle and at least 2% of complete prove time is
recoverable. The Merkle paper is also a regime mismatch: mutable-update locks
and multiple roots do not transfer to STWO's immutable canonical tree.
