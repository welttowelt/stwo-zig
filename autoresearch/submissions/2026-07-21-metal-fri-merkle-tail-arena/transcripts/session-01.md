# Session 01 — extending the resident FRI epoch through the first layer

Date: 2026-07-21
Model: GPT-5 Codex

## Objective and clean frontier

Continue the user's Metal-backend optimization loop immediately after the
sampled-value batch epoch merged and was recorded. The canonical updater moved
main from `bbb8c8823cca` to recorded frontier `564cea426cf4`; the preceding
submission is now listed neutral on the CPU-only judge board, while its Native
Metal evidence remains a 0.9152 suite ratio. A fresh worktree and branch
`autoresearch/metal-epoch3` were created at the exact recorded frontier, and
repo setup passed before source work.

The same five repository skills remain active: algorithm matching, Metal
profiling, Metal performance design with the complete compute common-pattern
reference, Zig profiling for host attribution, and reasoning-first submission
transcripts. The prior iteration's durable note and packaged transcript are the
immediate research prior. No production source has been edited.

## Initial hypothesis pending fresh attribution

The merged frontier's last profile left FRI quotient/build/commit at roughly
4.2 ms wide and 4.6 ms deep, now the largest common residual. The existing
resident line-FRI cascade starts only after the quotient column has been
computed/committed, its root mixed on CPU, a circle challenge drawn, and the
circle evaluation folded into a line evaluation. The next question is whether
that complete prefix can join the resident cascade without changing any
Fiat--Shamir state, proof byte, tree lifetime, or fallback contract. A fresh
benchmark and source dependency map come before selection or editing.

## Fresh frontier benchmark and device attribution

The untouched recorded frontier was rebuilt as the production ReleaseFast,
source-JIT Metal product and run locally before source work. Ten warmups and
three timed, verified proofs gave 6.832 ms small, 12.573 ms wide, and 7.606 ms
deep. All samples matched the established proof hashes, reported no fallback,
and retained one physical sampled-value epoch and one physical line-FRI epoch.
Fresh stage profiles put FRI at 3.746, 4.205, and 3.971 ms respectively; it is
still the largest residual common stage.

A Debug host build was then used only to expose the backend's command-buffer
GPU timestamps after five proof warmups. A steady wide proof reported about
0.63 ms for quotient plus its first Merkle tree, 0.04 ms for the circle fold,
and 3.65 ms for the resident thirteen-tree line cascade. The cascade encodes
169 dispatches in one command buffer. These timestamps are device attribution,
not verdict timing: Debug host preparation is intentionally excluded from any
performance claim.

## Algorithmic match and architecture decision

The remaining hot path is a geometric sequence of immutable Merkle reductions,
interleaved with exact transcript and line-fold dependencies:

```text
line evaluation_i
  -> coordinate planes_i
  -> leaf hashes_i
  -> parent level 1 -> ... -> parent level log_i -> root_i
  -> transcript mix/draw -> fold -> line evaluation_(i+1)
```

The root dependency prevents different trees from running concurrently, but a
Merkle tree's upper levels fit inside one Metal threadgroup. Once a level has
at most 256 parent hashes, one kernel can retain those hashes in threadgroup
memory and reduce all remaining levels with threadgroup barriers. The existing
`stwo_zig_blake2s_parent_tail_sparse` kernel already implements precisely that
mapping and is used by prepared resident Merkle plans. The FRI cascade misses
it only because each logical hash level currently lives in a separate
`MTLBuffer`, while the sparse-tail ABI addresses levels by offsets in one
arena. This is an accelerator layout mismatch rather than a cryptographic or
arithmetic problem.

Candidate comparison before production editing:

| Candidate | Physical effect | Main risk | Decision |
| --- | --- | --- | --- |
| Fuse quotient, circle, and line submissions | three waits to one; same ~4.3 ms device work | large generic FRI/quotient ownership surface | defer |
| Fuse circle into line cascade | removes one ~0.04 ms kernel submission | limited ceiling | defer |
| Generate inverse domains on GPU | removes small host preparation | more field kernels, unchanged 169 dispatches | defer |
| One offset-addressed FRI Merkle arena plus threadgroup tails | ~76 fewer dispatches and ~100 fewer buffer allocations | layer-offset/decommit correctness | select |
| New fused coordinate/leaf/tail kernel | can remove more late-tree dispatches | duplicates leaf/hash logic | follow-up only if needed |

The selected layout is:

```text
one shared FRI hash arena
+--------------------+----------------+----------------+-----+
| channel/roots/alpha| tree 0 levels  | tree 1 levels  | ... |
+--------------------+----------------+----------------+-----+
                       ^ offsets retained by each Tree handle

per tree execution
coordinates -> leaves -> large parent levels -> [<=256-parent fused tail]
                                                    |
                                                    v
                                           root slot in same arena
```

All level starts remain 256-byte aligned. Each returned tree keeps the same
logical level lengths and now references the common arena plus exact word
offsets, which the existing root, layer-copy, selective-hash, batch-decommit,
and destruction paths already support. The root slot remains inside the
transcript arena, so transcript ordering and challenge bytes do not change.
On this unified-memory device, a single shared arena has the same CPU-visible
storage mode already selected for all existing levels.

