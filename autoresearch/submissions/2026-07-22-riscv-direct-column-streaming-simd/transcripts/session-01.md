# Autoresearch session 01 — RISC-V deep epoch 4

## Objective and frontier

This session continues the long-running optimization loop after PR #83 merged
the explicit Metal resident proof pipeline into `main` at `e6e86b072604`.
The user extended the run for nine additional hours and explicitly requested
large architectural improvements, with special priority on the largest RISC-V
benchmarks. The acceptance unit is therefore the complete seven-program
`riscv/deep` portfolio, followed by Native CPU and Metal product guards; an
isolated kernel win is only diagnostic.

The repository-resident CLI was refreshed before work. A clean detached
workspace was cloned from current main and `stwo-perf setup` built the Native,
RISC-V, and Metal bench products. No source edit has been made yet.

## Method and prior evidence

All five repository skills were reread from current main. Their binding method
is: profile before editing; write a problem-match brief before a material
algorithm change; use instruction/cycle/sample evidence for CPU attribution;
preserve the compute-only Metal residency, synchronization, AOT, and proof-byte
contracts; and capture rejected approaches and surprises rather than erasing
them. The Metal common-patterns reference was read completely; render-specific
guidance is inapplicable.

The two immediately preceding RISC-V promotions were reviewed in full. Run-wise
lifted quotient strength reduction cut deep proving to ratio 0.724575, then
worker-local grouping of equal quotient geometries cut the new frontier to
0.958426. That second session rejected serial compact-column materialization:
although instructions fell to 0.749x, main-thread plan construction lengthened
the critical path and did not improve verified proving time. The next profile
must therefore start from current main and must not simply repeat quotient
materialization.

A later unsubmitted experiment proposed deferring streaming Merkle leaf hashing
until all already-retained columns were available, exposing four-message SIMD
hashing and removing per-leaf incremental state. Its source remains isolated in
an older dirty worktree and is treated as a hypothesis/dead end, not inherited
code. This session will first reproduce the current-main large-row profile and
measure whether Merkle ingestion, memory movement, quotient execution, or a new
stage now dominates after PR #83's additional CPU batching and SIMD work.

## Fresh current-main baseline and profile

All seven `riscv/deep` programs were run from the clean ReleaseFast main binary
with one verified warmup and one timed sample. Request / proving seconds were:
xorshift 1.445/1.353, Fibonacci 1.586/1.487, GCD 1.504/1.395,
multi-shard 1.564/1.464, SHA2-512 2.138/1.636, SHA2-1024 2.412/1.928,
and SHA2-2048 2.792/2.140. Every artifact verified and its digest was retained
in the external session evidence directory.

A fresh three-second macOS sample of SHA2-2048 changed the priority relative to
the previous epoch. Useful top frames were four-message BLAKE2s compression
845 samples, packed incremental leaf ingestion 774, `memmove` 738, quotient
tile execution 600, scalar/SIMD BLAKE2s 381, batch inversion 251, and direct
batched leaves 126. Merkle leaf work is now the largest cluster by a wide
margin; quotient work remains material but no longer deserves the first edit.

The prior deferred-commit candidate is being reconsidered only because its
premise changed after PR #83. The merged branch added direct equal-height
column-layout hashing, which eliminates the row-message repacking cost that
made the earlier plain deferred builder unattractive. The updated problem-match
and Metal compute design briefs were written before editing. The predicted
signature is simultaneous removal of the large per-leaf incremental-state
array, collapse of packed-update/scalar-finalize frames, preservation of the
required four-message compression work, and at least an 8% SHA2-2048 proving
win. A sub-3% result or any correctness/resource regression rejects it.

## Deferred-all-columns experiment rejected

The minimal candidate removed the `StreamingTreeBuilder`'s duplicate leaf-state
array, retained batch-wise column preparation, restored original PCS order, and
invoked the backend's normal commitment once. The complete ReleaseFast test
root passed its 372-source closure before measurement.

The first verified SHA2-2048 screen decisively falsified the performance model.
Request time regressed from 2.791643 s to 3.407045 s and proving from
2.140442 s to 2.714156 s. Across one warmup and one sample, retired
instructions rose from 258.44 billion to 444.51 billion and cycles from
83.00 billion to 175.21 billion. Peak physical footprint was essentially
unchanged (1.570 GB to 1.576 GB), so the predicted state-memory benefit did
not materialize at the process peak. Statement and transcript digests remained
exact, but the benchmark artifact identity changed and would require separate
proof-byte investigation if the candidate had survived performance screening.

The inferred equal-height premise was wrong for the complete commitment. The
RISC-V trees mix column heights, causing the backend to use its mixed-height
message-packing path; reconstructing every complete 895/444-column leaf message
costs far more than preserving incremental state across the 64-column batches.
This explains why PR #83's direct equal-height path did not rescue the old
architecture. The source change was reverted with `apply_patch`, formatted,
and checked byte-for-byte against current main. The test and measurement remain
in the transcript as a rejected architecture.

## Height-grouped incremental fusion candidate

