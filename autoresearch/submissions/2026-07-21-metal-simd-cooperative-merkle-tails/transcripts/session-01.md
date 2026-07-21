# Session 01 — next paired CPU and Metal frontier

## Objective and setup

The user requested another full optimization round with the same contract: update the repository-resident CLI first, preserve existing research, benchmark the current system locally, use profiling and architectural reasoning, submit as soon as a significant solution exists, drive the PR green, merge it, and improve both CPU and Metal from one source submission.

Canonical main was initially at `1c3f3ca` with two pre-existing untracked Metal research notes. `stwo-perf update` correctly refused the dirty checkout. Those two exact files were moved to a temporary safe directory, main fast-forwarded six commits to promoted frontier `c2d29013ff5b`, and the files were restored with identical SHA-256 hashes (`81263c43...81f3` and `7654c629...2bd`). No note content changed.

All five repository research skills were loaded for this round: canonical-problem matching, Zig counters/codegen profiling, real-device Metal profiling, Metal architecture design, and submission transcript capture. The compute-only Metal common-pattern reference was also read; render/TBDR guidance is not applicable.

`stwo-perf clone` created the candidate workspace, a separate detached predecessor was created at the same frontier, and the candidate branch is `autoresearch/dual-hotpath-04`. `stwo-perf setup` rebuilt both enabled Native CPU and Native Metal ReleaseFast products in both worktrees. RISC-V remains disabled by benchmark policy.

## Search discipline

The prior round removed the dominant corrected-frontier QM31 base-multiplication regression and promoted CPU-wide R=0.7911 plus Metal-wide R=0.7598. This round will not assume the old bottleneck remains. The first action is a fresh six-row benchmark suite, followed by stage profiles and source/lifetime analysis. Any material algorithmic replacement will receive a problem-match brief before editing; any Metal architectural change will receive the skill-mandated resource, ownership, dispatch, ABI, and falsifier brief.

## Fresh frontier benchmark

Both products were benchmarked from the untouched `c2d2901` frontier with ten
warmups and ten verified post-warmup samples. All sixty proofs verified, all
samples within each row were byte-identical, CPU fallback was zero, and Metal
reported the expected 18/22/24 post-warmup dispatches for small/wide/deep.

| backend | workload | prove median | request median |
| --- | --- | ---: | ---: |
| CPU | small | 1.919 ms | 2.156 ms |
| CPU | wide | 9.419 ms | 10.266 ms |
| CPU | deep | 6.334 ms | 6.661 ms |
| Metal | small | 4.170 ms | 4.416 ms |
| Metal | wide | 8.670 ms | 9.477 ms |
| Metal | deep | 4.721 ms | 5.041 ms |

The fixed proof hashes were respectively `91741aec...5700`,
`57a7d291...3374`, and `d63a2c92...dbaf`. The Metal-small number is known to
be especially sensitive to process/clock state, so it is grounding evidence,
not a claim against the promoted historical median.

## Fresh stage attribution

Five-warmup/five-sample compact profiles make FRI quotient construction,
folding, and commitment the largest common stage. It costs 0.774/3.048/2.965
ms on CPU small/wide/deep and 1.290/1.835/1.587 ms on Metal. CPU-wide also has
2.241 ms of composition evaluation, while Metal-wide has 2.083 ms; therefore
extension-field arithmetic is a plausible shared lever beyond FRI itself.

The current Metal line cascade already uses one command buffer and one wait,
resident inverse domains, fused next-coordinate/leaf production, a shared
Merkle arena, multiblock bottom tails, threadgroup-local top tails, and fused
transcript root-mix/challenge draws. Prior transcripts show that ownership
transfers, generic inversion chains, terminal-only folds, and further tail
micro-fusion either failed or were too small. The remaining fold kernel is:

```text
out = left + right + alpha * ((left - right) * inverse_x)
```

`inverse_x` is base-field, but `alpha` is a full random QM31 element. The only
full extension multiplication is `alpha * difference`; both Zig and MSL use
the same two-level Karatsuba tower, totaling nine M31 products. The current
investigation therefore profiles that exact live primitive and its fold
context before choosing between a cross-lane code-generation rewrite and a
larger ownership/dispatch change.

