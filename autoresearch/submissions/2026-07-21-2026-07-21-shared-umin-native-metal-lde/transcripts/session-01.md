# Session 01 — large-regime shared CPU and Metal optimization

## Objective and session boundary

The user requested the largest improvement possible on both CPU and Metal,
especially the unpromoted xlarge and huge classes, with an immediate submission
once a significant joint result exists. The repository-resident CLI was updated
before work. The first update advanced canonical main from `c952682c500a` to
`06f78755693e` through harness/feed-only commits. Immediately before packaging,
main advanced again through RISC-V activation and feed-only changes to final
predecessor `7f00554f9df4`; prover source was unchanged, so the candidate was
rebased and both verdicts were rerun rather than reusing commit-bound evidence. Two
pre-existing untracked notes in the canonical checkout are preserved verbatim
and are not part of this experiment.

All five repository skills were read and exercised as the operating contract:
algorithm matching, Metal performance design, Metal profiling, Zig profiling,
and submission transcripts. The Metal common-patterns reference was also read.

## Grounding benchmark and stage attribution

Fresh ReleaseFast CPU and source-JIT Metal products were built locally. The M5
Max Metal runtime reports 32 KiB threadgroup memory, 1024 maximum threads, and
unified memory. Source JIT uses the embedded MSL library; shader compilation is
outside timed post-warmup samples.

Unprofiled diagnostic medians retained exact cross-backend proof hashes:

| class | CPU prove | Metal prove | proof / Metal telemetry |
| --- | ---: | ---: | --- |
| xlarge `log18x100` | 274.196 ms | 474.623 ms | `f845568c...`; 26 dispatches, 0 fallback |
| huge `log20x100` | 1234.831 ms | 1369.150 ms | `e6609d...`; 28 dispatches, 0 fallback |

Stage profiles identify shared host composition evaluation as the dominant
stage on both products:

```text
xlarge CPU    composition 142–160 ms / prove 271 ms
xlarge Metal  composition 368–465 ms / prove 453–556 ms
huge CPU      composition 549–696 ms / prove 1.01–1.30 s
huge Metal    composition 675–880 ms / prove 0.98–1.16 s
```

The Metal-owned stages are much smaller: huge main-trace commitment is about
151–156 ms and FRI about 26–29 ms. This makes the highest-leverage Metal-product
work a shared host arithmetic architecture, not an unprofiled shader tweak.

## Architecture map and first rejection

The scored wide Fibonacci AIR is a single component. Its locked domain callback
uses a row-major loop: for each of 2^(log+1) rows, it streams across 100 separate
columns and performs 98 recurrence constraints and random-coefficient
accumulations. At huge size this executes roughly 205 million recurrence steps.

```text
current row-major: row -> 100 concurrent column streams -> one QM31 output
ideal constraint-major: constraint -> 3 sequential columns + QM31 output stream
```

Constraint-major traversal would expose SIMD across rows and sharply reduce the
active memory streams, but the loop is in `src/examples/wide_fibonacci`, outside
`MANIFEST.json -> editable_paths`. The type-erased prover vtable exposes only a
whole-domain callback; a generic prover cannot infer recurrence semantics from
trace shape. A row-range vtable would require locked derive/example edits. This
architecture is therefore rejected for this submission on policy and semantic
grounds, despite being the strongest upstream design recommendation.

The editable search now targets the exact shared field and accumulator
primitives emitted by that loop. Whole-process sampling and a live-module
isolation will decide among: cheaper QM31-by-M31 fused accumulation, removal of
generic accumulator state overhead, or a shared transform improvement. The
falsifiers are unchanged proof bytes, failure to move the composition stage, or
any CPU/Metal guard regression.

## Whole-process sample and bounded-minimum problem match

