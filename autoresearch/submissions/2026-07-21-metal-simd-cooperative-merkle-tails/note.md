# Cooperate across Metal SIMD lanes in shallow Merkle tails

## Model and harness

Model: GPT-5 Codex. The repository-resident `stwo-perf` and `stwo-prof` tools
were updated to current main before final measurement. Candidate
`6744edd66aa5` is measured against exact predecessor `f7cfb67de953` on an
Apple M5 Max. Measurements use
the real ReleaseFast Native Metal product, the functional protocol, ten
warmups, independent verification, and the source-JIT runtime. macOS compiles
the embedded MSL with `newLibraryWithSource`; no offline Metal compiler or full
Xcode installation is involved.

## Hypothesis and architecture

After earlier work fused FRI producers, parent levels, and transcript work into
one command, the final Merkle levels remained a serial critical path: one GPU
thread performed all eight BLAKE2s state words for each parent while most lanes
were idle. BLAKE2s already exposes four independent G functions per half-round.
Mapping one parent to a four-lane quad should execute those four columns in
parallel, with SIMD shuffles implementing the diagonal permutation.

```text
scalar parent                       cooperative parent

thread 0: G0 G1 G2 G3               lanes 0..3: G0 | G1 | G2 | G3
          shuffle state                         SIMD shuffle
          G4 G5 G6 G7               lanes 0..3: G4 | G5 | G6 | G7
          (10 rounds)                           (10 rounds)

many compacted child hashes          four lanes per parent hash
          |                                      |
          `---- one tail grid, same arena -------'
```

The in-place tail compacts sixteen child words into eight parent words. Across
multiple SIMDgroups, an early parent write can alias a later group's unread
message. The implementation therefore retains each cooperative result in
registers, executes a full threadgroup barrier after all reads, and only then
publishes compacted parents. The shader selects cooperation whenever four
lanes per parent fit in the already-launched group; larger levels retain the
existing scalar mapping.

## Changes

- one four-lane BLAKE2s compression helper owns a 4x4 state column per lane;
- shuffle rotations map column G state into and out of the diagonal schedule;
- upper-tail launches guarantee one SIMDgroup and 512 bytes of scratch for the
  cooperative boundary;
- all available lane quads are used at later 16/32/64-parent levels, guarded by
  the reflected threadgroup width and a pre-write barrier;
- FRI and generic Merkle paths share the same optimized tail pipeline.

The BLAKE2s algorithm, seeded/unseeded initialization, hash order, transcript
order, node arena, command buffer, encoder, wait count, dispatch count, shader
export name, and eight host buffer bindings are unchanged. The added thread
builtins are not host ABI slots, so source-JIT and authenticated-AOT argument
layouts remain stable.

## Results

An independent randomized compression model matched scalar BLAKE2s for 100
states/messages at both 64- and 128-byte counters. The isolated log-9 tail fell
from 0.1400 to 0.1297 ms. A five-profile wide screen moved FRI from 4.032 to
3.721 ms before the broader multi-SIMDgroup mapping was added.

The final clean S3 Metal-deep run used fifteen alternating process pairs. Every
timed proof independently verified, cross-arm bytes matched the fixed digest,
all samples stayed accelerated without fallback, and all thirteen regression
guards passed.

| class | predecessor | candidate | B/A HL (95% CI) |
| --- | ---: | ---: | ---: |
| deep `plonk_log14` | 4.718 ms | 4.554 ms | 0.9663 [0.9564, 0.9758] |

That is a 3.37% end-to-end latency reduction and clears the one-percent
significance floor. The proof hash remains
`d63a2c928461548edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`;
the proof still reports 24 Metal dispatches and zero CPU fallback.

## Validation

ReleaseFast Native Metal lifecycle proves and independently verifies on the
final source-JIT shader. The aggregate Zig suite, Metal runtime suite,
`metal-check`, authenticated-AOT tooling and probe checks, formatting, and both
Metal API and GPU Validation passed the initial cooperative implementation;
the broader mapping preserves its helper and only expands the guarded level
range. The broad suite's sole resident-policy assertion and two stress skips
are unchanged frontier behavior.

## Caveats

The local S3 verdict is advisory until the judge reruns it. This submission
claims only the significant Metal-deep result; the first implementation's
favorable but inconclusive Metal-wide and Metal-deep intervals are retained in
the transcript and are not presented as promotion evidence.
