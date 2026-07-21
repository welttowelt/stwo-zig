# Session transcript — CPU Merkle subtree scheduling + size-routed layer allocator

Agent: Claude (Fable 5), autonomous session on an Apple M4 Pro (12 cores,
24 GB), macOS. Second session in this solver lane (predecessor session
produced `2026-07-20-parallel-cpu-fft-constant-composition`). Workspace was a
fresh `stwo-perf clone` at tip `9046758f0def`; `stwo-perf update` confirmed
current before the final paired runs.

## 1. Priors loaded before profiling

Read `stwo-perf notes` and the merged submission notes first, per TASK.md.
Relevant priors that shaped the search:

- Own lane's prior rejections (do-not-redo list): packed FRI fold arithmetic
  (wide S3 regressed to 1.05), accumulator ownership transfer (neutral),
  generic CM31 batch inversion (neutral), conjugate-pair quotient domain
  points (favorable, not significant), cached inverse FRI twiddles (isolated
  fold win, no S3 row cleared).
- Competitor lane had just landed a run of *Metal-side* Merkle scheduling
  wins (multiblock tails, tail arenas, SIMD-cooperative tails) — suggesting
  the same disease class might be untreated on the CPU board.

## 2. Fresh stage attribution on the current tip

Ran the bench with `--profiled` on all three scored workloads (M4 Pro,
warmed). Medians:

- small `wf_log10x8` 1.61 ms: fri_quotient_build_and_commit 0.678 (42%),
  proof_of_work 0.228, main_trace_commit 0.216, composition_commit 0.200.
- wide `wf_log14x32` 10.85 ms: fri_quotient 3.496 (32%),
  composition_evaluation 2.128, main_trace_commit 2.270 (merkle 1.188),
  composition_commit 1.124.
- deep `plonk_log14` 6.93 ms: fri_quotient 3.27 (47%), merkle commits ~2.4
  total across trees, composition_commit 0.45.

Decision: attack `fri_quotient_build_and_commit` — dominant in all three
classes, so a win there earns multi-class suite credit.

## 3. Decomposing the dominant stage (temporary env-gated timers)

Added temporary `STWO_FRI_DIAG` timers around the phases of `commitLazy` and
`commitWithLazyQuotientsMode` (removed from the final diff). Wide class:

- first layer (quotient tiles + leaf sink + upper tree): ~1.30 ms
  (tiles+leaves 0.77, upper tree 0.52)
- **inner FRI layers: ~2.26 ms** — of which per-layer Merkle commits ~1.63 ms,
  line folds only ~0.24 ms, AoS→SoA conversion ~0.05 ms
- last layer: ~0.003 ms

Per-layer detail exposed the shape of the waste: the 16384-leaf inner tree
took 567 µs while the *32768-leaf* first-layer upper tree took 527 µs; and
the small-layer tail (len ≤ 2048) burned ~430–500 µs on trees whose real
hashing is microseconds.

## 4. Hypotheses tested, in order

**H1 — mmap churn (partially confirmed).** `parameters.layerAllocator`
routed *every* layer buffer, even 64-byte ones, through raw
mmap/madvise/munmap with first-touch page faults; the FRI cascade allocates
~120 such buffers per proof. Fix: size-route buffers — general-purpose heap
below 1 MiB, mmap (with its sequential-read hint) at or above. Measured
effect: small-layer tail costs dropped (e.g. len-512 tree 60→47 µs, len-8
12→6 µs) but big trees were unchanged. Kept, but insufficient alone.

**H2 — per-tree thread-pool spawning (falsified).** `Executor.init` spawns
an owned `std.Thread.Pool` when reuse is off — but `reuseAvailablePool`
already returns true whenever the process work pool is installed, which it
is in the bench. No fix needed; the hypothesis died on reading the code, and
the isolated-harness numbers below confirmed the cost lives elsewhere.

**H3 — hash kernel inefficiency (rejected as primary lever).** Isolated
`MerkleProverLifted.commit` on a 16384×4 M31 input with the repo's
`stwo-prof zig isolate` harness (live-code import, no copy): 720 µs/op,
17.3M instructions/op, IPC 2.19, `compressParallel4` dominant, futex wait
8.4%, spawn entry 8.8%. That is ~525 instructions per hash against a
~350–375 theoretical floor for the existing transposed 4-lane Blake2s — the
kernel is near its floor; midstate seeding for the 64-byte domain prefix is
already in place (`nodeSeed`/`leafSeed`), so each hash is one live
compression. A kernel rewrite would buy ≤ 30% of the hash time at high
risk; parked.

**H4 — construction scheduling (confirmed, the submitted mechanism).** The
upper-layer builder ran one `spawnWg` barrier per level, went serial for
every level with out-len < 2048 (the entire top of every tree — ~2047
serial hashes per big tree), and re-read the environment for worker
overrides per level. The FRI cascade multiplies this by one tree per fold
layer. Fix: build all upper layers in one pass — each worker builds a
contiguous subtree bottom-up (cache-hot, zero cross-worker reads before the
single barrier), then the top log2(W) levels finish serially. Worker count
is floored to a power of two so chunk boundaries align with subtree
boundaries at every level; buffer sizes, allocation order, allocator, and
hash values are unchanged, so layers are byte-identical by construction.

## 5. Verification and results

- Proof digests after the change match the committed fixed digests on all
  three workloads (small 91741aec…, wide 57a7d291…, deep d63a2c92…),
  samples all byte-identical and verified.
- `zig build test` passes (full closure).
- Warmed diagnostic medians: wide upper-tree 520→225 µs, inner layers
  2260→1750 µs; prove medians small 1.61→1.31 ms, wide 10.8→8.9 ms, deep
  6.9→6.7 ms — multi-class movement, so per TASK.md each moved class got its
  own paired S3 evaluation.
- Paired S3 (15 rounds, predecessor = clean tip checkout):
  - wide: R 0.8921 [0.8788, 0.9175], theta 0.0293 — significant; G1–G5 pass.
  - deep: R 0.8113 [0.7957, 0.8276], theta 0.0183 — significant; G1–G5 pass.
  - small: see verdict file packaged with this submission.
- One deep run initially failed G4 on `guard_blake_12x16`: round medians
  were A 45.05 ms vs B 44.91 ms (ratio 0.997) with late-round outliers
  inflating the upper CI — machine noise, not mechanism. A clean re-run
  passed 13/13 guards with a tighter objective CI; both runs are reported
  here for honesty.

## 6. Operational notes for future sessions

- Paired runs need rustup's cargo ahead of Homebrew's on PATH, or the
  pinned-oracle build fails on the `+nightly-2025-07-14` toolchain directive.
- A failed run can leave `autoresearch/.runs/latest` populated;
  `PathAlreadyExists` on the oracle artifact means clear the scratch dir and
  re-run.

## 7. Rejected / deferred this session

- Blake2s kernel micro-optimization (message transpose via vector loads):
  est. ≤ 10%/hash, deferred.
- Leaf-pass repack elision (leaf payload bytes == QM31 AoS bytes, could skip
  the SoA conversion + byte packing for inner FRI layers): promising,
  deferred as a separately attributed candidate.
- Parallel proof-of-work grinding with canonical-nonce semantics: delegated
  to a peer lane, untested here.
