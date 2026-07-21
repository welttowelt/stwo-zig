# Session 01 — direct column-major four-lane leaf hashing

## Assignment and baseline

Claude-Mersenne assigned CODEX ANVIL the post-merge Merkle leaf lane after
fresh stage attribution put ordinary trace/preprocessed Merkle work at roughly
10–21% of the CPU proof, while the quotient/FRI block occupied 32–45%. The
candidate started from current frontier commit `2ab16c66a306`; no older
worktree was reused.

The functional invariant was fixed before editing: each leaf message must stay
the stable log-size-sorted sequence of canonical little-endian M31 words at the
lifted source index. The leaf domain prefix, BLAKE2s byte counters and terminal
block behavior, leaf digests, upper tree, root, proof bytes, and oracle result
could not change.

## Source trace and hypothesis

The lazy quotient first layer already hashes from its producer tile, so a
second complete quotient-column scan had already been eliminated. Ordinary
batched commitments still performed two layout transformations before every
four-lane leaf hash:

1. gather column-major evaluations into four contiguous row messages;
2. reload those messages and transpose their words into the four SIMD lanes
   consumed by the BLAKE2s compressor.

The selected hypothesis was to expose a guarded word-reader entry point for
the existing four-lane compressor. A reader supplies one canonical M31 word
for all four leaves at once, allowing the compression vectors to be assembled
directly from column-major evaluations. The same primitive can read the four
coordinate slices of a quotient tile without first creating four temporary
QM31 rows.

This is not a new hash or Merkle algorithm. It deletes a representation
round-trip while preserving the exact message word stream.

## Alternatives considered

- Fusing leaf hashing into the FFT/evaluation producer was considered first.
  It would have crossed polynomial ownership boundaries and could not discard
  the extended columns because later decommitment and sampled-value evaluation
  still require them. That was too broad for the first experiment.
- Retaining row-message packing but changing the byte transpose to different
  vector loads was narrower, but it would leave the scratch write/read in
  place. The direct reader tests the stronger structural claim with the same
  compression kernel.
- A previous retained-row representation experiment had removed instructions
  but produced neutral whole-proof wall time. This candidate therefore avoided
  another global representation rewrite and targeted only the proven copy and
  transpose boundary.
- The plain-hash protocol does not start leaf hashing from the domain-prefix
  seed. The new route is explicitly capability-gated to the prefixed protocol;
  unsupported/plain modes retain the old packed or scalar paths.

## Implementation

The crypto backend gained a generic four-message seeded BLAKE2s routine whose
reader returns the next `[4]u32` canonical word vector. It preserves scalar and
SIMD implementations, the rule that a full terminal 64-byte block remains
terminal, and the original counters beginning after the 64-byte leaf prefix.

The lifted BLAKE wrapper exposes that primitive to:

- ordinary batched leaf construction, including lifted indices for shorter
  columns;
- the first lazy quotient-layer sink, reading four coordinate slices.

All generic and plain-protocol fallbacks remain intact. A boundary test compares
packed bytes with the word reader at 1, 16, 17, and 33 words in scalar and SIMD
modes.

## S1 evidence

Two live-repo ABBA harnesses compared the exact old pack-plus-hash operation
with the new direct reader. Both confidence intervals exclude 1.0:

- 32-column ordinary leaf: wall B/A `0.9073`, CI95
  `[0.881874, 0.952029]`; cycles B/A `0.8977`; instructions B/A `1.0531`.
  The extra gather instructions are offset by removal of scratch traffic and
  the second transpose, yielding 9.3% lower wall time.
- four-coordinate quotient leaf: wall B/A `0.9301`, CI95
  `[0.879552, 0.987226]`; cycles B/A `0.9190`; instructions B/A `0.7525`.
  This separately falsified the risk that the generic reader overhead would
  regress short leaf messages.

Artifacts: `anvil-leaf-packed` versus `anvil-leaf-direct`, and the corresponding
four-coordinate harnesses, in the local `stwo-prof` cache. Durable findings and
the problem-match brief are in the campaign state for `anvil-record2`.

## Correctness and qualification state

Before paired end-to-end measurement, all of the following passed at candidate
commit `3f6a362`:

- `zig build test-stwo-core -Doptimize=ReleaseFast`;
- `zig build test-stwo-prover -Doptimize=ReleaseFast`;
- `zig build test-native-cpu-product -Doptimize=ReleaseFast`;
- `zig build test` (356-source closure).

An attempted S2 command was rejected before execution because the harness
reserves S2 as diagnostic-only and accepts only S1 kernels or S3+ proofs. No
result was inferred from that non-run.

The first Studio S3 pass showed the direct reader alone was real but below the
whole-proof floor: wide 0.9770 [0.9615, 0.9884] and deep 0.9851
[0.9765, 1.0057]. The host was released without a reroll. That miss identified
the unfinished structural pass: each inner FRI line evaluation was still
converted from QM31 AoS to four M31 coordinate planes, after which the ordinary
commit path reread those planes to form leaf messages.

Iteration two added a CpuBackend hook that materializes the coordinate planes
needed for openings while hashing each QM31 row into its leaf. Work partitions
are aligned to four rows; each worker decodes one four-row group, writes its
four coordinate slices, and passes the same register-resident words to the
four-lane BLAKE2s reader. Generic and Metal backends retain their existing
conversion/commit path. A live-repo 1,024-row ABBA of old conversion+commit
against the fused path measured wall B/A 0.9562, CI95
[0.918636, 0.988373], instructions 0.9420, cycles 0.9515. The prover and native
CPU ReleaseFast closures passed before freezing combined commit `5fbf86b`.

## Final paired evidence

All CPU A/B arms ran on the same quiet M4 Max Studio against predecessor
`2ab16c66a306`. Every timed proof was byte-identical across arms and accepted
by the pinned oracle; all 13 regression guards passed:

- small `wf_log10x8`: 1.204000 -> 1.068334 ms, R 0.883109, CI95
  [0.863699, 0.899429], theta 0.037308, 10 rounds — significant;
- deep `plonk_log14`: 4.646709 -> 4.406125 ms, R 0.951050, CI95
  [0.942025, 0.960200], theta 0.018278, 9 rounds — significant;
- wide `wf_log14x32`: 7.498500 -> 7.354959 ms, R 0.981701, CI95
  [0.968283, 0.994015], theta 0.029290, 8 rounds — moved but neutral.

The run recorder's G2 field named repository-wide locked files that are already
present in the unchanged predecessor/anchor history; `git diff
2ab16c66a306..5fbf86b` contains only the eight allowed source files. This is
the same current anchor-registry drift observed by parallel submissions; it is
reported, not hidden.

Because the diff also touches shared hashing and FRI control flow, the campaign
required Metal measurement. A normal Metal run could not reach the objective:
the unchanged predecessor aborts mandatory `guard_blake_10x10` with
`InvalidLastLayerDegree`, independently reproduced on both M4 hosts and filed
as issue #50. Guards-none diagnostics were therefore labeled non-qualifying:
Metal deep 0.888254 [0.878896, 0.898387], Metal wide 0.989285
[0.928572, 1.036228]. They are retained as attribution evidence but are not
attached as qualified submission verdicts.
