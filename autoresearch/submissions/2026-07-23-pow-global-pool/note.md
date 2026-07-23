# Reuse the prover work pool for proof of work

## Model and harness

Model: OpenAI GPT-5 (Codex). The candidate was built from canonical main
`0c030ee1c1ae` and measured with the repository-resident `stwo-perf` harness
at commit `8d20dbf7f600`, Zig 0.15.2, ReleaseFast. The final paired S3 ran on
an idle 16-core Apple Silicon host from a clean canonical-origin clone.

## Hypothesis

The functional protocol's Blake2s proof-of-work search creates and joins a
fresh set of OS threads for every proof. Earlier proving phases already use a
persistent global worker pool, and the pool's own module says it replaces
separate FFT, Merkle, and PoW pools, but the PoW call site never routes work
through it.

For the small proof, PoW was about 0.25 ms, roughly 23% of prove time. Reusing
the live pool should remove fixed thread lifecycle overhead without changing
the nonce search, transcript, hash, or proof. Elicit literature on task
granularity supported the direction but supplied no transferable magnitude;
the paired full-proof run was the deciding evidence.

## Changes

`src/prover/pcs/proof_of_work.zig` now recognizes the raw Blake2s channel and,
when the global prover pool is available, assigns one strided nonce residue
class per worker. The caller executes residue zero while the existing pool
executes the remaining residues. All workers atomically lower a shared bound
and join before return, preserving the globally lowest valid nonce independent
of scheduling.

The nonce-invariant prefix is computed once, and each candidate hashes the
same 40-byte prefix-plus-nonce message as current main. The explicit
`STWO_ZIG_POW_WORKERS` override, generic channels, single-threaded builds, and
pool-unavailable execution retain the original channel path. Focused tests
compare the result with the original grinder across difficulties and worker
counts and bind it to changed transcripts.

There is no cross-request nonce cache, SIMD-width threshold, protocol change,
or core-channel edit.

## Results

The exact-main local S1 reported a prove ratio of **0.8650**, 95% CI
**[0.8343, 0.9061]**, with medians of 1.048 and 0.905 ms. Request time fell
to 0.8823, energy to 0.7966, and peak RSS to 0.9583. Proof bytes and digest
were identical.

The final Studio S3 with automatic guards reported a prove ratio of
**0.9358**, 95% CI **[0.9175, 0.9518]**, with medians of 0.965 and 0.903 ms
across 20 balanced rounds. Request time fell to 0.9473, energy to 0.8760, and
peak RSS to 0.9645. All 13 impact-mapped regression guards passed their 1.05
upper-CI budgets. Every timed proof verified, cross-arm proof digests were
byte-identical, the pinned Rust oracle passed, and G1-G5 were green.

Core, prover, Native CPU product, and source-conformance closures passed. A
post-run fetch confirmed both the predecessor and canonical `origin/main`
remained `0c030ee1c1ae`; candidate `92b18a7a1f51` was a clean descendant.

## Caveats

This is a local claimed verdict; the project judge's rerun is authoritative.
The win is concentrated in the small class because fixed thread lifecycle
cost is a larger fraction there. Wider guard rows were neutral or modestly
faster and are not claimed as separate class records.

The optimized path applies only to the raw Blake2s channel and the default
worker policy. An explicit PoW worker override deliberately selects the
original implementation. The prover-side prefix helper mirrors the locked
core-channel construction; equality tests and whole-proof byte identity guard
against drift, but a future protocol change must update both paths together.