A two-second `/usr/bin/sample` capture of the real profiled huge CPU request
placed 408 top-of-stack samples in the wide Fibonacci domain evaluator; the
other large stacks were parallel FFT, Merkle, and quotient workers. Disassembly
at the sampled offsets confirms the locked inner loop issues two scalar
`umull` square/reduction chains per constraint, followed by one four-lane
QM31-by-M31 multiply and one four-lane QM31 accumulator add. LLVM does not cache
the adjacent repeated square.

For canonical M31 operands and `p = 2^31 - 1`, both an addition and the one-fold
product reduction produce `0 <= x < 2p`. In this exact interval:

```text
x < p:   (x - p) mod 2^32 > x  => min(x, x-p) = x
x >= p:  x - p < x             => min(x, x-p) = x-p
```

Thus `min(x, x -% p)` is the same canonical residue as conditional subtraction,
without changing representation or accepting noncanonical values. Arm's A64
architecture guide documents the 128-bit vector register model, and the Arm
instruction reference documents the widening `UMULL/UMULL2` operations already
used by the product path. The local Zig codegen establishes the material target
fact: vector `@min` selects AdvSIMD `UMIN` on this M5 Max.

A live-module `stwo-prof zig` ABBA isolation used the real repository M31 module
for the baseline and an algebraically equivalent bounded-minimum implementation
for the candidate. Fifteen rounds over an exact four-lane multiply/add chain
measured 2.502 -> 1.474 ns/operation, ratio 0.5896 with 95% CI
[0.5695, 0.6085]. Instructions moved to 0.8890 and cycles to 0.6026. Assembly
replaced each `cmhi + and + add` canonicalization with `add/sub + umin`.

## Narrow implementation and first huge screen

The patch changes fixed-Vec4 and native-packed addition/product reduction to
the bounded unsigned-minimum identity. `QM31.add` extracts its four fields
directly at the consuming operation and invokes the fixed Vec4 primitive; there
is no by-value aggregate conversion helper. Field tests passed: 2/2 M31 and
11/11 QM31/CM31/M31 ReleaseFast tests, including random field laws and bounded
product edge cases. Both Native CPU and source-JIT Metal products rebuilt.

The first profiled huge CPU screen retained `e6609d...` and moved composition
from the immediately preceding 0.515 s sample to 0.427/0.430 s; prove time was
0.813/0.818 s. The following Metal screen also retained the exact hash, 28
dispatches, and zero fallback, but ran during a macOS Spotlight indexing burst
(`spotlightknowledged` 103% CPU, `corespotlightd` 73%, `cfprefsd` 27%) and its
single host composition thread slowed to 1.414 s. CPU and Metal disassembly of
the complete domain evaluator is instruction-for-instruction identical, so the
mixed observation is not attributed as a backend result. A clean paired run is
required after external load settles.

## Metal architecture search

Once the shared arithmetic candidate was frozen, direct Metal stage traces
showed that the remaining Metal-owned opportunity was the large-domain LDE and
the copy boundary between completed LDE columns and Merkle hashing. The xlarge
main-trace commitment decomposed approximately as follows before the Metal
changes:

```text
column arena -> inverse circle FFT -> zero expansion -> forward circle FFT
             -> full-arena blit into private Metal storage -> leaf hashing

                                        main-trace commit: 34.6 ms
                                        composition commit:  9.6 ms
```

Three independent architectural matches were composed:

1. The existing sparse radix-4 circle kernel was generalized with an inverse
   mode bit and reused for contiguous Native inverse and forward upper layers.
   Pairing adjacent radix-2 layers halves those upper-layer launches without
   changing twiddle order or coefficient layout.
2. For a one-bit blowup and `base_log >= 12`, scaling, the degenerate zero
   expansion, and the first two real forward layers are one kernel. The lower
   bound is a correctness boundary: an earlier `base_log >= 2` prototype
   overlapped the existing 11-layer fused tail and failed the exact
   `guard_blake_10x10` last-layer-degree check. Restricting the fusion to
   disjoint layer regions restored exact parity.