## Falsified arithmetic and unrolling candidates

Live Zig counters measure one dependent QM31 multiplication at 9.219 ns,
154.4 instructions, and 33.97 cycles; four independent chains reach 7.353 ns
per operation and compile to 82.9% NEON. On Metal, a FRI-sized 8,192-thread
grid performs one QM31 multiplication in about 0.0039 ms. Replacing the
widened M31 product with explicit 32-bit low/`mulhi` reconstruction regressed a
sixteen-multiply chain from 0.092 to 0.113 ms and the real-sized one-multiply
grid from 0.0039 to 0.0126 ms. The runtime compiler already lowers the bounded
widened multiply well, so this direction is rejected.

Likewise, forcing BLAKE2s's ten rounds to unroll regressed an 8,192-parent grid
from 0.0323 to roughly 0.0388 ms, a 128-parent grid from 0.0079 to 0.0118 ms,
and a one-parent grid from 0.0273 to 0.0391 ms. Compact loop code is materially
better for this GPU. Neither rejected experiment is included in production.

A full-proof host sample confirms that wide CPU composition remains hot in the
component recurrence. Its obvious operation-count fix is reuse of adjacent
squares, but that implementation lives under manifest-locked `src/examples`;
it is not an eligible carrier. Metal cascade instrumentation instead measures
only about 0.04 ms of host preparation and 0.02 ms of encoding versus roughly
2.34 ms steady GPU execution. Buffer pooling therefore has too little ceiling.

## Metal design brief: four-lane cooperative shallow BLAKE2s

The selected design preserves the exact BLAKE2s and binary-Merkle algorithms
and changes only their mapping onto Apple GPU SIMD lanes. The unit is one
parent compression in the existing one-threadgroup upper tail. At levels with
more than eight parents, the current one-thread-per-hash mapping remains. Once
at most eight parents remain, each four-lane quad cooperatively owns one hash:
the four independent column G functions execute in parallel, lane shuffles
rotate `(b,c,d)` into the diagonal schedule, the four diagonal G functions run
in parallel, and inverse shuffles restore the column layout.

Resource and ownership model:

- no new device buffer, command buffer, encoder, pipeline, or proof-owned
  allocation;
- the existing tail arena remains the only globally materialized tree owner;
- dynamic threadgroup scratch is raised to a 512-byte minimum so it can retain
  sixteen child hashes at the cooperative boundary;
- dispatch width is at least one 32-lane SIMDgroup, while large tails retain
  their existing width and 8 KiB maximum scratch;
- every logical hash is still written to its existing arena offset for later
  decommitment; inactive lane quads never publish data.

Dispatch and synchronization model are unchanged: 32 physical cascade grids,
one encoder, one command buffer, one wait, and the same buffer barriers. The
optimization occurs inside the already-serialized upper-tail kernel. The
existing eight buffer bindings and exported function name are unchanged; the
new `thread_index_in_simdgroup` input is a Metal builtin, not a host ABI slot,
so source-JIT/AOT argument layout and function inventory remain stable.

The compute-only design assumes the existing reflected SIMD width of 32 and
uses four-lane subgroups entirely within it. A randomized independent model
checked 100 compression states/messages at both 64- and 128-byte counters and
matched scalar BLAKE2s exactly. A real-device isolated log-9 tail moves from
0.1400 to 0.1297 ms (7.4%). Falsifiers are any source-JIT compile failure,
root/challenge/proof digest drift, GPU validation error, dispatch change,
reflected width incompatible with four-lane quads, or end-to-end Metal S3
interval that does not clear the promotion threshold.

## Frozen candidate validation and screen

The candidate changes only the existing Metal shader and the two host-side
tail launch sites. Large levels retain one thread per parent. For levels with
at most eight parents (after the global-arena level), one SIMDgroup executes
up to eight four-lane cooperative compressions. Both host paths guarantee at
least 32 launched threads and 512 bytes of dynamic threadgroup scratch. The
generic no-prefix Merkle path selects the ordinary BLAKE2s initialization;
prefixed proof-tree paths retain node-seed initialization.

