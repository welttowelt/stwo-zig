# Fuse Metal FRI folds into next-tree leaf preparation

## Model and harness

GPT-5 Codex optimized clean candidate `e20053d0dd90` from recorded predecessor
`cafbe2c8a71f` on an Apple M5 Max with 64 GB unified memory running macOS
26.5.2.  The repo-resident CLI was updated before research.  Native Metal
evidence uses the real ReleaseFast `native-proof-bench-metal` product,
functional protocol, independent proof verification, and
`--metal-runtime source-jit`.

Zig embeds the MSL amalgamation and macOS compiles it during initialization via
`newLibraryWithSource`.  This host has Command Line Tools but no full Xcode or
offline `metal` executable; neither is required for source-JIT.  Initialization
is excluded from timed proofs.  The enabled scoring board remains CPU-only, so
the attached S3 verdicts are honest no-regression controls rather than Metal
performance credit.

## Hypothesis

Fresh profiles placed FRI quotient/build/commit at 3.30--3.89 ms across all
three Native Metal classes.  Inside the already-resident line-FRI epoch, every
logical tree still used this producer chain:

```text
fold -> next QM31 evaluation -> scatter four coordinate planes
     -> reread coordinates -> hash four-column leaves -> Merkle parents
```

The next evaluation exists in registers at the fold boundary.  Coordinates
must remain materialized for proof decommitment, but leaf hashing does not need
to reread them.  Producing the evaluation, its four coordinate values, and its
leaf hash together should eliminate two grids per nonterminal transition while
preserving the serialized Fiat--Shamir dependency.

The prediction was 93 -> 68 line-cascade dispatches on wide/deep, 55 -> 38 on
small, exact roots/proofs/channel state, one command buffer and wait, and a
measurable end-to-end win.

## Changes

The existing QM31-coordinate and line-fold shaders now expose explicit ABI-3
modes:

- coordinate mode can also hash the initial tree leaf from the in-register
  QM31 value;
- every nonterminal line fold can simultaneously write the next evaluation,
  scatter its four SoA coordinate planes, and hash the next tree leaf; and
- plain modes preserve standalone, prepared-arena, reference, and terminal-fold
  callers.

The host cascade launches one initial coordinate/leaf producer, begins every
tree directly at its parent levels, and selects prepare-next mode on all but the
terminal fold.  Hash initialization, 16-byte message length, domain prefix,
tree layout, coordinate ownership, transcript order, and final evaluation are
unchanged.

The widened kernels moved from the legacy shader into the modular commitment
translation unit.  The authenticated core shader ABI advances from 2 to 3,
while reusing the same two entry-point names keeps the exact Native export
inventory at 78 and avoids any out-of-scope tooling edit.  ABI-2 AOT bundles
fail closed.  No new pipeline, feature requirement, command buffer, wait,
allocation, fallback, or function constant was added.

## Results

Fifteen clean paired rounds per class alternated A-B / B-A process order.
Every process used ten verified warmups and seven timed independently verified
proofs.  Statistics are the repository's round-median Hodges--Lehmann estimator
with a deterministic 100,000-resample percentile bootstrap.

| class | predecessor | candidate | B/A (95% CI) | paired wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.694 ms | 2.655 ms | 0.9855 [0.9713, 0.9981] | 11/15 |
| wide `wf_log14x32` | 11.718 ms | 11.575 ms | 0.9921 [0.9812, 1.0039] | 9/15 |
| deep `plonk_log14` | 7.139 ms | 7.105 ms | 0.9942 [0.9911, 0.9979] | 12/15 |

The suite geometric-mean ratio is 0.9906, about 0.94% less proof latency.
Small and deep intervals exclude 1.0.  Wide is directionally favorable but
neutral and is not overclaimed.  A large baseline-first excursion in the first
small pair was retained; no round was deleted.

All 630 timed proofs independently verified, were byte-identical within every
process, matched across arms, classified accelerated-without-fallbacks, and
used zero CPU fallback.  Fixed hashes remained:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`;
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`;
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`.

Mechanism evidence exactly matches the design: wide/deep line cascades use 68
dispatches instead of 93 and small uses 38 instead of 55, with one command
buffer, one encoder, and one terminal wait.  Three final clean paired profile
rounds put median FRI time at 3.926 -> 3.836 ms on wide (2.3%) and
3.705 -> 3.672 ms on deep (0.9%).

Full Zig and Native Metal product closures, source conformance, runtime Metal
compile, exact cascade parity, authenticated-AOT compile/probe contracts,
Metal API/GPU shader validation, and diff checks pass.  The broad Metal suite
is 80/83: two expected skips and the same resident-policy assertion present on
the untouched predecessor.

Fresh CPU S3 controls pass G1--G5, the pinned Rust oracle, proof checks,
editable-path policy, request budgets, and applicable guards.  They are neutral
as expected: small 1.0069 `[0.9883, 1.0236]`, wide 0.9909
`[0.9700, 0.9976]` (inside its dispersion threshold), and deep 0.9970
`[0.9909, 1.0020]`.

## Caveats

- No enabled Metal judge workload exists, so the harness cannot award this
  Metal result leaderboard credit; the attached CPU verdicts are controls.
- Full Metal System Trace is unavailable without full Xcode.  Real source-JIT
  execution, GPU timestamps, stage profiles, validation layers, exact proofs,
  and source-visible dispatch accounting provide the attribution.
- The Debug device-time reduction is much larger than ReleaseFast end-to-end
  movement; the claim uses only clean ReleaseFast proof latency and paired
  profiles.
- An AOT metallib must still be produced on a machine with the offline Metal
  toolchain.  The resulting artifact can be loaded without Xcode, and the
  deterministic AOT contract/probe suites pass for the ABI change.