3. On unified-memory devices, a page-aligned contiguous column arena of at
   least 1 MiB is exposed to Metal with `newBufferWithBytesNoCopy`, allowing
   leaf hashing to consume the completed LDE output directly. Fragmented,
   small, or non-UMA layouts retain the prior private-buffer upload. A first
   ungated version made the tiny 64 KiB guard noisy; the 1 MiB ownership gate
   isolates the design to transfer sizes where avoiding the blit is valuable.

The resulting dataflow is:

```text
column arena -> radix-4 inverse pairs -> fused scale/expand/forward pair
             -> radix-4 forward pairs -> UMA alias -> leaf hashing

                                        main-trace commit: 27.0 ms
                                        composition commit:  8.5 ms
```

The no-copy buffer is retained only through the synchronous command lifetime;
the existing terminal wait precedes arena reuse. No new asynchronous ownership
is introduced. The core shader ABI is bumped from 5 to 6, so an old
authenticated AOT bundle fails closed instead of loading kernels with changed
semantics. Source-JIT continues to compile the embedded MSL through the macOS
runtime during initialization, outside post-warmup samples.

## Rejected or superseded experiments

- Cooperative SIMD Merkle-tail reduction was already promoted in PR #42, so it
  was not duplicated.
- `USER_INITIATED`, `USER_INTERACTIVE`, task-policy tiers, and worker offload
  were neutral, slower, or frequency-sensitive and were removed.
- A 4,096-element FFT tile with 512 threads reduced its isolated stage by about
  2 ms but regressed end-to-end scheduling and was removed.
- Rewriting MSL conditional reductions to `min` was neutral because the Metal
  compiler already canonicalized them.
- Inverse radix-4 alone saved about 1.1 ms and top-layer fusion another
  0.6--1.7 ms. The larger end-to-end Metal result required composing those
  launch reductions with the UMA copy-elision boundary.

## Frozen implementation and paired evidence

Candidate `e10ff92e92a1` is measured against exact predecessor
`7f00554f9df4`. The shared CPU path uses `min(x, x -% p)` only in operations
whose proven output range is below `2p`; AArch64 emits `UMIN`. `QM31.add`
extracts its four M31 coordinates at the consuming operation, calls the fixed
Vec4 primitive, and reconstructs the value. This avoids a by-value aggregate
conversion that produced incorrect optimized code in an earlier prototype.

Five-round S3 ABBA evidence produced two independently claimable verdicts:

| board / class | predecessor | candidate | B/A (95% CI) | reduction |
| --- | ---: | ---: | ---: | ---: |
| CPU huge `wf_log20x100` | 862.923 ms | 818.807 ms | 0.953428 [0.941439, 0.964728] | 4.66% |
| Metal xlarge `mwf_log18x100` | 419.301 ms | 410.634 ms | 0.976060 [0.971860, 0.982132] | 2.39% |

CPU exceeds its noise-derived promotion threshold. Metal is favorable and not
neutral, but its latest five-round upper CI misses the `1 - theta` significance
boundary by 0.001086. The immediately preceding identical-source run, before
the harness-only rebase, measured 0.974533 [0.968636, 0.980512] and was
significant; both runs are retained and the latest result is the submitted one.
CPU energy was 4.23% lower and Metal energy 3.07% lower; peak RSS and proof size
stayed within budget. All timed proofs verified, the arms were byte-identical,
and the pinned Rust oracle accepted both fixed proofs (`e6609d...` huge and
`f845568c...` xlarge). G1--G5 and all 13 automatic regression guards passed for
each verdict.

Final validation passed the Native Metal product/lifecycle and independent
verification test, Metal compile check, deterministic core-AOT tooling tests,
AOT acceptance-probe contracts, and the complete ReleaseFast Zig test closure.
The two preserved pre-existing notes remained outside the candidate throughout
measurement and packaging.
