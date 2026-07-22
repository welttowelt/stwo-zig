# Fold M31 products with AArch64 AdvSIMD and fuse CPU FFT tails

## Model and harness

Model: GPT-5 Codex. The repository-resident `stwo-perf` harness ran on the
designated Apple M5 Max in ReleaseFast mode. The claimed S3 `core_cpu/huge`
comparison used immutable candidate `ee3316f3685f` and current-main predecessor
`354da109e02a`, paired A-B-B-A rounds, verified proofs, the pinned Rust oracle,
and the automatic 13-workload Native regression portfolio. The complete exact
PR6 width-100 diagnostic separately used ten warmups and seven ABBA rounds at
logs 14, 16, 18, 20, and 22 for both verified-request and cold-process lanes.

## Hypothesis

M31 multiplication was still paying scalar widening and reduction costs in the
CPU prover's densest loops. On AArch64, a four-lane `mul.4s` plus `sqdmulh.4s`
recovers the low product and doubled signed high product needed for an exact
Mersenne fold; masking, folding, and `umin` then canonicalize four products at
once. Fusing only the final three, four, or five FFT layers should complement
that arithmetic win while preserving radix-8 scheduling and cache locality.

The falsifiers were any field mismatch, transform mismatch, proof-byte drift,
oracle rejection, guard regression, or an insignificant end-to-end result.

## Changes

`M31.mulVec4` now selects an AArch64 AdvSIMD reduction built from full-lane
`mul` and `sqdmulh`; other architectures retain the portable implementation.
The circle transform scheduler selects size-aligned fused 3/4/5-layer tails so
earlier passes remain radix-8. A differential test compares every output with
the generic transform across relevant sizes.

The search also produced useful negative results. A direct 2x-LDE reuse idea
was invalid because the canonical base and extended circle cosets are disjoint.
A compact Blake compressor removed a spill frame but increased instructions.
Dynamic heterogeneous tiling damaged locality, packed radix-16 increased
register pressure, and an earlier volatile `sqdmull` experiment regressed
codegen; all were removed. The retained binary contains 213 `sqdmulh`
instructions and uses the nonvolatile exact fold.

## Results

The clean S3 huge CPU verdict measures 356.401 -> 332.792 ms: ratio **0.9239**,
95% CI **[0.9129, 0.9362]**, a statistically significant 7.6% reduction.
Energy is 0.9130x (95% upper 0.9158), peak RSS is 0.9992x (upper 1.0097), and
proof size is unchanged at 86,383 bytes. Every timed proof verified, proof
digests matched across arms, the pinned Rust oracle accepted the workload, and
all 13 automatic regression guards remained within budget.

The broader cumulative PR6 research branch measured 0.7556x on the same class,
but carried unrelated earlier architecture changes. This submission deliberately
isolates only the four-file arithmetic/FFT mechanism onto current main so all
repository identity and editable-path gates pass.

The exact PR6 diagnostic confirms broad CPU gains: both request and cold lanes
pass the 0.80 target at logs 14, 16, and 18; logs 20 and 22 improve materially
and win both ABBA halves but remain above the task's unusually strict 0.80
ratio. Clean single-process medians were 10.876, 20.534, 69.962, 268.833, and
1145.818 ms across logs 14..22. The apparent earlier 132--135/523--539 ms
discrepancy was resolved: those figures were Metal verified-request timings,
not CPU timings.

ReleaseFast canonical and deep roots, core/prover/CPU/Metal/RISC-V products,
field and transform differentials, source conformance, and a 13-row CPU/Metal
holistic smoke all pass. The smoke produced identical canonical CPU/Metal
proof bytes and zero Metal CPU fallbacks.

## Caveats

This is a claimed local result; only the locked judge can issue a judged
verdict. G1--G5 pass, including a clean identity gate with no locked or
out-of-scope path. The full PR6 Supremacy task still lacks exact Blake,
Plonk, fixed-wide, and state-machine peer ports, complete oracle vectors,
synchronization telemetry, and a passing log20/log22 CPU ratio at both timing
boundaries. Accordingly, this submission claims the significant repository
CPU improvement only, not PR6 Supremacy.

**PR6 Supremacy: not achieved.**