A temporary read-only shape diagnostic on the restored streaming path showed
why a narrower loop interchange remains promising. The SHA2-2048 commitment
has groups from log 5 through log 21, hundreds of columns around log 16, but
only one log-19, one log-20, and two log-21 columns. Preparation emits many
64-column batches at the same log size. The current builder therefore schedules
and scans the same leaf-state array repeatedly even though it retains every
extended column until decommitment. The diagnostic log was removed before the
candidate edit.

The revised candidate does **not** call the generic mixed-height Merkle builder.
It keeps the existing lifted incremental state expansion and exact byte stream,
but delays `StreamingCommitter.addColumns` until `commit`, sorts all retained
column references once, and feeds the committer once. Columns of equal height
are consequently processed as a single group instead of one group per
preparation batch. Interpolation and extension stay bounded at 64 columns;
ownership, original PCS ordering, transcript mix order, final leaf semantics,
and the standalone streaming-committer API are unchanged.

This is batch fusion/loop interchange rather than a cryptographic change. Its
predicted signature is fewer worker-pool barriers and scratch allocations,
especially at log 16, with the same number of BLAKE2s payload bytes and the
same canonical proof. A meaningful large-row win without a small-row or memory
regression promotes it; a sub-1% result or digest/parity failure rejects it.

The complete ReleaseFast closure passed, but the first large-row measurement
made the decision unambiguous. SHA2-2048 request ratio was 1.004166, proving
ratio 0.999535, retired-instruction ratio 1.001727, cycle ratio 1.013827, and
peak-footprint ratio 1.000063 versus the fresh current-main sample. Statement
and transcript digests matched exactly. The artifact envelope digest was the
same candidate-build identity observed in the earlier rejected experiment, so
it is not being treated as a canonical-proof mismatch.

The predicted scheduling gain does not exist at end-to-end scale: merging the
same-height batches does not reduce the dominant BLAKE2s payload or persistent
state traffic enough to measure. This candidate was rejected under its stated
sub-1% falsifier and reverted with `apply_patch`. The next architecture must
remove the million-entry sparse-tail state expansion or vectorize continuation
of independent leaf hashers, not merely reschedule it.

## Sparse tail and four-message incremental architecture

The sparse-terminal-block path passed the full 372-source ReleaseFast closure.
Its first scalar-tail screen was nearly neutral, showing that expansion removal
alone was insufficient. Adding four-message SIMD finalization made the same
SHA2-2048 request 0.979452x and proving 0.986919x current main, with instruction
ratio 0.987590, cycle ratio 0.984358, and energy ratio 0.976789. This retained
exact statement and transcript digests and established the terminal-block
equivalence, but still left the profiled dense incremental ingestion untouched.

The next stacked change generalized four-message SIMD from one-shot leaves to
four independent in-progress BLAKE2s states. A differential unit fixture now
covers distinct prefixes, distinct 257-byte updates, partial buffers, distinct
20-byte final tails, and scalar-equivalent digests. The first row-packed
version improved SHA2-2048 proving to 0.955130x and request to 0.967578x, with
cycles at 0.909943x and energy at 0.931985x.

Finally, the update path was fused directly with equal-height column-major M31
storage. Four adjacent rows are already the vector lanes required by the
four-message compressor, so complete 16-word blocks no longer pass through the
256 KiB-per-worker row-major staging tile. Partial buffered words retain the
same little-endian encoding and terminal-full-block rule. This is structurally
admitted by hasher capability and adjacent equal-height columns; scalar and
big-endian implementations retain exact fallbacks.

The first complete SHA2-2048 screen is large: verified request fell from
2.791643 s to 2.434196 s, ratio 0.871958 (1.147x throughput); instructions to
0.951499, cycles to 0.842603, and energy to 0.899145. Peak footprint was flat at
0.999697x. The reported witness substage fell from 0.544390 s to 0.193482 s,
while `prove_ms` returned to 0.999527x, because deferring the complete-shape
leaf pass moves Merkle work across the recorder's preparation/commit labels.
The verified request boundary, retired work, and energy all demonstrate a real
end-to-end gain; `prove_ms` is diagnostic and is not used as the verdict.
Statement and transcript digests remain exact. The artifact-envelope digest is
stable across all dirty candidate builds and differs from main's clean-build
envelope, so canonical proof bytes will be compared from frozen proof outputs
rather than inferred from that build-labelled envelope hash.

## Complete portfolio screen and bottleneck transfer

The direct-column continuation was then screened once against current main on
all seven deep programs. Every row won verified request time, proving time,
retired instructions, cycles, and energy while remaining within 0.1% of the
baseline peak footprint. The request ratios were 0.9214 xorshift, 0.9314
Fibonacci, 0.9229 GCD, 0.9114 multi-shard, 0.9530 SHA2-512, 0.9591 SHA2-1024,
and 0.9503 SHA2-2048. The corresponding cycle ratios were 0.8768, 0.8629,
0.8579, 0.8617, 0.8628, 0.8690, and 0.8696. This broad signature rejected the
possibility that the first large-row win was a target-specific accident.

