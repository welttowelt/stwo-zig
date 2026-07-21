# Session 01 — eighth Metal-backend architecture campaign

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and fresh grounding

PR #31 merged generic multi-block Merkle parent chains and the recorder
advanced canonical main to `f52e3a791dd7`.  The repo-resident CLI was updated
to that exact frontier before a fresh workspace passed setup.  A clean
ReleaseFast Native Metal build then ran the complete fixed source-JIT suite
with ten warmups and seven verified timed samples:

| class | prove median | request median |
| --- | ---: | ---: |
| small `wf_log10x8` | 6.524 ms | 6.779 ms |
| wide `wf_log14x32` | 11.688 ms | 12.659 ms |
| deep `plonk_log14` | 7.003 ms | 7.361 ms |

Every proof verified, provenance was clean and complete, post-warmup direct
compilation and CPU fallback were zero, and the runtime used the embedded-MSL
macOS `newLibraryWithSource` path.

Fresh seven-sample profiles show the post-merge stage distribution:

| stage median (ms) | wide | deep |
| --- | ---: | ---: |
| main trace commit | 1.811 | 0.631 |
| composition evaluation | 2.669 | 0.127 |
| composition interpolate/split | 0.477 | 0.055 |
| composition commit | 1.345 | 0.745 |
| sampled values | 0.808 | 0.664 |
| FRI quotient/build/commit | 3.891 | 3.626 |
| proof of work | 0.347 | 0.355 |
| all decommitment | 0.119 | 0.130 |

Wide composition evaluation is CPU AIR work rather than a Metal kernel.  FRI
is the largest common Metal stage and retains an architectural serialization
that can be removed without changing the protocol.

## Residual FRI graph

The wide/deep line cascade has thirteen trees, logs 14 down through 2, in one
compute encoder and one command buffer.  After the prior campaigns its 58
physical grids are:

```text
initial coordinates/leaves + 13 folds/leaves       14
multi-block bottom and/or top Merkle tails          18
root mix grids (one thread each)                     13
secure challenge draw grids (one thread each)        13
                                                    ---
                                                     58
```

Every tree's top tail is exactly one threadgroup and finishes with one root
hash in threadgroup scratch.  The next two grids are serialized only because
the host currently ends the Merkle operation at that API boundary:

```text
top-tail root --buffer barrier--> mix(channel, root)
              --buffer barrier--> draw alpha
              --buffer barrier--> fold next layer
```

## Selected root-to-challenge tail fusion

Add a dedicated top-tail-plus-transcript kernel, leaving the existing bottom
and generic tail pipeline untouched.  It performs the same parent reduction,
then thread 0 uses the final root already present in threadgroup scratch to
execute the existing Blake2s channel mix and one secure-field draw.  The
following fold grid consumes alpha after the tail's existing buffer barrier:

```text
one top-tail threadgroup

parents ... -> root in shared scratch
                    |
                    `-> lane 0: channel mix -> draw alpha
                                      |
                                      `-- global transcript arena

next grid: fold(alpha)
```

A separate pipeline is intentional.  Adding transcript locals and Blake
state to the multi-group bottom-tail kernel would raise register allocation
for every bottom thread and risk repeating the rejected producer-fusion
occupancy failure.  Only the one-group upper tail pays the wider kernel.

Production wide/deep predicts 58 -> 32 grids, removing all 26 one-thread
transcript launches and their intervening barriers.  The exact log-10 fixture
predicts 38 -> 20 while preserving nine roots, nine challenges, every
coordinate column, final evaluation, channel digest, draw count, and error
state.

The new authenticated export advances core shader ABI 3 -> 4 and native
export count 78 -> 79.  Source-JIT compilation remains local to macOS runtime
initialization; authenticated AOT tooling will validate the widened manifest
contract.  Unsupported/no-tail shapes keep the two existing transcript grids.

Falsifiers are any root/challenge/final-value mismatch, nonzero transcript
error state, validation-layer finding, AOT/export contract failure, physical
count above the model, or clean paired end-to-end regression.  Prediction:
at least 0.15 ms less FRI time on a production class and a significant
end-to-end win without changing logical telemetry or proof bytes.

## Second mechanism: carry the linear coset walker into Metal orchestration

Initial source-JIT profiling of the root-to-challenge fusion showed the exact
grid reduction and favorable deep timings, but its launch savings were partly
masked by host work between Metal epochs.  A source audit found four Metal
fold paths still constructing every inverse-coordinate input through
`domain.at(bitReverseIndex(i << 1))`.  The earlier CPU campaign had already
proved the equivalent linear coset walk: 3.823 rather than 28.177 ns per
coordinate and about 0.64 ms less CPU FRI work at log 14.  That helper remained
private, so the resident Metal cascade never inherited the improvement.

