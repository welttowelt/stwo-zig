# Session 01 — cache-skewed shared column arenas

## Objective and operating contract

The user requested the largest promotable improvement, with Metal as the
primary focus, and asked for CPU and Metal verdicts in one submission. The CLI
was updated before the search. Work began from canonical predecessor
`bca6540a3fbe`; the final source candidate is `715e37c89da6`, measured with
harness `a9bf238c4fdc`.

All five repository skills governed the search: algorithm matching, Zig
profiling, Metal profiling, Metal performance design (including the complete
common-patterns reference), and submission transcripts. Prior notes and
submissions were reviewed before choosing a new direction. The relevant prior
work had already reduced Metal LDE and Merkle costs, which made the remaining
host composition discrepancy conspicuous.

## Problem-match brief

```text
Task and required semantics:
  Store fixed M31 evaluation columns so row-wise AIR evaluation and Metal
  commitment/opening remain bit-exact. No row, column, transcript, or proof
  ordering may change.

Inputs, measured scale, and model:
  Wide Fibonacci at log18/log20, 100 base columns, one-bit blowup. Logical
  columns are column-major; the evaluator accesses one row across all columns.
  Cost model is cache/TLB transfers plus Metal shared-memory upload traffic.

Constraints and structure:
  Every public column must remain an ordinary contiguous slice. Merkle leaves,
  FRI quotient views, and decommitment use the same logical indices. Proofs
  must be byte-identical and Metal must not fall back to CPU.

Candidate matches:
  (1) cache-conflict avoidance by array padding/skew — exact layout transform;
  (2) row-major transpose — exact but breaks column-slice consumers;
  (3) evaluator tiling — exact but requires locked AIR/vtable changes;
  (4) gather/repack before composition — exact but adds a full memory pass.

Chosen canonical variant:
  Conflict-avoiding padding of simultaneous power-of-two-stride streams.

Project mapping and recovery:
  Add one cache line between physical columns, expose only the original
  2^log logical slice, and carry backing/stride metadata only at backend
  boundaries. Logical solution recovery is the identity mapping.

Complexity and prediction:
  Work remains O(rows * columns); storage adds 64 * (columns - 1) bytes per
  same-log group. Prediction: composition time falls sharply at 100 columns,
  while <=64-column guards remain neutral. Falsifiers are changed proof bytes,
  guard regressions, or a composition stage that does not move.
```

This was a layout/I/O specialization rather than a new asymptotic algorithm.
The transpose and tiled-evaluator alternatives were rejected because they
crossed locked semantic interfaces; padding preserved every public consumer.

## Grounding profiles and discovery

Fresh exact-predecessor profiles established the useful stage picture:

| product / xlarge stage | approximate predecessor time |
| --- | ---: |
| CPU complete prove | 206 ms |
| CPU composition evaluation | 111 ms |
| Metal complete prove | 408 ms |
| Metal main-trace commitment | 27 ms |
| Metal composition evaluation | 344 ms |

The Metal product was therefore not dominated by a Metal kernel. Its host AIR
evaluator took roughly three times the CPU product's time. Sampling and codegen
inspection did not support an arithmetic/code-generation explanation. Mapping
addresses exposed the exact physical geometry: after one-bit blowup, each
log18 column occupies 2 MiB, and the row-wise evaluator touches 100 addresses
whose low address/index bits repeat.

```text
before
  col0 + r*4
  col1 + r*4 = col0 + 2 MiB + r*4
  ...
  col99 + r*4

after
  physical stride = 2 MiB + 64 B
  logical slice length remains exactly 2 MiB
  each next stream rotates by one cache line
```

A 64-byte skew reduced Metal xlarge composition from roughly 344 ms to about
90 ms. CPU xlarge also moved from roughly 206 ms complete prove into the
mid-160 ms range. This confirmed a memory-layout bottleneck rather than a
shader-throughput bottleneck.

## Architecture and ownership proof

The Metal design brief classified the workload as compute-only on an Apple M5
Max with unified memory and Metal source-JIT runtime compilation. The unit of
work remained one independently verified proof. The resource plan became:

| resource | producer | consumers | lifetime / storage |
| --- | --- | --- | --- |
| base values / coefficients | trace + inverse circle FFT | sampled-value evaluation | independently releasable host/shared allocation |
| skewed extended evaluations | circle LDE | Merkle, composition, quotient, decommit | page-rounded retained shared arena |
| logical column slices | arena metadata | all prover code | borrowed, original length only |
| Merkle hash arena | Metal leaves/parents | root + openings | resident tree lifetime |

The command/data flow is:

```text
owned base columns
    -> Metal inverse FFT in coefficient storage
    -> sparse fused scale/expand/top-two kernel
    -> offset-aware forward FFT into skewed evaluation arena
    -> backing-aware Merkle leaves (no dense repack)
    -> host row-wise composition on logical slices
    -> raw FRI quotient upload through page-envelope aliases
```

