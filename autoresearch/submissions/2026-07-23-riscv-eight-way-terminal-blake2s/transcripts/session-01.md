# RISC-V system-level 2x autoresearch — terminal BLAKE2s epoch

## Objective and inherited state

This epoch continued the fixed-protocol RISC-V system-level 2x task. The
immutable authority is commit
`2beae9d03b33bc9c5b0b21bb445439799786f2fb`; the epoch began from promoted
main `c3a7e8b364604e117d292a3f7793918498d1a64d`. The target host is an Apple
M5 Max with 18 logical CPUs and 64 GiB RAM, using Zig 0.15.2 ReleaseFast.

The fixed contract requires exact RISC-V statement/AIR/protocol semantics,
independent verification, pinned Rust/Stark-V oracle acceptance, identical
proof bytes, unchanged proof shape and security parameters, no input- or
workload-specific routing, resource telemetry, paired same-host processes,
and broad RISC-V/native guards. The completion target remains 2x on every
headline CPU prove and verified-request point, followed by a genuine RISC-V
Metal backend. This transcript records a final requested architecture
checkpoint, not a claim that those complete gates have all been achieved.

The immediately preceding promotion preserved structurally base QM31
operands. Its clean code candidate was `963f30da163a`; its submitted source
closure was `e2b4926`. Against the frozen task baseline, the six headline
proving geometric mean reached 0.665886 (1.502x), verified request reached
0.750290 (1.333x), and all 20 RISC-V programs improved. That promotion was
merged and the feed advanced main to `c3a7e8b`.

## Repository and tooling state

The canonical checkout contained three pre-existing untracked researcher
notes. They were treated as user-owned and never modified. Work proceeded in
clean worktree:

`/Users/theodorepender/code/auto-researching/ws-riscv-system2x-epoch2`

on branch `autoresearch/riscv-system2x-epoch2`. A separate clean detached
predecessor worktree at `c3a7e8b` was created for paired evidence. The
repo-resident CLI had already been refreshed at session start; its reported
version is `stwo-perf 0.1.0`.

No concurrent benchmark or autoresearch job ran. All candidate screens used
prebuilt ReleaseFast products, retained proof artifacts, and the same
ELF/input/protocol as their predecessor arm.

## Promoted-main profile

Production complete-request profiles were captured at three SHA2 input sizes:

| input | request s | prove s | witness s | verify s | peak footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| SHA2-128 | 1.39205 | 0.86349 | 0.43966 | 0.08382 | 1.402 GB |
| SHA2-512 | 1.57479 | 1.03680 | 0.44037 | 0.08837 | 1.443 GB |
| SHA2-2048 | 2.18607 | 1.51469 | 0.56809 | 0.08420 | 1.571 GB |

Nested diagnostic profiles divided the proving path as follows:

| stage | SHA2-128 ms | SHA2-2048 ms |
| --- | ---: | ---: |
| preprocessing | 80 | 84 |
| opcode/infrastructure | 246 | 269 |
| main commitment | 46 | 58 |
| interaction | 396 | 620 |
| composition evaluation | 282 | 292 |
| composition interpolation | 8 | 7 |
| composition commitment | 23 | 25 |
| sampled values | 27 | 32 |
| FRI | 84 | 89 |
| decommit | 3 | 3 |

A process sample kept BLAKE2s `compressParallel4` as the largest aggregate
kernel (roughly 4,489--4,924 samples). Other large entries were FFT tails
(1,206--1,400), quotient evaluation (974--1,213), memory movement
(882--2,258), Merkle leaf work (about 700), and LogUp pair constraints
(404--673).

The RISC-V frontend itself is locked by the autoresearch manifest. The live
editable frontier was therefore shared crypto, field, polynomial, PCS, and
lifted-Merkle architecture.

## Scheduler experiment

Per-component composition timings showed a strongly heterogeneous set of 35
components: the first main-thread component took about 0.006 ms, while late
worker components ranged from about 61 to 233 ms. This motivated a structural
longest-processing-time-first scheduler.

The candidate reordered structurally derived component tasks and kept proof
bytes exact. It did not survive paired complete proofs:

- SHA2-128 split its two halves between a small loss and a small win.
- SHA2-2048 split at about a 2% loss and a 1% win.

The extra concurrently active 18th worker increased bandwidth contention and
the scheduler did not shorten the joined critical path reliably. The complete
patch was rejected and reverted. The rejected patch and all exact-proof
reports are retained under the external session evidence directory
`profile-scheduler`.

This also confirmed earlier worker-count and oversubscription sweeps: the
problem was not simply an insufficient number of runnable component tasks.