A new eight-second sample of the candidate confirmed the intended transfer:

```text
before                         after
packed leaf ingestion  774 ->   49 samples
four-way compression   845 -> 3359 samples
memmove                 738 -> 2180 samples
quotient executor       600 -> 1076 samples
direct batched leaves   126 ->  480 samples
```

Absolute counts are not directly comparable because sample duration and proof
progress differ, but stack ordering is. Packed incremental ingestion collapsed
from the leading cluster to background noise. Canonical four-message BLAKE2s
compression is now the largest remaining stage, followed by memory movement,
RISC-V LogUp evaluation, quotient execution, and circle FFT work. The profile
is retained at `evidence/direct-column-profile/process.sample.txt`, with its
machine-readable report beside it. A future epoch should attack compression
round scheduling or eliminate another copy; it should not add another builder
reschedule or restore row-major message packing.

The material dataflow change is:

```text
old: batches -> row-major staging -> per-leaf incremental states -> scalar/SIMD finish
new: retained columns -> four adjacent rows -> direct SIMD continuation -> sparse finish
```

The final implementation includes three differential fixtures: independent
four-stream prefixes plus 257-byte updates, distinct 20-byte terminal tails,
and direct column-major continuation versus four scalar streams. A focused PCS
test forces the sparse terminal path and compares its root with the fully
materialized generic path. Scalar and big-endian fallbacks remain unchanged.

## Source-policy correction before the frozen run

The first immutable candidate, `8404000`, passed the seven-row paired benchmark
with a 0.9367 portfolio ratio and all proof/oracle gates, but failed G2 because
its specialization had been placed in two locked generic VCS wrapper files.
That run is retained under `evidence/official-first-8404000-run`; it is not the
submission verdict. The failure exposed a packaging error, not a benchmark or
correctness failure.

The specialization was moved into the editable lifted-prover adapter
`src/prover/vcs_lifted/blake2_stream4.zig`. The locked wrapper files were
restored byte-for-byte from `main`, and the candidate was amended to the clean
commit `f6ef4dd0bcd5165d767b9e81d754347b7f40ffdf`. Only MANIFEST-approved core
crypto, PCS, and lifted-prover paths differ from its predecessor. The complete
ReleaseFast closure then passed with 374 transitive Zig sources and no new
source-conformance findings.

## Frozen paired verdict

The final local S3 run paired clean candidate `f6ef4dd0bcd5` against clean
current-main predecessor `e6e86b072604`, using the refreshed harness
`083877c03a81`. It ran the full seven-program RISC-V deep portfolio, continued
the two noisier SHA2 rows to five rounds, and accepted every gate:

| workload | proving ratio | 95% CI | verified-request ratio | rounds |
| --- | ---: | ---: | ---: | ---: |
| xorshift | 0.9091 | [0.9048, 0.9127] | 0.9160 | 3 |
| Fibonacci | 0.9392 | [0.9348, 0.9445] | 0.9429 | 3 |
| GCD | 0.9336 | [0.9296, 0.9367] | 0.9379 | 3 |
| multi-shard | 0.9107 | [0.9078, 0.9190] | 0.9140 | 3 |
| SHA2-512 | 0.9302 | [0.9173, 0.9484] | 0.9484 | 5 |
| SHA2-1024 | 0.9426 | [0.9360, 0.9503] | 0.9492 | 5 |
| SHA2-2048 | 0.9469 | [0.9415, 0.9506] | 0.9579 | 3 |

The geometric-mean proving ratio is 0.930236 with portfolio 95% CI
[0.927643, 0.933370], a statistically significant 7.0% latency reduction.
Geometric-mean energy ratio is 0.907941 (9.2% lower), peak-RSS ratio is
1.000545, and proof-byte ratio is exactly 1.0. Every timed sample verified,
candidate and predecessor proof digests were byte-identical per round, the
pinned Stark-V correctness oracle accepted all 7 workloads, and mechanism
telemetry remained canonical. This is a local claimed verdict; only the
authenticated judge rerun can promote it.

The shared change also passed `test-riscv-cpu-product`,
`test-native-cpu-product`, device-only `test-native-metal`, `fmt`,
`source-conformance`, and the full ReleaseFast test root. Native Metal reported
no CPU fallback and completed independent verification. The local harness's
automatic Native guard mapping is currently malformed for this RISC-V board,
so the objective was run with `--guards none` and the three product boundaries
were executed explicitly and sequentially instead of being silently omitted.

## Decision and remaining work

Promote. The implementation generalizes over BLAKE2s message structure and
equal-height column layout, not workload names, sizes, or input digests. It
removes a profiled architectural bottleneck across the complete deep portfolio,
passes exact proof/oracle checks, saves energy, and does not materially increase
memory. The remote locked judge remains authoritative for the final verdict.

This submission improves the repository's RISC-V product but does not complete
the separate all-cell PR6 objective: its exact workload ports, log22 vectors,
two timing boundaries, and locked-M5 judged matrix remain incomplete.

**PR6 Supremacy: not achieved.**
