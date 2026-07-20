# CPU prover optimization session

## Objective and constraints

The objective is to reduce end-to-end prove time on the fixed `core_cpu`
small, wide, and deep workloads while preserving byte-identical proofs. The
clean main checkout is the paired predecessor. Only paths listed as editable in
`autoresearch/MANIFEST.json` may change; the harness, tests, vectors, build
files, and conformance record remain untouched.

The initial workspace and predecessor started at commit `b275053b9c42`. Zig
0.15.2 and Python 3.12.12 are installed. `stwo-perf setup` built the native
bench target successfully. An unchanged-tree S1-labelled harness run on the
small workload produced ratio 0.9842 with 95% CI [0.9469, 1.0225], correctly
showing no significant difference and giving a noise reference.

## Search strategy

Before editing, inspect the merged research record and live stage profiles.
The repository already contains several July 20 optimization submissions, so
starting from generic ideas risks duplicating work or undoing a deliberate
tradeoff. Three read-only investigations cover: prior attempts and durable
notes; exact editable-code opportunities; and live benchmark/stage evidence.

The first candidate will be selected only when a concrete repeated cost maps
to a proof-byte-preserving transformation. Algorithm replacement is out of
scope unless evidence points there; if it does, the separate algorithm-mapping
gate must be applied first.

## Fresh profiling evidence

Seven-sample diagnostic profiles on current main put the largest common stage
at FRI quotient build plus commitment: roughly 0.8 ms small, 5.7-7.3 ms wide,
and 4.4-4.7 ms deep in stable profiled samples. The earlier submissions already
attacked quotient accumulation and Merkle construction. Their retained probes
attribute about 0.74 ms to initial circle folding and 0.62 ms to line folds on
wide/deep before the latest downstream gains, leaving folding as the largest
explicitly deferred part of that aggregate.

A live `stwo-prof` harness called the repository's one-step line fold over
16,384 secure-field values. It measured 45.33 ns per output row, 762.2
instructions per output row, 179.6 cycles per output row, and IPC 4.24. The
high IPC indicates compute throughput rather than a serial dependency wall.
Each output row is independent, but the source performs four scalar M31 limbs
through a secure-field butterfly and multiplication. This is a direct-product
SIMD opportunity: place four independent rows into native M31 lanes while
keeping every row's field-operation order unchanged.

The selected candidate packs the line-fold arithmetic and, if the same helper
fits cleanly, the circle-to-line arithmetic. Domain point generation and batch
inversion remain unchanged. Scalar tails retain the exact old code. Prediction:
cut fold arithmetic instructions by at least 35%, reduce wide/deep proving by
2-6%, and preserve proof bytes. Falsifiers are any differential test failure,
missing packed ARM64 code generation, or an S3 confidence interval reaching
1.0. This is a representation-level constant-factor transfer, not an algorithm
replacement, so the algorithm-mapping gate is not invoked.

## Packed-fold result and rejection

The focused core suite passed after integrating four-lane line and circle fold
arithmetic. Code generation showed the intended ARM64 widening multiplies,
lane recombination, packed reductions, and four-coordinate stores. The live
whole-fold A/B (including unchanged domain generation and batch inversion)
improved from 46.076 to 41.477 ns per output row: wall ratio 0.8970 with 95%
CI [0.8739, 0.9105], instruction ratio 0.8164, and cycle ratio 0.9048. NEON
share in the inlined workload rose from 15.5% to 45.2%.

This verified the representation transfer, but the end-to-end falsifier did
not pass. Seven-sample unpaired diagnostics were noisy: wide was favorable at
0.982 while small regressed and deep's predecessor was externally disturbed.
The required S3 wide run was neutral/regressed at ratio 1.0502 with 95% CI
[0.9184, 1.2793]. Proof hashes stayed exact, but the confidence interval spans
1.0 by a wide margin. The arithmetic is now too small relative to coordinate
generation and batch inversion to justify shipping 230 additional lines.
Reject and revert this candidate; retain its counter evidence as the reason a
future fold attempt should remove repeated domain-coordinate inversion rather
than add more arithmetic SIMD.

The next experiment targets a simpler measured waste in composition
accumulation. `finalize` allocates and zeroes a new maximum-domain secure
column, then adds an already-owned maximum-domain bucket across every row.
Moving that bucket into the result preserves every field value and eliminates
the allocation, memset, and full add pass. The new-bucket branch also zeroes a
column immediately overwritten row-for-row, so uninitialized allocation is
equivalent. This targets wide's roughly 2.7 ms composition stage with a much
smaller correctness surface.

## Composition ownership result and rejection

The ownership-transfer candidate and overwrite-without-zeroing change passed
the 152-source ReleaseFast prover closure. Its S3 wide result was ratio 1.0107
with 95% CI [0.9761, 1.0395], 13.093 ms predecessor versus 13.069 ms candidate.
The tiny median movement and interval spanning 1.0 show that the eliminated
allocation and add pass are below the full-proof noise floor. Revert rather
than bundle a neutral micro-optimization.

Fresh stack attribution instead exposed a batching cliff in the circle FFT
orchestration. A same-size group is divided only by a 256 KiB cache target.
Four large secure-coordinate columns therefore form one work item and run
sequentially, even though the resident pool has up to 16 workers. This repeats
in interpolation and extended-domain evaluation for composition commits and
the four-column Plonk traces. The next candidate caps the cache batch by the
group's fair per-worker column share only for large CPU domains. Backend-owned
batch implementations stay untouched, and small domains retain the existing
cache batch to avoid task overhead. Prediction: 20-50% faster affected FFT
stages and at least 2% end-to-end improvement on deep or wide; falsifier is a
paired CI reaching 1.0 or any proof-byte change.

