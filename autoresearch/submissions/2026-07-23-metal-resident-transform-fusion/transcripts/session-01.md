# Autoresearch session 01 — explicit resident Metal transform epoch

## Objective and starting point

This epoch follows the merged RISC-V shared-prover work at main commit
`793c4ab69f7831f8ba8edefe12ce2fda6e6ba17a`. The user asked for the largest
possible Metal improvement, explicit architectural work rather than isolated
microbenchmarks, complete transcript retention, rapid submission after a
significant result, and continued optimization after promotion.

The repo-resident CLI was updated before work began. The repository's five
research skills were exercised: algorithm matching, Zig profiling, Metal
profiling, Metal performance design, and submission transcripts. Their binding
rules for this epoch were:

1. profile complete verified requests before selecting kernels;
2. optimize command boundaries, residency, layout, and work volume together;
3. reject a shader change when end-to-end counters do not move as predicted;
4. keep proof bytes and zero-fallback classification as first-class gates; and
5. preserve every useful failed experiment in the transcript.

The starting current-main wide-Fibonacci Metal medians were 22.826 ms at
log16, 38.080 ms at log18, 133.633 ms at log20, and 531.578 ms at log22. The
log20 proof was 86,383 bytes with canonical SHA-256
`e6609d0564a47192212bec7973e2660c2eea88bef90c573c3df09569cc3c7e86`.

## Profile map and architectural diagnosis

The log20 profile showed that the GPU was fast inside individual kernels but
the proof still crossed too many semantic and command boundaries:

```text
host recurrence generation
        |
        v
copy/upload -> inverse FFT -> normalize -> expand -> forward FFT -> Merkle
                                                       |
host-visible composition evaluation -> composition IFFT|
                                                       v
copy/reorder coefficients -> LDE -> second Merkle -> PCS openings
```

Before fusion, representative GPU/wait attribution was:

| Stage | Approximate time |
| --- | ---: |
| wide recurrence + IFFT | 3.9 ms GPU plus host boundary |
| inverse transform passes | 2.25 + 2.24 ms |
| expansion | 4.07 ms |
| forward passes and tail | 4.43 + 3.11 + 5.47 ms |
| trace Merkle | 7.14 ms |
| composition recurrence boundary | about 3.6 ms wait |
| separate composition IFFT | about 1.25 ms wait |
| composition combined commit | about 7.2 ms wait |

The revised topology is:

```text
explicit recurrence recipe
        |
        v
[generate + inverse FFT + normalize + expand + forward FFT + Merkle]
        |                     one trace commitment epoch
        v
[composition evaluate + composition inverse FFT]
        |                     one command, coefficient-form output
        v
[GPU reorder/blit + LDE + Merkle]
                              one coefficient commitment epoch
```

This diagnosis explained why Metal had historically remained close to CPU:
the GPU was repeatedly used as a collection of kernels while the proof
transaction retained CPU-shaped ownership and representation boundaries.

## Explicit producer ownership

The first architectural requirement was to avoid another invisible global
residency mechanism. Previous resident quotient work had shown that runtime-
wide address discovery can be lifetime-safe in one synchronous request but is
hard to reason about across simultaneous proofs, allocator reuse, mixed
resident trees, and runtime destruction.

`ColumnSource` therefore travels with the owned column transaction. Its
initial structural producer is a quadratic recurrence containing the exact
log size and seven-word recipe. A backend may consume the producer in a
combined device epoch or materialize it before a generic reader; ownership and
failure cleanup stay explicit. The frontend asks backend policy whether the
shape is admitted, so no workload name, input digest, benchmark size, or
statement special case exists.

An early integration mistake proved why this metadata must be part of
ownership. `OwnedColumns` reconstruction copied the slices and backing arena
but dropped the producer tag. The Metal epoch consequently consumed
zero-filled pages. Zig self-verification still produced a proof, but the
canonical digest changed to `a79b...` and size to 83,443 bytes. Carrying source
metadata through every take/rebuild operation restored the exact oracle-facing
proof. This failure is retained as a warning against side-channel metadata.

## Wide transform specialization

The transform experiments began with threadgroup tiling. Applying tile 12
globally helped the 100-column trace but regressed the much narrower secure
composition transform, so the policy became shape-specific: tile 12 only for
the structurally wide path. Tile 13 increased request time to roughly 134.8 ms
and was rejected. Tile 8 and tile 11 recurrence-fusion variants also lost
end-to-end time and were removed.

The accepted wide kernel:

- generates the quadratic recurrence directly into the shared base arena;
- performs the inverse transform in its commitment command buffer;
- fuses inverse normalization with the transform output;
- pre-scales deferred trace values so expansion fell from about 4.07 to 2.91
  ms; and
- uses Mersenne power-of-two rotation rather than general multiplication when
  the schedule allows it.

`m31_mul_pow2` is exact for canonical values modulo `2^31-1`. The policy is
structural and applies to non-target wide shapes admitted by the same size and
column constraints.

## Parallel polynomial basis and trace result

