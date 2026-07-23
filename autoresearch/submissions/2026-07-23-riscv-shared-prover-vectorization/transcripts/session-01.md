# Autoresearch session 01 — RISC-V deep epoch 6

## Objective, policy, and starting point

This session continues the user-directed optimization loop after PR #86 merged
direct column-to-four-message BLAKE2s streaming. The promoted predecessor is
clean `main` commit `0a04f85af1e2`. The priority is the complete seven-program
`riscv/deep` portfolio, especially SHA2-2048, while retaining Native CPU,
Native Metal, proof-size, energy, RSS, and correctness guards. A single fast
screen is diagnostic; the promotion unit is a clean paired portfolio verdict.

The repository-resident CLI had already been refreshed and the five repository
skills were exercised. Their binding method in this epoch was:

1. match a measured hot path to a structural algorithm change before editing;
2. use macOS sampling plus instruction/cycle/energy counters for attribution;
3. preserve Metal residency and fallback contracts even though this objective
   scores the shared CPU/RISC-V prover;
4. distinguish exact canonical proof bytes from provenance-bearing artifact
   envelopes; and
5. preserve unsuccessful iterations in this transcript and external evidence.

The editable-path audit was decisive. The attractive epoch-5 Horner LogUp
prototype lives under locked `src/frontends/riscv/**`, so it was retained as
architecture evidence but excluded from this scored candidate. Epoch 6 starts
from shared MANIFEST-approved field, PCS, polynomial, and crypto code only.

## Baseline profile and bottleneck map

The current-main SHA2-2048 profile retained at
`evidence/packed32-sha2-2048.sample.txt` sampled the live ReleaseFast prover.
The useful collapsed top-of-stack counts were:

```text
four-message BLAKE2s compression                         3246
memmove                                                  2004
RISC-V LogUp pairConstraint                              1316
quotient tile executor                                   1121
forward circle FFT tail                                   994
Poseidon full-round AIR                                   615
lookup denominator                                        601
batched Merkle leaves                                     437
inverse circle FFT batch                                  242
CM31 quotient batch inversion                              83
```

The main thread spent most samples in worker waits, so optimization decisions
used worker stacks and process-wide counters rather than treating wait samples
as work. Locked frontend frames were not edited. The shared quotient, FFT,
field, and BLAKE2 frames became the search surface.

## Layer 1: packed CM31 batch inversion

The quotient row preparer performs many independent CM31 inversions. The
existing prefix/suffix batch algorithm serialized every multiplication. The
new AArch64 path packs four independent CM31 values across AdvSIMD lanes, then
uses size-adaptive dependency stripes of 8, 16, or 32 elements. Generic hosts
retain scalar stripes of width 8 or 4. Zero input remains fail-closed.

An isolated 4,096-value profile measured:

| implementation | ns/value | instructions/value | cycles/value |
| --- | ---: | ---: | ---: |
| serial prefix/suffix | 8.614 | 134.1 | 39.59 |
| scalar striped-8 | 5.531 | 148.2 | 25.42 |
| packed striped-8 | 2.954 | 42.8 | 13.58 |
| packed striped-16 | 2.566 | 42.15 | 11.80 |
| packed striped-32 | 2.538 | 43.5 | 11.67 |

Width 64 was rejected: latency was flat at 2.539 ns/value while instructions
rose. Differential coverage includes lengths 1, 2, 3, 7, 8, 16, 24, 31, 32,
40, 63, and 64 plus zero rejection. Commit `90703d2` passed the complete test
closure. Its clean paired portfolio was a real but sub-threshold improvement:
ratio 0.991250, 95% CI [0.988412, 0.993043]. It was retained for stacking.

## Layer 2: exact four-term compact quotient reduction

SHA2-2048's quotient plan contains 33 compact groups, 2,122 compact members,
2,291 total contributions, and 13 numerator batches. Each compact group was
performing a modular reduction after every base-field product. Four canonical
M31 products sum below `2^64`, so `M31.dot4` now accumulates four exact `u64`
products and performs one final Mersenne reduction. Compact groups use that
primitive for even and odd lifted values across all four extension coordinates
and retain a scalar tail.