Expose narrow line- and circle-fold inverse preparation functions from core
FRI, keep the coordinate walker itself private, and make both CPU and Metal
call the same authority.  Route the Metal circle fold, generic line fold,
single fold-plus-commit, and full line cascade through those helpers.  The GPU
algorithm is unchanged; this removes repeated O(N log N) circle-group point
reconstruction from the CPU submission path feeding Metal.

```text
old Metal host path, each FRI layer
  output i -> bitReverse(i) -> reconstruct group point -> x/y -> batch inverse
             O(N log N) group additions

new shared path
  walk coset once -> scatter coordinate to bitReverse slot -> batch inverse
             O(N) group additions
```

The two mechanisms attack orthogonal serialization: the walker shortens CPU
preparation before the command buffer, while the fused tail shortens the GPU
dependency graph inside it.  Predicted combined effect is at least 0.4 ms on
wide/deep FRI and a three-class end-to-end geometric improvement above 2%.
Falsifiers are coordinate differential failures, any proof-byte drift, the
20-grid fixture changing, or clean paired FRI/end-to-end timing that does not
separate from the unchanged frontier.

## Editable-surface correction

The first implementation exported the shared preparation functions through
top-level `src/core/fri.zig`.  The complete CPU control correctly rejected
that carrier: the manifest permits `src/core/fri/**` but not the sibling
top-level facade.  This was a G2 packaging failure; its proof, oracle, guard,
and budget gates all passed.

The optimized walk is therefore kept private to
`src/backends/metal/commit_backend.zig`, using the same coset iterator,
bit-reversal scatter, and batch inversion as the already-proved core helper.
All core files and CPU call paths return byte-for-byte to the predecessor.
This preserves the Metal asymptotic improvement while making the mechanism a
strict Metal-only diff inside the editable surface.  The real Metal cascade
fixture and clean paired benchmarks must be rerun after this correction; the
prior timing is retained as discovery evidence rather than silently reused.

The first release-gate pass then found a second contract: the authenticated
Native AOT probe fixes the function inventory at 78, so a new 79th entry point
cannot be carried by the editable Metal surface.  The final design widens the
existing `stwo_zig_blake2s_parent_tail_sparse` export instead.  A three-word
configuration binding selects transcript fusion only for the one-group FRI
upper tail; generic Merkle tails and parallel FRI bottom tails bind an explicit
disabled configuration and retain the group-relative hashing schedule.

This keeps ABI 4 for the changed binding while preserving exactly 78 Native
and 90 aggregate exports, zero function constants, and AOT/JIT name parity.
The wider pipeline's source-JIT screen remains favorable (10.651 vs 11.489 ms
wide and 6.301 vs 6.967 ms deep), so the feared bottom-tail occupancy loss did
not appear at end-to-end scale.  The final commit must still receive fresh
clean pairs; these dirty-build figures are only the go/no-go screen.

## Frozen result

Final candidate `4d4dbdc54c4e` was rebuilt in a clean detached worktree and
compared with exact merged predecessor `f52e3a791dd7`. Fifteen process pairs
per class alternated A-B/B-A; every process used ten warmups and seven timed
verified proofs. The repository Hodges--Lehmann estimator and deterministic
bootstrap produced:

| class | A median | B median | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small | 2.634792 ms | 2.558583 ms | 0.97515608 [0.96610289, 0.98772320] | 13/15 |
| wide | 11.593334 ms | 10.870667 ms | 0.93713115 [0.93150563, 0.94346191] | 15/15 |
| deep | 7.002000 ms | 6.279542 ms | 0.89622707 [0.88965266, 0.90136953] | 15/15 |

The three-class geometric ratio is 0.93561575, about 6.44% less proof
latency. All 90 reports and 630 timed proofs carried exact clean commits,
complete provenance, fixed hashes, source-JIT acceleration, zero fallback,
and zero post-warmup compilation.

Final seven-sample profiles isolate the intended stage: FRI moves 3.833 to
3.097 ms on wide and 3.609 to 2.922 ms on deep, while main-trace commit is
1.833 versus 1.831 ms on wide and 0.635 versus 0.642 ms on deep. The exact
log-10 cascade remains one encoder/one command buffer/one wait and 20 rather
than 38 physical grids, with every root, challenge, coordinate column,
terminal evaluation, digest, counter, and error state equal to CPU.

The final CPU S3 control is neutral at 1.0020 [0.9925, 1.0104] and passes
G1--G5 plus the pinned Rust oracle. Full product, conformance, AOT contract,
source-JIT lifecycle, API/GPU validation, and compile gates pass. The broad
Metal suite remains 80/83: two expected skips and the same resident-policy
assertion reproduced on the predecessor.
