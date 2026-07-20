# Session 01 — post-Merkle architecture search

Model: GPT-5 Codex

## Objective and contract

The user requested the largest defensible CPU-prover improvement, explicitly
requiring the repository CLI to be updated first, prior notes/transcripts to be
used as research input, profilers and visualizations to guide architecture, and
submission as soon as a significant solution is verified.

The repo-resident updater fast-forwarded the clean primary checkout from
`95f32a8` to current `main` at `4dc26f0` before a candidate workspace was
created. The fixed suite is small wide-Fibonacci, wide wide-Fibonacci, and deep
Plonk. Acceptance requires paired S3 end-to-end evidence, byte-identical proof
outputs, and edits confined to the manifest's editable prover paths.

## Prior-research synthesis

All three promoted notes and reasoning-first transcripts were read before new
profiling. The combined frontier already includes:

- packed direct quotient accumulation using native four-row lanes;
- reuse of the resident prover work pool for Merkle construction;
- deeper pool scheduling with smaller Merkle layer tasks;
- four-way BLAKE2s leaf hashing throughout the FRI cascade;
- exact scratch sizing and removal of unused incremental hashers in that path.

Their reported current-frontier medians are 2.379 ms small, 17.321 ms wide,
and 8.521 ms deep, although the source improvements are combined on current
`main` and a fresh baseline must be measured. Earlier temporary attribution
split the formerly dominant FRI stage into approximately 0.9–1.0 ms lazy first
layer, 1.36 ms circle/line folds, and roughly 3 ms inner Merkle commitments on
wide/deep *before* the latest SIMD cascade optimization. Therefore the old
stage percentages cannot be reused as the new map.

## Architecture visualization and selection rule

```text
trace columns
    |
    +--> main/composition commitments ----+
    |                                     |
    +--> quotient tiles -> first FRI tree -+-> fold -> inner tree -> fold ...
                    packed/fused             ^         ^
                    frontier work             |         |
                                         candidate   frontier SIMD/pool work
                                         residual
```

The next candidate will be chosen from fresh current-main evidence. The
preferred target must (1) retain at least about 1% end-to-end headroom, (2)
affect more than one class if possible, (3) preserve exact transcript/hash
ordering, and (4) admit a clear mechanism check through counters, samples,
operation counts, or code generation. Repeating the now-optimized Merkle
threshold work, optimizing Metal, or editing benchmark/harness files is
rejected up front.

If profiling recommends an algorithm or data-layout replacement rather than a
mechanical constant-factor change, a complete canonical problem-match brief
will be written before editing.

## Fresh baseline and residual attribution

The current combined frontier was built and the complete fixed suite was run
locally with ten warmups and seven verified, unprofiled samples per workload.
Median prove times were 1.984 ms small, 12.509 ms wide, and 8.445 ms deep. All
seven proofs in each workload verified and were byte-identical; their SHA-256
identities matched the promoted research record.

Seven-sample diagnostic stage profiles produced this residual map:

```text
stage (median ms)             small   wide   deep
FRI quotient build + commit   0.815  3.858  3.816
composition evaluation        0.040  2.729  0.398
sampled-value evaluation      0.158  1.745  0.879
main-trace commit              0.279  1.898  1.119
proof of work                 0.267  0.242  0.260
```

FRI remains the largest common aggregate, but its already-optimized hash path
contains several mechanisms. Wide composition evaluation is large but belongs
to one example's single-component row/constraint traversal, whose source is
outside the editable submission surface. Sampled-value evaluation is both
suite-wide and editable.

## Packed direct-product sampled-value design

Source inspection showed that a sampled-value plan applies identical secure
point factors to many independent circle-basis coefficient polynomials. The
current batched helper changes loop order and shares factors, but invokes the
full scalar coefficient reduction for each polynomial. Existing thread
parallelism uses one worker per eight columns, leaving lane-level parallelism
inside each worker unused.

The selected transfer is a direct-product SIMD evaluation: keep every
polynomial's carry-style merge tree and arithmetic order unchanged, but place
independent polynomials in native M31 vector lanes. This is a constant-factor
representation transfer, not a replacement algorithm, so the algorithm-match
gate does not require an external canonical-algorithm brief. Correctness is
lane-wise equivalence to the existing scalar evaluator; batches with a partial
tail retain the scalar path.