Prediction: reduce the line cascade from 169 to about 93 dispatches and improve
wide/deep end-to-end proof latency by at least 3%, with exact proof hashes,
zero fallback, unchanged logical commitment counts, and no extra command
buffer. Falsifiers are any offset/decommit parity failure, proof-byte mismatch,
memory-lifetime error, or interleaved confidence interval crossing regression.

## Implementation diagnostic and first exact result

The first arena implementation failed before proof construction completed: the
GPU transcript rejection sentinel was overwritten. Tail fusion was disabled,
then the original parent pipeline was restored, and Metal API plus GPU shader
validation were enabled; the corruption remained while the computed arena
cursor exactly matched the allocation. Instrumentation showed channel word 9
entered the command as zero and returned as a deterministic hash word rather
than the rejection value `1`.

The violated invariant was at the leaf boundary. Separate buffers had always
bound every leaf destination at byte offset zero. Once all logical levels
shared an arena, that unchanged binding made every later tree overwrite arena
offset zero, which is the channel header. Applying the returned tree's recorded
level-zero word offset fixed the fault. This diagnosis is retained because it
is the central correctness trap in converting object-per-level Metal code to
offset-addressed arenas.

The corrected path passed a full small proof under Metal API and GPU shader
validation with the canonical `91741aec...bea5700` hash. It reduced the
nine-tree small cascade to 55 dispatches. A production-size Debug attribution
run reduced the thirteen-tree wide cascade from 169 to 93 dispatches and its
steady GPU timestamp from about 3.65 ms to roughly 3.37 ms. The smaller device
gain is expected: all hashes remain, while dispatch setup/barriers and roughly
one hundred Objective-C buffer allocations disappear.

ReleaseFast process-level A/B checks used separate baseline/candidate binaries,
ten warmups and seven verified samples per arm, alternating order for seven
rounds. All proofs were exact and fallback-free. Preliminary median paired
ratios were 0.950 small (one cold baseline outlier excluded by the median),
0.980 wide, and 0.957 deep. Every deep pair improved; the earlier isolated
8.72 ms deep reading was a warm-state/order artifact, as its individual samples
continued falling from 10.66 to 7.22 ms despite the process warmups. Formal
repository statistics and clean-commit evidence remain pending.

## Frozen clean-commit Metal verdict

Production and its focused expectation were frozen in source commit
`e6aea4a37f5a` (`metal: fuse shallow FRI Merkle tails`) against recorded
predecessor `564cea426cf4`. The transcript was stashed while both exact commits
were rebuilt as clean ReleaseFast products, so every formal report asserted
both `implementation_dirty=false` and `provenance.git_dirty=false`.

Seven round pairs per class alternated A--B / B--A process order. Each arm used
ten verified warmups and seven timed verified proofs. The repository's
round-median Hodges--Lehmann estimator and deterministic 100,000-resample
bootstrap produced:

| Metal class | predecessor median | candidate median | B/A HL (95% CI) | latency reduction |
| --- | ---: | ---: | ---: | ---: |
| small, `wf_log10x8` | 2.888 ms | 2.732 ms | 0.9572 [0.9430, 1.0296] | 4.28% estimate |
| wide, `wf_log14x32` | 11.990 ms | 11.859 ms | 0.9854 [0.9651, 1.0018] | 1.46% estimate |
| deep, `plonk_log14` | 7.571 ms | 7.210 ms | 0.9489 [0.9352, 0.9587] | 5.11% confirmed |

The three-class geometric-mean ratio is 0.9637, about 3.63% less proof latency.
Deep is the formal significant claim: all seven pairs improved and its upper
confidence bound is 0.9587. Small and wide point estimates improve, but their
intervals cross one; they are reported as estimates, not confirmed claims.
Small retained one cold-state process excursion and wide had two noisy pairs,
consistent with the previously observed process-frequency behavior.

The audit covered all 294 formal timed proofs. Every sample independently
verified, was byte-identical within its process, matched the fixed cross-arm
hash, reported `accelerated_without_fallbacks`, used zero CPU fallbacks, and
retained exactly one line-FRI command epoch. Debug GPU attribution showed the
mechanism directly: wide line-FRI dispatches fell 169 -> 93; the focused
three-layer test fell 45 -> 30; command buffers and waits remained one.

## Validation and official controls

The frozen source passes `zig build test`, `test-native-metal`, `metal-check`,
both authenticated-AOT core compile/probe gates, source conformance, diff
checks, exact full-proof verification, and Metal API plus GPU shader
validation. Broad `metal-test` is 80/83 with two expected skips and only the
same pre-existing resident-policy assertion at
`resident_data_test.zig:616`; the modified line-cascade parity test passes.

The manifest still enables only the CPU board, so three official S3 CPU
controls were run with all regression guards. Each passed G1--G5, the pinned
Rust oracle, cross-arm proof-byte checks, request/RSS budgets, and all 12
impact-mapped guards:

| CPU control | ratio (95% CI) | classification |
| --- | ---: | --- |
| small | 1.0114 [0.9886, 1.0256] | confirmed neutral |
| wide | 1.0077 [0.9930, 1.0144] | confirmed neutral |
| deep | 0.9925 [0.9847, 1.0019] | confirmed neutral |

The significant result is therefore honestly Metal-local and not represented
as a CPU-board speedup. The submission packages all three neutral CPU verdicts
for suite coverage while the note carries the exact Native Metal evidence.