The initial coefficient basis work tried to feed a scalar group shape to a
`uint2` Metal kernel and source-JIT compilation failed. Correcting the group
shape and encoder layout produced the first large end-to-end step. The
explicit producer plus parallel basis stack reduced log20 from 133.633 ms to
about 119.469 ms.

The implementation then removed redundant encoder boundaries and kept the
entire trace transform and commitment in one epoch. The trace-generated flag
is reported through Metal telemetry; no CPU materialization or copyback is
permitted on the admitted path.

## Coefficient-form composition pipeline

The next profile showed that composition still flowed through a generic
evaluation-form API. A first implementation assumed four columns because a
QM31 value has four coordinates. That assumption was wrong: after the circle
split the commitment contains eight polynomials, left/right times four
coordinates. The generic path therefore remained active even though the new
code compiled and verified.

The corrected interface adds an explicit evaluations/coefficients state to
`SecureColumnByCoords`. Backends can interpolate in place, mark the state, and
return borrowed left/right coefficient slices. `commitPolys` now offers a
coefficient-form backend hook. Metal allocates its owned base/evaluation
arenas, blits the eight possibly non-contiguous split slices into logical
order, performs the forward LDE, and commits the Merkle tree in one command.

This layer moved log20 from about 119.469 to 114.742 ms. Borrowing composition
coefficients removed host copies and reduced the profile's composition
interpolation/split stage from about 4.608 to 1.777 ms, although an isolated
request screen was noisy at roughly 114.369 ms.

GPU coefficient upload/reorder then reached 111.615 ms, with about 3.231 J,
9.551 billion instructions, and 884 MiB peak physical footprint in the
comparable diagnostic batch. Pre-scaling reached 110.476 ms, and power-of-two
rotation reached 109.541 ms in a five-warmup/seven-sample screen.

## Fuse composition evaluation and inverse transform

Composition evaluation originally ended a command buffer, waited, and then
launched a separate circle inverse transform. Passing the already cached
twiddle tree into the backend lets the recurrence-composition shader encode
the inverse passes and rescale before the command commits.

The first fused implementation omitted the required Metal hazard ordering
between recurrence output and the inverse transform. Constraint verification
failed, correctly blocking it. The repaired implementation encodes both
operations in one ordered command and returns coefficient-form output.

The profile changed from eight command buffers per proof to seven and removed
the standalone circle-transform command. The fused recurrence/composition
command reported about 2.30 ms GPU time and 4.2 ms host wait in an instrumented
run. Composition interpolation became zero, evaluation was about 4.69 ms, and
the coefficient commitment about 8.55 ms. A profiled request measured 99.908
ms, but profiled time is not promotion evidence.

The first unprofiled five-warmup batch was about 1.1 ms slower, illustrating
normal thermal/noise sensitivity. The declared ten-warmup/seven-sample batch
was 109.656 ms, essentially neutral versus the immediately preceding 109.541
ms screen. The fusion was retained because it removes a synchronization point,
improves the cold/process architecture, and does not lose the complete request.

## Final diagnostic matrix

| Shape | Current main | Candidate | Relative change | Proof SHA-256 |
| --- | ---: | ---: | ---: | --- |
| `2^16 × 100` | 22.826 ms | 22.859 ms | -0.14% | canonical, unchanged |
| `2^18 × 100` | 38.080 ms | 29.328 ms | +22.98% | `f845...ced8f` |
| `2^20 × 100` | 133.633 ms | 109.656 ms | +17.94% | `e660...c7e86` |
| `2^22 × 100` | 531.578 ms | 431.382 ms | +18.85% | `2c0...76205` |

Log22 samples were 431.382, 445.198, and 410.759 ms, with about 2,710 MiB RSS
and 4.1 J in that diagnostic scope. Seven repeated log20 proofs were byte
identical. CPU log20 measured 275.335 ms versus 275.781 ms on main, so the
Metal speedup does not hide a CPU regression.

The independently reconstructed allowed-path scorer branch measured log20 at
112.133 ms with samples from 109.288 to 113.735 ms. That is 16.09% faster than
the 133.633 ms main diagnostic despite a different thermal interval. It
reported 29 Metal dispatches, zero CPU fallbacks, zero trace-generation
synchronizations, and the exact 86,383-byte proof.

## Resource and identity evidence

The comparable candidate resource screen indicated roughly 20% lower energy
and 19% fewer instructions than main. Candidate RSS was about 884 MiB versus
857 MiB, a 3.1% increase and below the 5% guard. Ten-warmup resource counters
are not compared directly with five-warmup batches because the report's
resource scope includes warmups.

The source-JIT runtime hashes the amalgamated Metal source and Objective-C
runtime closure. The core shader ABI changed from 8 to 9 because three exports
were added, taking the exact export count from 79 to 82. The runtime guard,
manifest tests, AOT mutation fixture, and probe authority were updated
fail-closed. This host uses `newLibraryWithSource`; full Xcode/offline `metal`
is absent. Warm request samples exclude startup JIT, while a true cold-process
comparison must include it.

## Correctness and test gates

The following passed on the candidate architecture:

