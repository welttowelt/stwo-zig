# Session transcript — bit-reversed coset walk for lazy quotient evaluation

Agent lane: KIMI APOLLO (kimi-code CLI), 2026-07-21. Local coordination via
`.stormforge/stwo-autoresearch-mailbox` (CLAUDE-MERSENNE = research boss and
submission authority; CODEX ANVIL = leaf/leaf-hash lane; OLI = owner).
This transcript is reasoning-first: why each change was made, the evidence
behind it, and what was rejected. Machine: Apple M4 Pro (12 cores), macOS,
Zig 0.15.2, Python 3.12.12, ReleaseFast.

## 1. Intake and lane assignment

Goal from `autoresearch/TASK.md`: make the CPU prover faster on `core_cpu`
(small wf_log10x8, wide wf_log14x32, deep plonk_log14), byte-identical
proofs, edits only inside MANIFEST editable paths.

Frontier at session start (claimed ledger): small 1.418 ms, wide 9.341 ms,
deep 6.292 ms; canonical tip `9046758f0def`. Prior merged knowledge was read
first: `stwo-perf notes` (incl. the 2026-07-20 attribution note listing
rejected packed-FRI-fold, accumulator-ownership, CM31 batch-inversion,
conjugate-pair quotient points, cached inverse twiddles), plus the merged
submission notes for bounded-m31-reduction, paired-circle-basis-reuse-cpu,
and qm31-direct-lane-base-multiply.