The LDE API carries explicit evaluation backing, start, and stride. Sparse
offset kernels preserve the existing fused one-bit expansion. The generic
commitment tree optionally passes the retained backing to Metal; runtime range
validation proves every logical slice lies within it. The Metal buffer aliases
only the page envelope covering live evaluation columns. Command completion is
still synchronous at the existing API boundary, so host ownership cannot end
before GPU use. Core shader ABI 7 rejects stale authenticated bundles.

CPU uses the same layout insight with a narrower policy. It transforms owned
coefficient buffers in place, allocates only the skewed extended backing, and
selects the combined route only for 65--256 columns. A temporary wider policy
showed that Blake/Poseidon feed repeated 64-column chunks; the 65-column lower
bound keeps those guards on the predecessor path while covering the scored
100-column workload.

## Resource-gate failure and the decisive second diagnosis

The first complete Metal xlarge verdict was a 57.5% time improvement but failed
G4 by only 0.255 percentage points: peak RSS was 674.689 MiB, ratio 1.304851
against a 1.25 budget. The first hypothesis blamed a full 300 MiB backing alias.
The Merkle alias was narrowed to the page-rounded live column range. A second
hypothesis separated coefficient and evaluation storage so dead coefficient
pages could be released independently. Neither explained the measured peak by
itself.

A temporary lifetime-peak probe was then placed after each proof stage. With
the correct explicit Native Metal build target, it reported:

```text
prepared input                 114 MiB
main trace committed           234 MiB
composition evaluated          372 MiB
composition committed          438 MiB
sampled values mixed           438 MiB
FRI quotient committed         663 MiB  <-- jump
```

Inspection of the raw quotient uploader supplied the missing mechanism. It
groups physically adjacent input columns and uses `newBufferWithBytesNoCopy`
only for page-aligned runs. The 64-byte skew intentionally made 99 of 100
column starts non-page-aligned, so each became a separate 2 MiB copy. That is
approximately the unexplained 198 MiB.

The final uploader rounds each source pointer down to its VM page, rounds the
covered end up, creates a shared no-copy buffer for that safe page envelope,
and binds the logical byte displacement. M31 alignment guarantees the binding
offset is valid; the shader continues to see offset zero for the logical
column. Non-unified devices retain the copy path. After this change:

```text
FRI quotient committed         515.3 MiB
complete proof peak            515.8 MiB
predecessor direct diagnostic  516.4 MiB
```

The final S3 Metal xlarge verdict measured 516.923 MiB, ratio 0.999577, while
retaining the composition speedup and zero fallbacks.

## Falsified and rejected experiments

- AArch64 code generation was inspected first; it did not explain the
  CPU/Metal-host composition gap.
- Argument-buffer, fixed-buffer gather, scalar-M31, QoS, delay, and spin
  variants did not produce a stable complete-proof improvement.
- Narrowing only the Merkle alias was insufficient; the later FRI allocation
  was the actual peak.
- Marking dead coefficient pages reusable was explored and removed; it did not
  address the stage that established the lifetime maximum.
- Disabling the backing-aware Merkle route forced a dense repack and raised
  observed peak to about 760 MiB; it was immediately rejected.
- The first huge verdicts each caught one noisy unchanged small guard. CPU's
  failing guard had central ratio 1.0286 and Metal's 1.0121, with confidence
  bounds barely beyond 1.05. Clean sequential reruns passed all 13 guards; no
  source was changed between runs.

These dead ends were retained because they distinguish logical allocation
lifetime from Metal's hidden copy behavior and show why end-to-end resource
instrumentation was necessary.

## Final evidence

Candidate `715e37c89da6` versus predecessor `bca6540a3fbe`, harness
`a9bf238c4fdc`:

| board / class | A median | B median | paired R (95% CI) | result |
| --- | ---: | ---: | ---: | ---: |
| CPU xlarge | 216.379 ms | 166.644 ms | 0.770148 [0.764104, 0.773767] | 22.99% faster |
| CPU huge | 814.947 ms | 709.311 ms | 0.862618 [0.850738, 0.908437] | 13.74% faster |
| Metal xlarge | 407.538 ms | 160.480 ms | 0.390284 [0.380132, 0.397715] | 60.97% faster |
| Metal huge | 1396.273 ms | 609.984 ms | 0.454118 [0.402681, 0.559136] | 54.59% faster |

All four S3 verdicts pass G1--G5, all 13 regression guards, request-ratio
budgets, and named resource budgets. Proof bytes are unchanged. Every timed
proof verified and was byte-identical across the paired arms. Metal energy fell
to ratios 0.579504 and 0.636679 for xlarge and huge.

Validation passed the complete 361-source ReleaseFast test closure and the
Native Metal device-only prove, independent verification, product-marker, and
233-source closure suite. The final worktree was clean before `stwo-perf setup`
and every verdict is bound to the exact candidate commit.