The live reducer microprofile improved from 7.381 ns/member, 55.05
instructions/member, and 33.94 cycles/member to 6.060 ns, 43.06 instructions,
and 27.86 cycles. Two- and four-accumulator alternatives were measured and
rejected because register spills raised instructions to about 65/member and
latency to 6.86–7.30 ns/member.

Commit `2ddb141` moved the clean portfolio to 0.989187 with 95% CI
[0.986560, 0.991975], still below promotion significance. It remained in the
stack because the instruction and cycle mechanism was direct and broad.

## Layer 3: M31 reduction and inverse-FFT scaling

The general `reduce64` helper was corrected and shortened to two complete
Mersenne folds followed by unsigned minimum against wrapping subtraction. A
full-range unit fixture prevents confusing the stricter product-only bound with
arbitrary `u64` reduction.

Inverse FFT normalization was then expressed as four interleaved packed M31
products plus a scalar tail. The normalization microprofile improved from
0.2942 ns/value, 3.816 instructions, and 1.009 cycles to 0.2454 ns,
2.378 instructions, and 0.633 cycles. Commit `dc21153` produced clean portfolio
ratio 0.988733 with 95% CI [0.985543, 0.992656]. The stack was now close but
still honestly reported as not significant.

The SHA2-2048 screen at this point measured 2.632837 s verified request,
1.990471 s proving, 234.193 billion instructions, and 69.156 billion cycles.
Statement digest `6bc61b...97e88` and transcript digest `4ca8cf...fac8` remained
stable.

## Rejected quotient and scheduling experiments

Several plausible designs were falsified before the final architecture:

- Factoring the quotient determinant added dependency depth and did not reduce
  the complete row path. It was removed.
- Worker counts 12, 14, 16, and 18 plus an oversubscribed configuration did not
  improve the critical path. More workers increased contention or left the
  same serial joins.
- A flattened immutable direct-contribution plan converted 24 direct views
  into the grouped reducer and passed exact proofs, but changed SHA2-2048
  instructions by only -0.0086% while cycles rose 0.31%. It was removed in
  full, including its temporary diagnostic exports.
- Two and four independent compact accumulators increased spills and were
  rejected by the microprofile above.
- A generic three-batch SIMD QM31 multiplication saved instructions but lost
  latency on dependent multiplication chains; independent-row packing remains
  the correct SIMD dimension.
- Runtime worker oversubscription was not used to manufacture a benchmark win.

These outcomes matter because they rule out repeating plan materialization,
generic aggregate SIMD, or worker-count tuning as the next epoch's first move.

## Layer 4: fuse inverse normalization into radix-8

For the final three inverse FFT stages, the normal flow computed

```text
lo = lhs + rhs
hi = (lhs - rhs) * twiddle
```

and then traversed the whole coefficient buffer to multiply both outputs by
`n^-1`. The normalized radix-8 kernel instead computes

```text
lo = (lhs + rhs) * n^-1
hi = (lhs - rhs) * (twiddle * n^-1)
```

inside the final register-resident stage. Production transforms always reach
that final radix group; small shapes retain the generic scale fallback. A
focused differential test compares the normalized fused kernel with the old
three stages followed by scaling.

The first SHA2-2048 screen removed about 193 million instructions (0.082%) and
was deterministic across repeated runs. Its canonical proof bytes were stable.
An apparent artifact-hash change versus an older dirty build was traced to the
provenance envelope; comparing `proof_bytes_hex` is the correctness-relevant
test.

## Layer 5: expose four independent BLAKE2 G chains

Disassembly of `compressParallel4` showed a 5.8 KiB fully unrolled AArch64
function. Rotate-16 and rotate-8 were already one-instruction `rev32`/`tbl`
forms, while rotate-12 and rotate-7 were optimal two-instruction shift/insert
forms. The remaining opportunity was instruction scheduling: source issued
four complete independent G calls, so the generated code followed long local
dependency chains.

`g4Interleaved` advances four independent G functions one dependency level at
a time. Generated stack accesses fell from 85 to 70 and static instructions
from 1,448 to 1,440. The full SHA2 screen removed another 131 million
instructions. Cycle movement was too small for an isolated claim, so this was
kept only as part of the broad stack and later judged by the paired portfolio.

