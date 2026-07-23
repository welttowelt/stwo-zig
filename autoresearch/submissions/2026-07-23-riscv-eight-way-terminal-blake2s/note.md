# Batch eight independent terminal BLAKE2s Merkle hashes

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf` 0.1.0 at
`481487ba7153`, clean candidate `e199fbf569a8`, clean predecessor
`c3a7e8b36460`, immutable system-2x task baseline
`2beae9d03b33bc9c5b0b21bb445439799786f2fb`, Zig 0.15.2 ReleaseFast on
the 18-logical-CPU Apple M5 Max.

The submitted S3 RISC-V deep verdict used isolated paired same-host
processes. Every timed proof independently verified, cross-arm proof digests
were byte-identical, and the pinned Stark-V oracle accepted all seven
programs. The complete profiles, hypotheses, rejected variants, source-policy
correction, and final evidence are recorded in `transcripts/session-01.md`.

## Hypothesis

The shared BLAKE2s Merkle implementation hashes four independent messages in
one AArch64 vector. At each BLAKE dependency level, however, the machine can
issue work from a second independent four-message group. A logical
`@Vector(8, u32)` terminal compression exposes those two native NEON halves
to LLVM in one operation graph. This is useful specifically for the
single-compression internal-node path, where it increases instruction-level
parallelism without retaining multi-block stream state.

## Changes

The shared crypto backend now provides an eight-message fixed-terminal
BLAKE2s operation. It:

- consumes eight independent 64-byte child payloads after one common
  pre-hashed node-domain seed;
- uses checked, fixed-size data flow and the existing exact ten-round BLAKE2s
  permutation;
- uses bit-cast halves for zero-cost native-vector splitting and joining;
- preserves the scalar backend fallback for platforms without the SIMD path;
- keeps four-way handling for the residual Merkle tail; and
- is selected only from the generic lifted Merkle structure, never by
  workload, input digest, row count, or proof size.

The production routing is confined to manifest-editable
`src/core/crypto/**` and `src/prover/vcs_lifted/**`. A first packaging attempt
placed two convenience wrappers under non-editable shared-VCS directories;
the harness rejected it mechanically. Those wrappers were removed and the
same operation moved into the allowed prover adapter before this verdict.

An attempted eight-way multi-block leaf/continuation path was also removed.
It preserved proof bytes and reduced cycles, but its larger live vector state
caused spill pressure and did not win both wall-time halves. The promoted
patch therefore applies eight-way batching only to the one-compression node
case.

```text
old:  4 parents -> terminal BLAKE2s V4
      4 parents -> terminal BLAKE2s V4

new:  8 parents -> one terminal BLAKE2s V8 operation graph
      residual 4 parents -> existing terminal BLAKE2s V4
```

## Results

The admissible RISC-V deep-class paired result is:

| workload | candidate/predecessor | 95% CI |
| --- | ---: | ---: |
| xorshift PRNG | 0.9849 | [0.9834, 0.9870] |
| iterative Fibonacci | 0.9917 | [0.9896, 0.9926] |
| Euclidean GCD | 0.9919 | [0.9898, 0.9934] |
| multi-shard ADDI | 0.9885 | [0.9863, 0.9906] |
| SHA2-512 | 0.9839 | [0.9779, 0.9909] |
| SHA2-1024 | 0.9963 | [0.9936, 1.0043] |
| SHA2-2048 | 0.9878 | [0.9767, 1.0008] |

The incremental deep portfolio ratio is **0.9893**. All seven medians improve,
but the local harness correctly classifies the 1.07% aggregate change as
confirmed-neutral because the class significance floor is 1.29%. The
cumulative candidate-to-frozen-task-anchor ratio reported by the same verdict
is **0.4688**.

A separate admissible wide run passed all correctness, mechanism, resource,
and source-policy gates at ratio 0.9911. It is retained as guard evidence, not
claimed as a moved class: its Keccak row was noisy and the portfolio was
confirmed-neutral.

Short exact-proof screens showed 1.6--4% fewer cycles in the affected request
path. Peak physical footprint remained effectively unchanged. Core and prover
ReleaseFast tests, the full product build, exact SHA2-128/SHA2-2048 artifact
comparisons, and the seven-workload oracle gate pass.

## Caveats

This is a local claimed/advisory checkpoint; only an authenticated judge can
promote it. Its incremental effect is below the local significance threshold,
so it must not be described as an independently significant speedup.

The broader system-level task is not fully complete: although the cumulative
deep result is below 0.50 versus the frozen baseline, the required per-cell
CPU request/prove contract and genuine RISC-V Metal phase have not both been
completed. **RISC-V system-level 2x: not achieved.**
