# Admit packed recurrence composition in the latency regime

## Model and harness

Model: GPT-5 Codex. Harness: repository-resident `stwo-perf` at identity
`8b24d0b2eb96`, Zig 0.15.2 ReleaseFast, on the same arm64 macOS M5 Max host.
The clean candidate is `932aa7d2458b`; the paired predecessor is current main
`4259c8486593`. The claimed board is Native CPU `wide/time` at S3. The final
diff changes only `src/backends/cpu_scalar/secure_composition.zig`.

The session began by measuring the fixed-protocol width-100 series at logs 14,
16, 18, 20, and 22, then profiling CPU logs 14/18/22 and Metal logs
14/16/18/22. The final scored experiment used seven ABBA rounds, retained all
samples, independently verified every proof, and passed the pinned Rust Stwo
oracle.

## Hypothesis

The CPU backend already has a proof-wide execution plan for structurally
identified quadratic sum-of-squares recurrence AIRs. It traverses contiguous
trace columns directly, evaluates two independent packed row groups, reuses
squares across adjacent recurrence constraints, pre-packs secure powers, and
partitions rows across the persistent worker pool. Its old admission threshold
excluded the latency regime even though profiling showed generic component
evaluation consuming about 4.18 ms at width 100, log14.

The hypothesis was that a 2^15 evaluation domain and at least 32 contiguous
recurrence columns are sufficient to amortize worker fan-out. Admission remains
structural: one declared recurrence capability, one trace tree, exact
constraint/column relationship, uniform domains, contiguous storage, and
power-of-two packed rows. It does not inspect a workload name, benchmark size,
input, or digest.

## Changes

Lower the packed recurrence plan's evaluation-domain threshold from log17 to
log15 and express a minimum of 32 structurally matched columns. No arithmetic,
statement, trace, transcript, PCS, FRI, security parameter, proof encoding, or
fallback behavior changes.

Several broader experiments were deliberately removed before submission. A
CPU commitment-input ownership transfer screened favorably for request time
and some RSS points but produced a clean paired xlarge prove ratio of 1.0147
with CI [1.0003, 1.0294]. Metal combined/deferred admission at log14/16,
smaller transform tiles, and a split recurrence/IFFT command all lost to the
existing small-shape plan. Static contiguous CPU column ranges improved log14
but regressed log16 because heterogeneous-core load balancing was worse. The
submitted diff contains none of those rejected mechanisms.

## Results

The scored `wf_log14x32` prove median falls from 6.286708 ms to 4.960083 ms:
ratio **0.791173**, 95% CI **[0.783665, 0.801629]**. Verified-request ratio is
0.807709. Energy ratio is 0.943872 with upper CI 0.948983; RSS ratio is
0.998743 with upper CI 1.000721. Proof size is exactly unchanged at 41,840
bytes.

All G1-G5 checks pass. Every timed proof verified, cross-arm proof digests
were byte-identical in every round, and the pinned Rust oracle accepted the
scored proof. All 13 impact-mapped guards pass, covering wide Fibonacci,
Blake, Plonk, Poseidon, state machine, and XOR. The separate holistic smoke
also produced identical CPU/Metal canonical bytes for all 13 rows. Native CPU
product closure, prover closure, and source-conformance checks pass.

For the task's width-100 log14 point, the clean candidate records 7.436208 ms
verified request versus the frozen 10.876250 ms baseline, ratio 0.683711,
with seven identical verified 48,180-byte proofs. This is useful portfolio
evidence, but it is not substituted for the manifest-owned scored verdict.

## Caveats

This submission advances one latency/wide cell; it does not by itself satisfy
the system-level 2x contract. The diagnostic best-backend envelope across the
five fixed-protocol sizes reaches ratio 0.497667, but log16 remains at
0.937481 and therefore fails the per-cell ceiling. Cold-process ABBA evidence
and an automatic backend execution plan are also still outstanding.

The packed plan intentionally stays off traces with fewer than 32 columns or
without the exact recurrence capability and layout. A future change should
derive the crossover from measured plan cost or a more general compiled
component plan rather than repeatedly lowering this constant. PR6's full
exact workload and cold-process matrix is still incomplete.

**PR6 Supremacy: not achieved.**