## Layer 6: synthesize 2x LDE expansion in the first radix pass

The two-times LDE extension previously copied each coefficient buffer's lower
half into its upper half, then immediately reread both halves for the first
active radix-8 group. The skipped degenerate stage has exact output `(a, a)`.
The new expansion kernel processes the upper destination group first while the
lower source is intact, then transforms the lower group in place. This removes
one complete `memcpy` traversal. Small transforms that do not begin with a
packed radix-8 pass retain the old materialization fallback.

A focused fixture deliberately fills the unused upper half with unrelated
values and proves that synthesized expansion exactly matches explicit
duplication followed by the generic kernel. The SHA2-2048 screen reduced the
proving substage from 2.034471 s to 2.006513 s (1.37%); process-wide
instructions, cycles, and energy all fell. The verified-request sample itself
was obscured by a 43 ms witness fluctuation, which is why this layer proceeded
to ABBA rather than being claimed from one timing.

Commit `2f15522` combined the normalized inverse boundary, BLAKE2 scheduling,
and direct LDE expansion. Its clean paired seven-workload run reached ratio
0.985260 with portfolio 95% CI [0.981583, 0.988590]. Six rows were clearly
faster and SHA2-512 reached 0.9718, but the promotion boundary was approximately
0.987112, so the candidate remained a near miss and was not submitted.

## Layer 7: transpose compact quotients across extension coordinates

The remaining 0.15-point confidence gap prompted a second look at compact
groups. The scalar `dot4` reduction vectorized across members, but every member
already stores four contiguous extension coefficients. On AArch64 the better
dimension is therefore the four coordinates:

```text
member coefficients [c0 c1 c2 c3]
                    × splat(even value)
                    × splat(odd value)
```

Four members are issued together. Their eight independent `mulVec4` operations
are pairwise tree-reduced into even and odd vector accumulators. Generic and
stage2-C builds retain the exact scalar `dot4` implementation.

The focused SHA2-2048 screen removed 1.109 billion instructions (0.475%) and
522 million cycles (0.753%) from the complete warmup-plus-sample process. The
canonical proof hex, statement, claim, and transcript were byte-identical to
the predecessor. The whole JSON artifact digest changed only because its
provenance moved from dirty `dc21153` to dirty `2f15522`.

## First significant paired checkpoint

The first clean significant checkpoint is `e7560c9ceae5`, paired on the same host against
clean predecessor `0a04f85af1e2` under harness `20e097517010`. Adaptive paired
sampling used 29 total rounds. Every timed proof verified, candidate and
predecessor proof digests were byte-identical per round, and the pinned Stark-V
oracle accepted 7/7 workloads.

| workload | proving ratio | 95% CI | request ratio | rounds |
| --- | ---: | ---: | ---: | ---: |
| xorshift | 0.9866 | [0.9791, 0.9940] | 0.9909 | 5 |
| Fibonacci | 0.9859 | [0.9808, 0.9905] | 0.9867 | 3 |
| GCD | 0.9838 | [0.9780, 0.9888] | 0.9819 | 3 |
| multi-shard | 0.9834 | [0.9739, 0.9910] | 0.9826 | 5 |
| SHA2-512 | 0.9824 | [0.9626, 0.9989] | 0.9910 | 5 |
| SHA2-1024 | 0.9855 | [0.9798, 0.9915] | 0.9838 | 5 |
| SHA2-2048 | 0.9722 | [0.9662, 0.9759] | 0.9877 | 3 |

The geometric-mean proving ratio is **0.982829** with portfolio 95% CI
**[0.979287, 0.986004]**, clearing the noise-adjusted significance boundary.
Geometric-mean energy ratio is **0.962484** (3.75% lower). Peak-RSS ratio is
1.000374 with upper-CI geomean 1.003405, and proof-byte ratio is exactly 1.0.
All seven mechanism rows and all repository gates G1–G5 passed. This remains a
local claimed verdict until the authenticated judge reruns it.

The architecture is structural rather than benchmark-specific:

