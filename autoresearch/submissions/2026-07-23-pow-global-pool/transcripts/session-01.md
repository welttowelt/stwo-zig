# Session 01: replacing per-proof PoW threads with the prover pool

## Objective and freshness rule

The user required every experiment to start from the latest canonical main.
Before each build, evidence run, and seal, the campaign freshness gate fetched
canonical main and required the candidate to descend from it. Main advanced
during an earlier PoW experiment, so that evidence was discarded and the
candidate was rebased before any further claim. This submission started from
and finished against `0c030ee1c1ae`.

## Blocker audit

Exact-main stage profiles showed proof of work consuming about 0.25 ms of the
small proof, close to 23% of prove time. The current raw Blake2s channel
already computes the nonce-invariant prefix once, then creates and joins up to
64 OS threads for each proof. That made thread lifecycle overhead the largest
plausible remaining small-class lever.

Two alternatives were rejected first:

1. A transcript-keyed nonce cache made repeated benchmark requests fast but
   did not accelerate fresh production transcripts. It was NACKED without
   submission because performance depended on process history.
2. Four-lane Blake2s nonce batches preserved the lowest nonce and proof bytes,
   but an exact-main small S1 was neutral-to-worse at
   `1.0140 [0.9952, 1.0382]`. Its apparent isolated gains depended on where a
   fixed transcript's first valid nonce occurred. It was NACKED with no reroll.

The next audit found a source-level contradiction: the global prover worker
pool says it replaces separate FFT, Merkle, and PoW pools, while the actual PoW
call still invokes the channel's thread-spawning grinder. This isolated a
different mechanism: retain scalar hashing and the exact nonce order, but
replace fresh OS threads with persistent pool jobs.

## Research input

Targeted Elicit searches covered persistent pools versus thread creation for
sub-millisecond tasks, task-granularity crossover, deterministic
lowest-valid-nonce search, and combined thread/SIMD hashing. The useful
sources were general task-granularity studies, including DOI
`10.1145/3338497`, DOI `10.1007/978-3-031-06156-1_36`, and the thread
management study DOI `10.1145/75108.75378`. They support the qualitative
prediction that creation and scheduling overhead can dominate fine tasks.
None measured STWO, Blake2s nonce search, or Apple Silicon, so no paper result
was transferred as a quantitative claim.

## Implementation reasoning

The candidate changes only `src/prover/pcs/proof_of_work.zig`.

For the concrete raw Blake2s channel, the default path requests the existing
global pool. It computes the same prefix once, creates one work descriptor per
pool worker, spawns residues 1 through N-1 into the pool, and processes residue
zero on the caller. Each worker checks nonces congruent to its worker index
modulo N. A shared atomic `fetchMin` bound means a worker finding a high nonce
cannot hide a lower valid nonce in another residue class; all jobs join before
the bound is returned.

The core channel implementation was not edited because it is outside the
submission's editable surface. The prover path therefore contains a compact
copy of the locked prefix and 40-byte nonce hash construction. Focused tests
compare the resulting lowest nonce with the original channel grinder for
several difficulties and worker counts, verify every returned nonce, and
repeat the comparison after changing the transcript.

The explicit `STWO_ZIG_POW_WORKERS` override remains authoritative by selecting
the original channel grinder. Pool failure, tests, generic channels, and
single-threaded execution also retain the original path. SIMD4 was not combined
with pool reuse because its transcript sensitivity had already been falsified;
isolating one mechanism makes the evidence interpretable.

## Correctness and product closure

Before timing, formatting and diff checks passed. ReleaseFast closures passed
for 75 transitive core sources, 174 prover sources, and 214 Native CPU product
sources. Source conformance reported only five explained legacy findings and
no new violations. The candidate was committed as `92b18a7a1f51` and the
freshness gate proved it was a clean descendant of `0c030ee1c1ae`.

## Measurement path and surprises

The first exact-main local S1 cleared decisively:

- prove ratio `0.864994`, CI `[0.834305, 0.906102]`;
- 1.048458 ms predecessor versus 0.905250 ms candidate;
- request ratio `0.882266`;
- energy ratio `0.796593`;
- peak RSS ratio `0.958274`;
- byte-identical proof digest.

The first local S3 attempt took no samples because the quiet-host gate rejected
load above its threshold. A short Studio slot was claimed well before another
agent's reserved window. The shared Studio clone was discovered to use a stale
fork `origin/main`; it was rejected before timing. An isolated clone with the
canonical repository as `origin` established exact predecessor/main
`0c030ee1c1ae` and candidate `92b18a7a1f51`.

The isolated clone's first S3 attempt also took zero samples: clone/build
activity briefly raised load above the fail-closed threshold. After the cache
was warm and load dropped, one cooldown retry was admitted. It produced:

- prove ratio `0.935815`, CI `[0.917518, 0.951777]`;
- 0.964500 ms predecessor versus 0.902667 ms candidate;
- request ratio `0.947329`;
- energy ratio `0.875988`;
- peak RSS ratio `0.964453`;
- 13 of 13 automatic regression guards within budget;
- exact proof digest and pinned Rust-oracle success;
- G1-G5 pass.

The lower S3 effect than S1 was retained, not optimized away. Both independent
hosts still clear the significance floor, and the S3 is the claim artifact.
A post-run fetch confirmed main had not advanced. Studio was released
immediately.

## Decision

Package the immutable candidate for the small CPU class only. Wider guard rows
were neutral or modestly faster but do not clear their class significance
floors, so claiming them would overstate the result. The submission remains a
local claimed result until the project judge reruns it.
