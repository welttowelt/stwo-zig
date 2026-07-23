# Preserve sparse base-field structure in QM31 evaluation

## Model and harness

Model: GPT-5 Codex. Harness: refreshed repo-resident `stwo-perf` at
`7efe3b1abd72`, clean candidate `963f30da163a`, immutable task baseline
`2beae9d03b33`, Zig 0.15.2 ReleaseFast on the 18-logical-CPU Apple M5 Max.
The submission carries RISC-V small, wide, and deep S3 time verdicts. Paired
same-host processes used adaptive counterbalanced rounds. Every timed proof
verified, cross-arm proof digests were byte-identical, and the pinned Stark-V
oracle accepted all 20 programs. The complete research and rejection history
is attached as `transcripts/session-01.md`.

## Hypothesis

RISC-V AIR evaluators promote committed M31 columns into QM31 values so one
constraint interface can also evaluate full-extension out-of-domain samples.
Those promoted values remain structurally sparse—three of four coordinates are
zero—but generic QM31 multiplication immediately paid a full nine-base-product
Karatsuba operation. Preserving the actual base-field shape should remove most
extension arithmetic in interaction and composition evaluation without
changing the AIR, statement, transcript, protocol, trace, or proof.

## Changes

`QM31` now exposes an algebraic `isBase` predicate. At runtime, multiplication
by a structurally base operand uses the existing exact full-by-M31 operation,
and a structurally base square remains in M31. Two full-extension operands keep
the original Karatsuba path. Randomized schoolbook-reference tests cover both
operand orders and sparse squaring.

The final diff is 32 lines in one shared field file. Selection depends only on
field coordinates, never workload name, input digest, benchmark size, or
column count. An initially favorable packed batch-inverse layer was removed:
it supplied only 0--2%, enlarged specialized text, and twice made a Native
Plonk peak-RSS confidence bound miss its budget. The narrowed candidate passes
that guard.

```text
old: lifted M31 -> generic QM31 x QM31 -> 9 base products
new: lifted M31 -> structural base test -> QM31 x M31 -> 4 base products
```

## Results

All three exact-SHA RISC-V verdicts are significant:

| class | programs | proving geometric mean |
| --- | ---: | ---: |
| small | 6 | 0.8893 |
| wide | 7 | 0.7645 |
| deep | 7 | 0.8039 |

Headline results:

| workload | proving ratio | 95% CI | request ratio | energy ratio |
| --- | ---: | ---: | ---: | ---: |
| SHA2-128 | 0.6203 | [0.6056, 0.6486] | 0.7432 | 0.8332 |
| SHA2-256 | 0.6283 | [0.6256, 0.6299] | 0.7367 | 0.8343 |
| SHA2-512 | 0.6806 | [0.6686, 0.6934] | 0.7503 | 0.8297 |
| SHA2-1024 | 0.7029 | [0.6933, 0.7226] | 0.7658 | 0.8278 |
| SHA2-2048 | 0.7116 | [0.7037, 0.7241] | 0.7865 | 0.8312 |
| Keccak-128 | 0.6571 | [0.6517, 0.6666] | 0.7210 | 0.8329 |

The six-row headline proving geometric mean is **0.6659** (1.502x faster);
verified-request geometric mean is **0.7503** (1.333x). Across all 20 RISC-V
programs, proving/request geometric means are 0.8142/0.8514. Every individual
row improves. Proof bytes are exactly unchanged, all peak-RSS vectors pass,
and energy improves in every RISC-V row.

The sparse path cut diagnostic SHA2-128 composition evaluation from 718 to 276
ms and interaction generation/commit from 473 to 352 ms. Instructions in the
initial verified SHA2-128 screen fell from 407.2 to 298.0 billion. The 380-
source ReleaseFast closure, RISC-V prove/verify suite, and source conformance
pass. Explicit Native CPU small/wide/deep guards pass at proving ratios
0.9984, 0.9920, and 0.9821 with resource vectors in budget.

## Caveats

These are local claimed verdicts; only the authenticated judge can promote
them. The harness's automatic cross-board guard expansion currently parses
Native guard commands as RISC-V commands, so objective verdicts used
`--guards none` and Native CPU guards were run explicitly on their correct
board.

This checkpoint does not satisfy the task's full 2x contract: headline request
ratio is 0.7503, complete-board ratios are 0.8142/0.8514, and no headline
proving row is yet at most 0.50. **System-level 2x: not achieved.** The genuine
RISC-V Metal backend phase is also still outstanding.