## Eight-message BLAKE2s hypothesis

The existing four-message BLAKE2s implementation maps four independent
messages to one native AArch64 vector. Its ten-round dependency graph is
carefully interleaved across BLAKE G functions, but a second independent
four-message group can provide instruction-level parallelism at each
dependency depth.

The proposed architecture used a logical `@Vector(8, u32)`. LLVM legalizes
that value to two native 128-bit NEON halves on Apple Silicon. The first
target was the exact internal-Merkle-node operation:

1. start from the common pre-hashed 64-byte node-domain seed;
2. concatenate eight independent child pairs into eight 64-byte payloads;
3. transpose them into an eight-lane BLAKE2s message schedule;
4. execute one exact terminal compression operation graph; and
5. split the eight resulting states back into canonical 32-byte hashes.

This preserves every byte consumed by the transcript and does not alter
Merkle shape, leaf values, protocol, query count, or proof encoding.

## First upper-node screen

The initial upper-node-only candidate built and passed its terminal
differential test. SHA2-128 and SHA2-2048 proof artifacts matched the
predecessor byte for byte:

- SHA2-128 artifact:
  `95629c69c53e0d0cf40d852a98cd14aec94caa4bc39d7a1a0093f0ebf3b05288`
- SHA2-2048 artifact:
  `807b69a2f4c383c5b73c5570aa6e94858bafb684ee5c7529f1cc1c71318c363c`

The SHA2-128 proving halves improved by about 3.9% and 0.24%. SHA2-2048 split
between a roughly 0.3% loss and a 1.6% win. Hardware cycles nevertheless fell
consistently by roughly 2.4--3.2%, while instructions increased about 1%.
That was promising architecture evidence but insufficient promotion evidence.

## Rejected multi-block expansion

The next hypothesis extended eight lanes into:

- equal-length multi-block leaf hashing;
- direct M31 column-major leaf hashing;
- incremental leaf continuation;
- lifted-tail finalization; and
- batched leaf construction.

New differential tests covered terminal blocks, equal messages at 4, 64, 68,
and 3,296 bytes, direct column continuation, and scalar equivalence. Core and
prover test products passed and exact RISC-V artifacts remained identical.

The complete-proof result rejected the expansion. On SHA2-128, both proving
halves were flat-to-worse (about +2.2% and +0.1%), although total cycles fell.
The reason is architectural: one terminal compression has bounded live state,
while multi-block eight-lane streams retain two native halves for all 16
BLAKE working words and message state. That saturates the vector register file
and introduces spill/reload traffic. The broad leaf path was removed.

A terminal-finalization-only variant was also screened. One half improved
about 1.2%, while the reverse half regressed about 6%. It too was removed.

The retained scope is therefore deliberately narrow: eight lanes only for
one-compression internal Merkle nodes, with the existing four-lane path used
for all multi-block streams and residual parent groups.

## Lowering refinements

Several legalizations were compared:

1. explicit `@shuffle` extraction/join around native V4 halves;
2. direct V8 variable shifts; and
3. zero-cost `@bitCast([2]V4, V8)` halves with existing immediate V4 rotates.

Direct V8 shifts increased the instruction count. The final implementation
uses bit-cast halves for message loading, rotate operations, and result
splitting. This keeps the algorithm expressed as one V8 operation graph while
giving LLVM the existing immediate V4 rotate idiom on each legalized half.

The layer router handles groups of eight first, then explicitly retains the
existing group-of-four tail. An earlier `else if` draft would have made
four-parent residuals scalar whenever the eight-way declaration existed; that
was caught during review and corrected before the clean candidate.

## Short final screens

The final narrowed source produced exact SHA2-128 and SHA2-2048 proofs.
Representative paired screens showed:

| input | predecessor prove s | candidate prove s | request result |
| --- | ---: | ---: | ---: |
| SHA2-128 | 0.80059 | 0.79457 | candidate about 1.5% faster |
| SHA2-2048 | 1.43582 | 1.44127 | candidate about 0.3% faster request; prove noisy |

Across short screens, whole-request cycles fell by roughly 1.6--4%.
Wall-time movement was small enough that only the repository harness could
decide the final claim.

## Source-policy failure and correction

The first clean implementation commit was `55e61a7`. Its initial wide S3 run
verified all seven proofs and reported portfolio ratio 0.9836. However, G2
correctly failed because convenience wrappers had been added under:

- `src/core/vcs/blake2_hash.zig`
- `src/core/vcs_lifted/blake2_merkle.zig`

Those locations are not in `MANIFEST.json → editable_paths`, even though the
underlying shared crypto and prover paths are editable. That verdict was
discarded.