## FFT batching result and follow-on experiments

The FFT task split passed the prover test closure and preserved proof hashes.
On deep, S3 reported ratio 0.9680 with 95% CI [0.9396, 0.9980], narrowly
missing the acceptance rule that the upper bound must be below 0.99. Wide was
neutral at 1.0191 [0.9938, 1.0755]. The deep direction is credible but cannot
be submitted from this evidence.

The locked Plonk workload also materializes a constant composition column.
The next candidate detects a constant secure column before allocating an
evaluation accumulator and folds its weighted value directly into the scalar
constant bucket. Alternating stage profiles showed composition evaluation at
about 0.16-0.255 ms versus 0.54-0.607 ms on the predecessor. A workers-4 deep
S3 run with the FFT split reported ratio 0.9294 [0.9054, 1.0363]; heavy host
contention widened the interval beyond acceptance.

A third small candidate replaced the quotient path's duplicate serial CM31
batch inversion with the shared four-chain implementation. The combined
workers-4 deep run was neutral at 0.9981 [0.8885, 1.0939]. This does not show
that the inversion change helps, so it must be independently ablated before
retention.

The Apple host was under sustained unrelated load during these measurements:
load averages near 10 on 12 logical cores, with security and display daemons
regularly consuming multiple cores. No user or system processes were stopped.
Existing idle Runpod CPU workers are therefore used only for correctness,
code-generation inspection, and stable candidate ranking. Linux timing cannot
establish an Apple leaderboard claim; any retained candidate still requires a
fresh paired Apple S3 verdict.

## Conjugate quotient-domain point experiment

Bit reversal maps consecutive even/odd positions to domain indices separated
by half the domain. Those two circle points are conjugates. A separate clean
worktree therefore materializes the first point once and derives the second by
conjugation in the three large batched quotient paths. Differential tests cover
odd starts, tails, several domain sizes, and invalid shapes; the full prover
closure passes. A loaded-host workers-4 deep S3 run was favorable at ratio
0.9811 [0.9447, 1.0138], but the interval crosses the acceptance boundary.
The candidate remains diagnostic until an independent CPU lane ranks it and a
fresh Apple run confirms it.

## Final candidate selection and verification

The generic CM31 batch-inversion change was removed from the live candidate.
Its addition moved the workers-4 deep median from a favorable 0.9294 ratio to
0.9981 under comparable noisy conditions, and no independent evidence showed
an offsetting stage gain. Keeping an unproven third mechanism would weaken both
the result and its attribution.

With only CPU FFT task splitting and constant-column folding, a fresh paired
S3 deep run cleared the acceptance rule at ratio 0.9105 with 95% CI
[0.8887, 0.9408]. Focused unit tests were then added for the scheduling math
and the constant/nonconstant accumulator paths. Because test declarations
changed the candidate digest, the acceptance run was repeated. The final bound
verdict is ratio 0.9238 [0.9051, 0.9385] across 15 rounds, 10.591 ms
predecessor versus 9.779 ms candidate. Every timed proof verified and remained
byte-identical.

ABBA profiled diagnostics attribute the improvement to both intended paths.
Preprocessed and main-trace interpolation moved from 0.229-0.233 ms to
0.080-0.125 ms; their extended-domain evaluation moved from 0.274-0.277 ms to
0.174-0.203 ms. Composition evaluation moved from 0.490-0.515 ms to
0.150-0.165 ms. The proof hash stayed
`d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`.

Regression rows did not show a significant slowdown: wide was 1.0025
[0.9944, 1.0178], and small was 0.9605 [0.8465, 1.1781]. A default-worker deep
replicate kept a favorable 0.9434 median ratio but its interval
[0.9011, 1.0183] crossed the significance threshold under sustained host load.
The claimed verdict therefore records the explicit four-worker isolation used
for the two significant replicates.

Final verification includes `stwo-perf setup`, the ReleaseFast core and prover
closures, the native CPU product closure, and downstream-package smoke tests.
The prover and native CPU closures covered 152 and 190 transitive Zig sources.

## Upstream refresh and final bound verdict

The first local package detected that upstream had advanced by ten commits.
The canonical checkout was fast-forwarded from `b275053b9c42` to
`5d2eb59b2f9d`, including the newly promoted linear FRI coset walk. The source
candidate rebased without conflict to `c7a214981b03`. The refreshed harness's
`sync` command currently raises a missing-argument error inside its frontier
view call, but no bypass was needed: rebasing the linked workspace brought in
the complete updated policy and source tree directly.

All setup and closure gates were repeated against the refreshed predecessor.
The four-worker S3 deep replicate improved to ratio 0.8943 with 95% CI
[0.8668, 0.9225], 10.051 ms predecessor versus 9.078 ms candidate. A final
default-worker run independently cleared the gate at 0.9097
[0.8759, 0.9340], 9.269 ms versus 8.738 ms, and becomes the claimed verdict.
Updated ABBA profiles showed preprocessed and main interpolation at
0.230-0.245 ms versus 0.077-0.134 ms, extended evaluation at 0.279-0.315 ms
versus 0.168-0.231 ms, and composition evaluation at 0.501-0.523 ms versus
0.162 ms.
Updated regression rows were wide 1.0298 [0.9915, 1.0895] and small 1.0097
[0.9664, 1.0381]; neither was significant and both medians remain inside the
5% matrix-row budget. The stale pre-refresh package is discarded, and only the
refreshed verdict is eligible for the final package.