```text
CM31 inversion: serial dependency chain -> independent SIMD stripes
compact quotient: product-by-product reduction -> exact dot4 -> coordinate SIMD
inverse FFT: radix pass -> full scale traversal -> normalized final radix pass
2x LDE: memcpy duplicate -> reread both halves -> synthesize upper radix group
BLAKE2s: four complete G chains -> four dependency levels in lockstep
```

No workload name, input digest, target size, or proof parameter controls these
paths. Admission follows field type, AArch64 capability, compact-group geometry,
and the mathematically structural 2x-extension boundary.

## Remaining work and PR6 status

The next shared-prover epoch should profile after promotion. Likely remaining
editable targets are quotient finalization, forward FFT tail arithmetic, and
BLAKE2 message scheduling; locked RISC-V LogUp and lookup construction require
separate maintainer review. The 2x expansion kernel can also be extended to
load the lower radix tuple once and emit both twiddle variants if a microprofile
shows enough register headroom.

This promotion advances the broad RISC-V prover but does not satisfy the
separate all-cell PR6 contract. Exact PR6 workload ports, log22 oracle vectors,
both verified-request and cold-process timing boundaries, the locked-M5 matrix,
and an authenticated judged verdict remain incomplete.

**PR6 Supremacy: not achieved.**

## Submission-conformance extraction

The first significant checkpoint could not yet be submitted because two
optimized implementation files exceeded the repository's manual 850-line
ceiling. This was a source-conformance issue, not a failed proof or benchmark.
The four-message BLAKE scheduling kernel and its public dispatch contract were
moved into focused crypto modules. The packed radix-8 implementation was moved
into a focused FFT module and re-exported through the existing API. No
arithmetic or call-site policy changed.

The first extraction compile exposed a Zig name-shadowing error between the
radix helper's `inverse` parameter and its public `inverse` wrapper. Renaming
the parameter to `inverse_transform` resolved it. The complete ReleaseFast
closure then passed across 377 transitive Zig sources, and source conformance
reported only the five already-explained legacy findings. The clean extraction
commit was `0e15f1af3bdb`.

A fresh paired run on that immutable identity produced portfolio ratio
0.988161, 95% CI [0.985446, 0.991572], and was correctly classified as not
significant. Deterministic diagnosis ruled out a code-generation regression:
SHA2-2048 retained approximately 232.58 billion instructions and 68.8 billion
cycles, essentially identical to the prior significant checkpoint. The
candidate/predecessor clock relationship had moved. This near-miss is retained
at `evidence/run-clean-0e15f1a-nearmiss-raw`; it was not selected as promotion
evidence.

## Layer 8: algebraically reduced, batch-major quotient denominators

The near-miss left a small confidence gap, so the next iteration targeted a
real remaining quotient cost. Each denominator was formed for every row and
sample batch as

```text
(prx - x) * piy - (pry - y) * pix
```

where `x` and `y` are base-field domain coordinates and every other term is
constant for a proof session. Expanding once gives

```text
det = prx*piy - pry*pix
denominator(row) = det - x(row)*piy + y(row)*pix
```

The session now precomputes `det`. The CPU tile path transposes denominator
storage from row-major to sample-batch-major and evaluates four adjacent rows
with native M31 vectors. Four domain points are deinterleaved into x/y vectors;
four coordinate products cover all four rows. The resulting CM31 values are
interleaved into contiguous storage, batch-inverted with the already optimized
packed inversion, and loaded back by quotient finalization with two vector
loads and two shuffles instead of eight strided scalar gathers.

```text
old: row -> [sample0 sample1 ...] -> scalar CM31 products -> strided gather
new: sample -> [row0 row1 row2 row3] -> packed base products -> contiguous load
```

The retained scratch records whether inverses are row-major or batch-major so
the old API fails closed if called under the wrong layout. Tests cover batch
counts 1, 3, and 8; row counts 1, 2, 3, 4, 7, 8, and 17; repeated stride
changes; zero denominators; scalar tails; and packed finalization against the
canonical scalar quotient. The full SHA2-2048 proof supplied end-to-end parity.