The wrappers were removed. The allowed
`src/prover/vcs_lifted/blake2_stream4.zig` adapter now packs the eight child
payloads and calls the allowed `src/core/crypto/**` backend operation
directly. The source diff became exactly:

- `src/core/crypto/blake2s_backend.zig`
- `src/core/crypto/tests/blake2s_backend.zig`
- `src/prover/vcs_lifted/blake2_stream4.zig`
- `src/prover/vcs_lifted/layers.zig`

Core/prover tests and the full ReleaseFast product build passed again. The
commit was amended and force-pushed as clean candidate `e199fbf569a8`.

## Admissible wide evidence

The corrected candidate passed all gates on the seven-program wide class:

- G1: every sample verified; cross-arm proofs identical; oracle 7/7.
- G2: no locked or out-of-scope paths.
- G3: canonical stable RISC-V mechanism telemetry.
- G4: all time/request/resource vectors within budgets.
- G5: local claimed/advisory environment.

| workload | ratio | 95% CI |
| --- | ---: | ---: |
| memcpy | 0.9855 | [0.9777, 0.9909] |
| sieve | 0.9878 | [0.9845, 0.9918] |
| bubble sort | 0.9921 | [0.9860, 1.0036] |
| Collatz | 0.9868 | [0.9843, 0.9915] |
| Keccak-128 | 1.0152 | [1.0075, 1.0349] |
| SHA2-128 | 0.9972 | [0.9765, 1.0046] |
| SHA2-256 | 0.9738 | [0.9498, 0.9972] |

The wide portfolio ratio was 0.9911 versus current main and 0.4077 versus the
frozen calibration anchor. Because the incremental result is
confirmed-neutral and the noisy Keccak point lost, this class is retained as
guard evidence and is not included as a moved-class submission verdict.

## Submitted deep evidence

The deep S3 run also passed G1--G5:

| workload | ratio | 95% CI | rounds |
| --- | ---: | ---: | ---: |
| xorshift PRNG | 0.9849 | [0.9834, 0.9870] | 3 |
| iterative Fibonacci | 0.9917 | [0.9896, 0.9926] | 3 |
| Euclidean GCD | 0.9919 | [0.9898, 0.9934] | 3 |
| multi-shard ADDI | 0.9885 | [0.9863, 0.9906] | 3 |
| SHA2-512 | 0.9839 | [0.9779, 0.9909] | 5 |
| SHA2-1024 | 0.9963 | [0.9936, 1.0043] | 3 |
| SHA2-2048 | 0.9878 | [0.9767, 1.0008] | 5 |

All seven medians improve. The current-main portfolio ratio is 0.9893, a
1.07% improvement. The class significance effect size is 1.29%, so the
harness honestly labels the incremental result confirmed-neutral. The
cumulative candidate/frozen-anchor ratio is 0.4688.

This deep verdict is the final requested checkpoint. It demonstrates exact
architecture/correctness and preserves a small portfolio-wide improvement,
but it is not represented as an independently significant promotion.

## Final verification inventory

The retained candidate passed:

- `zig build test-stwo-core test-stwo-prover -Doptimize=ReleaseFast -j18`
- `zig build -Doptimize=ReleaseFast -j18`
- eight-way terminal BLAKE2s differential tests;
- exact SHA2-128 and SHA2-2048 proof artifact comparisons;
- seven-program wide S3 verification/oracle/resource/source gates; and
- seven-program deep S3 verification/oracle/resource/source gates.

Peak process footprint remained in the predecessor envelope. No AIR,
statement, input, protocol, proof size, transcript ordering, security
parameter, resource admission, or backend fallback changed.

## Final status and rejection ledger

Promoted candidate architecture:

- eight-message terminal BLAKE2s for internal lifted Merkle nodes;
- structural selection only;
- V4 residual and multi-block paths retained;
- exact canonical proofs.

Rejected in this epoch:

- longest-processing-time component scheduling: split A/B halves;
- extra active worker: bandwidth contention;
- eight-way multi-block/equal leaf hashing: register spills, prove regression;
- eight-way direct M31 leaf hashing: same live-state problem;
- eight-way incremental continuation: same live-state problem;
- eight-way finalization across retained streams: split halves;
- direct V8 variable shifts: excess instructions;
- non-editable shared-VCS wrappers: mechanical G2 rejection;
- wide-class claim: confirmed-neutral with noisy Keccak regression.

The final checkpoint is committed, pushed, submitted with the deep verdict,
and intended for merge at the user's explicit stopping point.

**RISC-V system-level 2x: not achieved.**