Two other local lanes were active: CLAUDE-MERSENNE (boss, FRI/Merkle,
PR #45 cpu-merkle-subtree-scheduling) and CODEX ANVIL (leaf interface).
Per mailbox steering (16:58Z), Apollo owns `src/prover/pcs/quotients/**` and
the quotient tile/row executors; Merkle/tree-build and poly/** belong to
Mersenne; leaf hashing interface belongs to Anvil. Lane boundaries are by
editable directory to prevent diff collisions.

## 2. Fresh attribution (before editing anything)

Stage profiles (`--profiled`, median samples) on the promoted state:
- wide 12.03 ms: composition_evaluation 2.36 (locked, see below), FRI
  quotient build+commit 3.85, composition_commit 1.32, main_trace_commit
  2.80 (interpolate 0.43 / extended eval 0.97 / merkle 1.39),
  interpolate_and_split 0.47, sampled_value 0.41, pow 0.26.
- deep 7.69 ms: FRI quotient stage 3.45 (44.8%), merkle commits ~2.4.
- small 1.61 ms: FRI quotient stage 0.71 (44%), pow 0.23 (14%).

Temporary env-gated timers (STWO_FRI_DIAG, reverted) decomposed the FRI
stage: quotient tiles+leaves ~0.76 ms, upper tree ~0.5-0.8 ms, inner-layer
Merkle ~1.7-2.1 ms (wide/deep). The Merkle share is Mersenne's lane.

Temporary timers inside `quotient_tile_executor.executeBatched`
(STWO_Q_DIAG, reverted) split the quotient compute per 12-worker steady
state on wide: domain point generation ~70 us, denominator prep+inversion
~38 us, packed numerator accumulate ~105 us, finalize ~27 us, leaf-sink
emit ~133 us (emit = leaf hashing = Anvil/Mersenne territory).

## 3. Bounds discovered (rejected before attempting)

- `composition_evaluation` (2.36 ms on wide): the row loop lives in
  `src/examples/wide_fibonacci/component.zig` — NOT in MANIFEST
  editable_paths. Same for plonk. Cannot be parallelized or restructured
  from editable paths. Rejected.
- PoW grind (0.23-0.30 ms/class): `src/core/channel/blake2s.zig` — NOT
  editable, and already thread-parallel with prefix caching. Rejected.
- FFT butterfly kernels (`src/prover/poly/circle/fft_kernels.zig`): already
  4-way interleaved packed SIMD with graded fallbacks; also poly/** is
  Mersenne's lane. Rejected.

## 4. Hypothesis 1 (approved by Mersenne): incremental coset walk

Observation: every lazy-quotient row computes
`domain.at(bitReverseIndex(position, n))` via `CirclePointIndex.toPoint()`,
which costs one circle-group addition per set index bit (~7.5 on average at
n=15). Point generation was ~19% of my lane's quotient compute.

Derivation: positions p-1 -> p flip the c trailing ones of p-1
(c = ctz(~(p-1))) plus bit c. In n-bit bit-reversed index space the delta is
delta_br(c) = 2^(n-c) + 2^(n-1-c) - 2^n (mod 2^n). Domain points satisfy
at(idx) = s * Q(idx mod half) with Q(j) = P(initial + j*step), and Q has
period half (half*step = full circle order = identity). So each step is one
group addition with a precomputed point delta_pt[c] = P(delta_br(c)*step),
wrapped by conjugations when the sign branch changes. Identical group law =>
byte-identical points, not approximations.

S1 falsification (stwo-prof isolates wired to live repo modules):
- arm A (direct at(bitReverseIndex)): 25.54 ns/op, 359.5 instr/op,
  100.4 cycles/op.
- arm B (walk): 4.45 ns/op, 56.1 instr/op, 17.5 cycles/op.
- equivalence: chained accumulators over 2000 iterations x 32768 points
  identical (c6b31e2026c68821). Verdict: 5.7x fewer ns, 6.4x fewer
  instructions; mechanism confirmed, not just a wall delta.

## 5. Candidate implementation

New file `src/prover/pcs/quotient_domain_walk.zig`:
`BitReversedCosetWalk.init(domain, log_size, start)` seeds the first point
directly (any span start, including non-power-of-two worker spans) and
precomputes log_size delta points; `next()` emits the current point and
advances with one group add plus sign-branch conjugation. Advancing past the
domain end is a guarded no-op.

Call sites rewired (all four hot generators, identical semantics):
- `quotient_tile_executor.zig`: `executeBatched`, `executeScalar`
  (also dropped the now-unused `core_utils` import).
- `quotient_row_executor.zig`: `executeMaterialized`,
  `executeMaterializedScalar`, `executeStreaming`, `executeStreamingScalar`.

Unit tests in the new file: byte-identical walks vs direct
`domain.at(bitReverseIndex)` for log sizes {1,2,3,4,5,11,15}, full domains
and arbitrary non-aligned starts (1, 7, 2731, half-1, half, size-3).

Bench conformance after the change (functional protocol, ReleaseFast):
small 91741aec9568, wide 57a7d291eb8a, deep d63a2c928461 — all fixed
digests match, every sample verified.

## 6. Measured effect (paired S3, predecessor 8e58d7015e28)

All three classes passed G1-G5 with 13/13 regression guards green; every
timed sample verified and cross-arm digests byte-identical.

| class | rounds | ratio | 95% CI | theta | verdict |
| --- | ---: | ---: | ---: | ---: | --- |
| small | 15 | 0.9872 | [0.9694, 1.0065] | 0.0373 | confirmed-neutral |
| wide | 7 | 0.9871 | [0.9778, 0.9992] | 0.0293 | confirmed-neutral |
| deep | 15 | 0.9870 | [0.9636, 1.0067] | 0.0183 | not significant |

The mechanism is real and uniform (~1.3% per class, matching the ~19%
point-generation share of quotient compute) but below this host's per-class
theta. Deep has the loosest floor (1.8%); a compounded quotient package
(walk + accumulation fusion + finalize vectorization) is the follow-up aimed
at deep. Confirmed-neutral is recorded honestly rather than rounded up.

## 7. Coordination notes

- Apollo's first S3 batch (wide/deep/small vs predecessor ../stwo-zig @
  9046758) self-started ~17:08Z before the slot protocol was known;
  disclosed in the mailbox with an abort offer.
- That batch failed pre-pairing: the harness invokes the Rust oracle via
  `cargo +nightly-2025-07-14`, which requires rustup's cargo ahead of
  Homebrew on PATH (Mersenne's ops note, read too late). No verdicts were
  produced. Restarted with `~/.cargo/bin` first on PATH and
  `autoresearch/.runs/latest` cleared between classes.
- PR #45 (Mersenne, claimed wide 0.8921) invalidates this baseline on merge:
  the plan is `stwo-perf update` + `sync` + re-run before packaging.
- Submission authority stays with CLAUDE-MERSENNE per Oli's 16:53Z grant;
  Apollo packages locally and hands off via the mailbox.

## 8. Rejected alternatives this session

- Composition row-loop parallelization: locked path (examples/).
- PoW grind changes: locked path (core/channel/), already parallel.
- FRI Merkle upper tree / inner layers: Mersenne's lane (PR #45 territory).
- Leaf-sink/leaf hashing side of the tile pipeline: Anvil's lane; the
  leaf-row transfer was falsified at S1 (Anvil 17:01 entry).
- FFT kernel re-vectorization: already 4-way packed; poly/** is Mersenne's.

## 9. Compound attempts after the neutral S3 (all falsified at S1)

The walk's uniform ~1.3% sat below every per-class theta (small 3.7%, wide
2.9%, deep 1.8%). Three follow-up mechanisms in the lane were evaluated with
stwo-prof isolates wired to live repo field arithmetic:

(a) Batch-fused numerator accumulation: register-resident numerator planes
across all same-batch column contributions, cutting plane RMW traffic ~7x.
Result: 15.7 vs 17.4 instructions/op but cycles tied (3.58 vs 3.62) — the
accumulate loop is ALU-port saturated at IPC ~4.8 with L1-resident planes.
Rejected: no wall win.

(b) 4-chain local-seed parallel-scan Montgomery batch inversion (prepare
stage): interleaved independent prefix/backward chains, seeds derived from
one shared inversion by exact field arithmetic (outputs byte-identical,
chained ACC equality verified for both the grouped and interleaved
variants). IPC rose 2.2 -> 2.6 but cycles fell only ~12% on the inversion
slice, ~0.04% end-to-end on deep. Rejected: below any useful floor.

(c) Packed denominator computation and finalize/writeRow vectorization:
analysis only, ~0.2-0.3% on deep projected; walk + all three compounds
(~1.8%) still does not robustly clear deep theta (0.0183) given run-to-run
CI width. Not built.

Conclusion: the quotient-compute lane on this host offers no mechanism
above ~1.5%. The walk remains the session deliverable; a deep re-run in a
quiet window was taken for a tighter CI, reported both ways.

## 10. Re-baseline and self-submission (Oli directive)

After the lane-closed handoff, upstream PR #46 (fft-bottom-layer-fusion,
Mersenne's lane) merged and recorded "neutral (claimed)". Oli then directed:
"whoever has the win or most crucial thing of the win must submit it if
able" — superseding the bundle-and-wait strategy. The coset walk is Apollo's
win; it is submitted directly via Path A (fork PR from welttowelt).

The workspace was re-baselined: canonical updated to 2ab16c6, workspace
reset to HEAD with ONLY the walk diff re-applied (the `stwo-perf sync`
restore of editable paths from the last promoted commit 5f0841b4 was undone
for non-walk files so the candidate equals HEAD + walk exactly, keeping the
paired predecessor honest). A fresh three-class S3 batch was run against
the fresh canonical tip before packaging; verdicts are in
~/runs/2026-07-21-qwalk/verdict-{wide,deep,small}-r3.json.

## 11. Continuation: packed finalize (post-#49 session block)

Oli directed work to continue while PR #49 monitors. Two compound pieces
were S1-evaluated; one won:

Packed finalize (WINNER): the executeBatched finalize loop repacked four M31
planes into a scalar QM31 per row, then ran scalar QM31/CM31 arithmetic per
row. The replacement keeps numerators in coordinate planes and finalizes
VEC_WIDTH rows per pass with Karatsuba CM31 multiplies over Vec4 lanes (the
same exact field operations as scalar CM31.mul and finalizeRowQuotients).
S1 (256-row tiles, batch_count=1): 30.35 -> 15.49 ns/op, 149.3 -> 63.9
instructions/op, cycles 76.4 -> 31.2; chained outputs byte-identical
(ACC 21949786593e36d3 both arms). Implemented in
quotient_tile_executor.executeBatched with a scalar remainder tail; a
conformance test compares packed groups against scalar
finalizeRowQuotients at batch counts 1/2/3 (16/16 quotient suite green).
Fixed proof digests unchanged on all three scored workloads.

Packed denominators (deferred): the denominator-value computation in
prepare is the same scalar-CM31 shape and likely ~2x-able for ~0.1%
end-to-end; deferred behind the finalize measurement.

Sequencing note: the compound candidate = coset walk (PR #49, pending
maintainer merge) + packed finalize. If #49 merges first, the finalize
ships as its own PR on top; otherwise it ships as a superset candidate and
#49 is closed in its favor.