The profiled SHA2-2048 screen moved from 232.617 to 229.797 billion
instructions (-1.21%), 68.800 to 68.147 billion cycles (-0.95%), and 2.029 to
1.983 seconds proving (-2.28%). Statement and transcript digests were stable,
and the canonical proof-byte SHA-256 was identical. Clean commit `cf9dee1bda01`
then produced a significant seven-workload verdict: portfolio ratio 0.981894,
95% CI [0.979489, 0.984016], 23 rounds, energy ratio 0.951516, RSS ratio
0.999773, and proof-byte ratio 1.0.

## Cross-backend breakage found and generalized Metal fix

The explicit Native Metal product guard then found an important compile-time
dependency: Metal's runtime uploader read the old `prx` and `pry` fields from
the shared CPU workspace. Restoring redundant fields would have hidden the
architectural mismatch. Instead, the Metal request path was changed to upload
the same precomputed determinant, `pix`, and `piy` in its existing eight-word
ABI envelope. The direct quotient, raw quotient, and split-finalize shaders now
use the same reduced formula and replace two full CM31 multiplies with two
CM31-by-M31 multiplies per sample and row. The independent resident FRI recipe
keeps its separate original point ABI and was intentionally not conflated with
this request layout.

Source-JIT compiled the changed shader through the macOS Metal runtime. The
Native Metal product closure passed across 256 transitive Zig sources, and the
device-only lifecycle proof plus independent verification passed with no CPU
fallback. This generalized fix became clean commit `8a3b16047112`.

## Final immutable verdict and confidence resolution

Because the Metal-only commit changed the candidate identity, the RISC-V board
was measured again rather than attaching the prior commit's verdict. The first
`8a3b160` run was faster on all seven rows, with portfolio ratio 0.984744 and
95% CI [0.981673, 0.987511]. Its upper bound missed the promotion threshold by
0.000316, so it was retained as a near-miss rather than called significant.
No sample failed or was discarded.

One declared confirmation run on the same immutable commit resolved that
narrow confidence edge. It used 23 adaptive paired rounds, with every timed
proof independently verified, cross-arm proof bytes identical per round, and
the pinned Stark-V oracle accepting 7/7 workloads.

| workload | proving ratio | 95% CI | request ratio | rounds |
| --- | ---: | ---: | ---: | ---: |
| xorshift | 0.9830 | [0.9782, 0.9850] | 0.9833 | 3 |
| Fibonacci | 0.9814 | [0.9694, 0.9933] | 0.9815 | 5 |
| GCD | 0.9855 | [0.9836, 0.9889] | 0.9894 | 3 |
| multi-shard | 0.9920 | [0.9849, 0.9961] | 0.9951 | 3 |
| SHA2-512 | 0.9734 | [0.9696, 0.9796] | 0.9793 | 3 |
| SHA2-1024 | 0.9769 | [0.9729, 0.9845] | 0.9819 | 3 |
| SHA2-2048 | 0.9849 | [0.9810, 0.9901] | 0.9792 | 3 |

The final portfolio ratio is **0.982416**, 95% CI **[0.980101, 0.984837]**,
which clears the predeclared theta 0.012888 significance rule. Energy ratio is
**0.952201** (4.78% lower); peak-RSS ratio is **0.998642** with upper-CI
geomean 1.001208; proof-byte ratio is exactly **1.0**. G1-G5 pass. The raw
confirmation evidence is retained at `evidence/run-final-8a-significant-raw`;
the non-significant confirmation predecessor and every earlier iteration are
retained alongside it.

Explicit guards on the final content passed the complete ReleaseFast test
closure, source conformance, the 352-source RISC-V CPU product closure, the
210-source Native CPU product closure, and the 256-source Native Metal product
closure with device-only proof lifecycle. The aggregate `--guards all` route
was also attempted earlier and exposed a harness manifest bug: a Native guard
row named `guard_blake_10x10` was parsed as RISC-V and lacked the required
`{admission}` placeholder. Explicit product gates were used rather than hiding
that harness failure.

The claimed verdict remains advisory until the authenticated judge repeats it.
The separate PR6 all-cell task still lacks the exact complete workload matrix,
log22 oracle vectors, both timing boundaries, and locked-M5 judged evidence.

**PR6 Supremacy: not achieved.**