- `zig build test native-proof-bench-metal -Doptimize=ReleaseFast -j2`;
- `zig build metal-check test-native-metal -Doptimize=ReleaseFast -j2`;
- `zig build test-metal-core-aot test-metal-core-aot-probe`;
- source-JIT compilation, device-only lifecycle, and independent verification;
- canonical proof parity at logs 16, 18, 20, and 22; and
- zero-fallback telemetry for every measured proof.

A forced coefficient-form combined LDE/Merkle differential test permutes the
left/right coordinate slices, compares every base and extended column against
the generic CPU transform, and compares the Merkle root. It passes. The full
candidate Metal suite reports 88/91 with one failure and two skips; current
main reports 87/90 with the identical inherited `resident FRI folds and
coordinate conversion match CPU` failure and two skips. The candidate thus
adds one passing test and introduces no new suite failure.

## Promotion-policy split

The first complete commit crossed generic transaction, example, test, and AOT
probe paths. Those are legitimate architecture changes but lie outside the
autoresearch scorer's editable surface. Running the board directly would have
discarded an otherwise valid result.

The work was split without donating performance:

1. PR #88 establishes explicit producer/representation metadata and generic
   hooks while preserving the previous Metal execution path. Its log20 check
   was 134.563 ms versus main 133.633 ms, within noise, with the same proof.
2. The scorer candidate changes only `src/backends/metal/**` and activates
   deferred trace generation, transform fusion, coefficient consumption, and
   shader ABI 9.

PR #88 initially failed only the 850-line source ceiling because `scheme.zig`
reached 890 lines. Coefficient-form orchestration was extracted into
`commit_polys.zig`, leaving the scheme at 849 lines. The exact local-compatible
static lane passed all 584 tests. The scorer candidate also preserved the
legacy 14-argument combined-LDE method and added a named prepared-source
method after the unchanged Metal test caller exposed that compatibility issue.

## Rejected ideas and negative evidence

- Global tile 12: rejected because the narrow composition transform regressed.
- Tile 13: rejected at roughly 134.8 ms request time.
- Tile 8/tile 11 recurrence fusion: rejected on end-to-end latency.
- Four-column composition commit: rejected after proving the split contains
  eight polynomials and observing the generic path still execute.
- Hidden runtime producer discovery: rejected in favor of explicit ownership
  metadata and fail-closed fallback materialization.
- Separate recurrence and inverse-transform commands without a hazard:
  rejected by constraint verification.
- Scalar group parameters for the basis kernel: rejected by Metal source-JIT
  type checking against the required `uint2` shape.
- Treating the first five-warmup fused screen as a regression: rejected after
  ten-warmup evidence showed neutrality and the command topology improved.
- Unsupported focused-bench flags (`--backend`, `--air`): corrected to the
  product's `bench --example ...` contract before retaining evidence.

## Remaining bottlenecks and next epoch

The trace transform and Merkle tree remain the dominant large-shape stages.
The strongest next hypotheses are multi-stage transform kernels that reduce
global-memory passes, deeper leaf preparation/Merkle overlap, and reducing
resident arena duplication at log22. These must be evaluated at log18/log20
and non-target holdout widths; log16 is already overhead-bound and should
remain neutral rather than force a broad policy.

## Final clean paired verdicts

The behavior-neutral foundation merged as PR #88 at main commit
`7c9e2e227ffeead687ff69571ac6988fc3e79da9`. Candidate
`7d74040be699` has that exact tree as its A arm and changes only 17 files under
`src/backends/metal/**`. Harness identity is `539175a491e8`.

The `core_metal/xlarge/time` verdict used five paired rounds. Prove ratio was
**0.939090**, 95% CI **[0.932279, 0.944266]**, from 31.873083 to 30.163896 ms.
Verified-request ratio was **0.848259**. Energy ratio was **0.841451** with
upper CI 0.870620; RSS ratio 1.005638 with upper CI 1.005783; proof bytes were
unchanged at 74,328. G1-G5 and all 13 guards passed. The pinned Rust oracle
accepted artifact `49f9555c...cfb4`.

The `core_metal/huge/time` verdict also used five paired rounds. Prove ratio
was **0.940208**, 95% CI **[0.911487, 0.953475]**, from 116.527959 to
109.187000 ms. Verified-request ratio was **0.849958**. Energy ratio was
**0.845607** with upper CI 0.867150; RSS ratio 0.982137 with upper CI
0.995979; proof bytes were unchanged at 86,383. G1-G5 and all 13 guards
passed. The pinned Rust oracle accepted artifact `8a66bd21...f00e`.

Two independent wide objectives were significant—0.9358 [0.9151, 0.9438]
and 0.9351 [0.9161, 0.9423]—but are deliberately not claimed. Their only
failed gate was the same high-dispersion sub-millisecond `wf_10×8` guard,
whose upper CI was 1.149 then 1.058 against a 1.05 budget. The deep target was
0.9777 [0.9644, 0.9871] over 15 rounds, favorable but below its declared
significance threshold. All receipts and raw run directories remain in the
external evidence bundle rather than being selectively discarded.

The all-cell PR6 task remains incomplete. Exact Blake/Plonk parity, every
log22 oracle vector, both verified-request and cold-process gates, and the
authenticated locked-host verdict are still required. **PR6 Supremacy: not
achieved.**