Correctness and toolchain gates pass:

- `zig build test -Doptimize=ReleaseFast` (356 transitive sources);
- `zig build test-native-metal -Doptimize=ReleaseFast`, including device prove
  and independent verification;
- `zig build metal-check`, `zig build test-metal-core-aot`, and
  `zig build test-metal-core-aot-probe`;
- `zig fmt --check src` and `git diff --check`;
- Metal API Validation and Metal GPU Validation on a deep proof, with zero
  fallback and the exact frontier proof hash
  `d63a2c928461548edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`.

The broad Metal suite reaches 81/84 with two expected skips and the known
frontier-equivalent `secureColumnUsesResidentMerkle` policy assertion. All
three benchmark classes independently verify and remain byte-identical to the
predecessor: small uses 18 dispatches, wide 22, and deep 24, all with zero
fallback.

A same-clock wide screen measures 11.481 ms on the predecessor and 11.180 ms
on the candidate (2.6%). Five matched stage profiles measure FRI at 4.032 ms
versus 3.721 ms (7.7% lower), while total proving moves from 11.642 ms to
11.350 ms. Composition commitment also moves from 1.566 ms to 1.477 ms,
consistent with reuse of the generic Merkle tail. These are screening results;
the promotion decision is reserved for the clean counterbalanced S3 verdict.

## First clean verdict and aggregate extension

Frozen first implementation `9b4d59836464` retained cooperation inside one
SIMDgroup. Its clean wide S3 result was 0.9789 with 95% CI
`[0.9522, 1.0104]`; deep was 0.9801 `[0.9391, 0.9916]`. Both were favorable,
fully verified, and byte-identical, but neither cleared the required upper
confidence boundary. They were not submitted as significant results.

The restriction to eight parents avoided an in-place compaction hazard:
different SIMDgroups may progress independently, so a fast group can overwrite
words another group has not yet consumed. The aggregate design keeps each
cooperative output in registers, waits at a full threadgroup barrier after all
message reads, then publishes the compacted parents. Cooperation can therefore
expand safely whenever `4 * parent_count` fits the existing threadgroup. The
same launch now uses lane quads at the 16/32/64-parent levels while retaining
scalar mapping for large levels. No new buffer, grid, encoder, or wait is
introduced.

Final candidate `febe81084d14` passed the source-JIT Native Metal lifecycle and
independent proof verification. Its clean Metal-deep S3 run against exact
predecessor `c2d29013ff5b` produced 0.9732 with 95% CI
`[0.9600, 0.9821]` over fifteen alternating pairs. All timed samples verified,
cross-arm proof digests were byte-identical, 12/12 guards passed, topology
remained 24 dispatches, and CPU fallback remained zero. This aggregate result
clears the one-percent significance requirement and is selected for immediate
submission.

## Current-main policy refresh

After the first package, `stwo-perf submit` detected that `origin/main` had
advanced by ten harness/correctness commits. The canonical checkout was safely
updated from `c2d29013ff5b` to `f7cfb67de953`; the two pre-existing untracked
research notes were moved aside for the fast-forward, restored byte-for-byte,
and retained their SHA-256 digests. The exact two Metal source commits were
then cherry-picked onto current main as `d88b144` and `6744edd`, and an
independent predecessor worktree was frozen at `f7cfb67`.

Both current-main worktrees passed `stwo-perf setup`. The fresh current-policy
Metal-deep S3 verdict used candidate `6744edd66aa5`, predecessor
`f7cfb67de953`, and harness `dd5d524a2e57`. Fifteen alternating pairs measured
4.718 ms versus 4.554 ms, giving ratio 0.9663 and 95% CI
`[0.9564, 0.9758]`. The pinned correctness oracle passed, every timed proof
verified with identical cross-arm bytes, G1--G5 passed, and all 13/13 current
regression guards stayed within budget. This 3.37% result supersedes the older
policy snapshot and is the sole verdict selected for the final package.