```text
factor[level] ───────────────┬─────────────── shared
poly 0 coeff stream ── lane 0│
poly 1 coeff stream ── lane 1├─ packed QM31 merge tree ── four exact outputs
poly 2 coeff stream ── lane 2│
poly 3 coeff stream ── lane 3│
```

A scratch S1 harness wired to live current-repo modules evaluated 32 degree-
2^14 polynomials at one secure point. It included four deterministic
differential checks against the scalar helper before timing. Results:

- scalar: 11.67 ns/coefficient, 226.5 instructions, 53.62 cycles, IPC 4.225;
- packed: 4.342 ns/coefficient, 72.52 instructions, 19.96 cycles, IPC 3.633;
- ABBA packed/scalar wall ratio 0.3730, 95% CI [0.3674, 0.3738];
- instruction ratio 0.3201 and cycle ratio 0.3730.

The 2.68x kernel speedup supports an end-to-end prediction of roughly 0.5–1.2
ms on wide and 0.2–0.6 ms on deep, depending on plan overhead and concurrent
tree scheduling. The falsifier is a neutral/regressed sampled-value stage or
failure of the existing scalar-vs-batch property test. A threshold-only worker
granularity change is deferred because it cannot remove the measured scalar
instruction burden and may oversubscribe trees already running concurrently.

## Integration, codegen, and end-to-end outcome

The packed secure-field helpers were integrated privately at the point-
evaluation boundary, and `evalManyAtPointsWithFlatFactors` now groups complete
native-width polynomial batches while preserving its scalar tail. No protocol,
hashing, point-factor, or scheduler code changed. The existing batch-vs-scalar
test was changed from a fixed five polynomials to `native width + 1`, explicitly
covering both a full packed group and the tail on each target.

The ReleaseFast prover closure passed across 152 transitive Zig sources. Fresh
profiled stage medians confirmed the predicted mechanism:

```text
sampled-value stage (ms)      predecessor  candidate
small                              0.158      0.087
wide                               1.745      0.711
deep                               0.879      0.380
```

Every seven-sample unpaired candidate workload verified and preserved the
predecessor proof SHA-256. Live integrated arm64 disassembly showed packed
widening multiplies (`umull/umull2.2d`), lane recombination (`uzp1.4s`), vector
field reductions (`add/sub/cmhi.4s`), and a four-coordinate vector store
(`st4.4s`). This closes the codegen requirement rather than inferring SIMD from
source syntax.

The exact paired S3 results against unchanged current `main` were:

- small: ratio 0.9612, 95% CI [0.9441, 1.0006], 1.645 to 1.582 ms;
- wide: ratio 0.9181, 95% CI [0.9099, 0.9246], 12.573 to 11.524 ms;
- deep: ratio 0.9430, 95% CI [0.9345, 0.9498], 8.608 to 8.131 ms.

All runs used 15 paired rounds and passed G1–G5. Wide and deep are significant
beyond the 1% floor. Small's mechanism moved in the expected direction but its
end-to-end CI reaches 1.0, so it is attached as neutral evidence rather than
rounded into a win. The ReleaseFast native CPU product closure also passed
across 190 transitive sources.

## Rejected alternatives and stopping decision

- A pure worker-threshold sweep was rejected as the primary design because the
  S1 counters attributed most cost to scalar instructions, not idle dispatch,
  and existing sampled-value evaluation already overlaps trees and partitions
  the largest coefficient plan.
- Wide composition evaluation has more single-workload time, but its concrete
  recurrence traversal belongs to an example source outside the manifest's
  editable paths. Attempting to route around that boundary would invalidate the
  submission.
- Another Merkle threshold or BLAKE2 rewrite was rejected because the three
  promoted sessions already optimized that architecture and fresh attribution
  exposed sampled-value evaluation as the larger unclaimed common residual.
- A new global packed-QM31 public type was unnecessary. Keeping the lane type
  private to point evaluation minimizes API and correctness surface while still
  reusing the repository's tested packed M31 primitives.

The user required submission as soon as a significant solution existed. With
two class CIs clearing the threshold, all affected classes measured, exact
proof identity preserved, profiler/codegen mechanism evidence collected, and
both product closures green, the search stops here to package this checkpoint.
