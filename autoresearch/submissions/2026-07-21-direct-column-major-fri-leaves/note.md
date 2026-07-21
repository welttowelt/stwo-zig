# Fuse FRI coordinate materialization with direct four-lane leaf hashing

## Model and harness

Model: GPT-5 Codex, operating as CODEX ANVIL under the campaign's
Claude-Mersenne research lead. The candidate began from current frontier
`2ab16c66a306` in a fresh worktree. S1 used `stwo-prof` ABBA counters against
live repo imports on an Apple M4 Pro. Final S3 A/B arms ran on the same quiet
Apple M4 Max Studio with the repo-resident harness and pinned Rust oracle.

## Hypothesis

The four-lane BLAKE2s leaf builder reconstructed row messages twice: it copied
column-major M31 evaluations into four packed row buffers, then reloaded and
transposed those buffers into SIMD message vectors. Inner FRI also converted
each folded QM31 AoS line into four coordinate planes before the commit reread
the planes to rebuild the same leaf words.

Reading canonical M31 words directly into four-lane compression vectors, then
materializing FRI coordinate planes while the same QM31 rows are hot, should
remove both representation round-trips without changing any hash input,
Merkle layer, root, transcript, or proof byte.

## Changes

- `blake2s_backend.zig` and `blake2_hash.zig`: a seeded four-message word-reader
  path preserves scalar/SIMD behavior, byte counters, and terminal-block rules.
- lifted `blake2_merkle.zig`: prefixed-protocol capability gates and readers
  expose canonical four-lane words without packed byte messages.
- `leaves.zig` and `first_layer_sink.zig`: ordinary batched leaves and lazy
  quotient tiles feed column/coordinate words directly to the existing
  compressor. Plain and generic fallbacks are unchanged.
- `vcs_lifted/prover.zig`, CpuBackend, and `fri.zig`: CPU inner-FRI rows now
  materialize coordinate columns and leaf hashes in one aligned worker pass;
  the stored columns remain available for openings exactly as before.

The algorithm and protocol are unchanged. A boundary test compares packed and
word-reader hashes at 1, 16, 17, and 33 words in scalar and SIMD modes.

## Results

S1 direct leaf input:

- 32 columns: 0.9073 [0.881874, 0.952029] wall, 0.8977 cycles;
- four quotient coordinates: 0.9301 [0.879552, 0.987226] wall, 0.9190 cycles;
- 1,024-row coordinate conversion + commit fusion: 0.9562
  [0.918636, 0.988373] wall, 0.9420 instructions, 0.9515 cycles.

Final fully guarded CPU S3 against `2ab16c66a306`:

| class | workload | A ms | B ms | R (95% CI) | theta | result |
| --- | --- | ---: | ---: | --- | ---: | --- |
| small | `wf_log10x8` | 1.204000 | 1.068334 | 0.883109 [0.863699, 0.899429] | 0.037308 | significant |
| wide | `wf_log14x32` | 7.498500 | 7.354959 | 0.981701 [0.968283, 0.994015] | 0.029290 | neutral |
| deep | `plonk_log14` | 4.646709 | 4.406125 | 0.951050 [0.942025, 0.960200] | 0.018278 | significant |

Every timed proof was cross-arm byte-identical and accepted by the pinned
oracle; all 13 regression guards passed. `zig build test-stwo-core`,
`test-stwo-prover`, `test-native-cpu-product`, and the pre-iteration-two full
356-source closure passed; the final full closure is repeated before the
submission commit is pushed.

## Caveats

- Wide improves at the point estimate but does not clear its 2.929% floor; its
  neutral verdict is attached so the moved class is not hidden.
- Local G2 reports locked files already present in the unchanged anchor history;
  `git diff 2ab16c66a306..5fbf86b` contains only eight allowed source files.
- Full Metal guards cannot run because the unchanged baseline currently aborts
  `guard_blake_10x10` with `InvalidLastLayerDegree` on both available M4 hosts
  (upstream issue #50). Non-qualifying guards-none diagnostics measured Metal
  deep 0.888254 [0.878896, 0.898387] and wide 0.989285
  [0.928572, 1.036228]; they are documented in the transcript, not submitted as
  qualified verdicts.
- These are claimed/advisory results; the locked judge rerun remains
  authoritative.
