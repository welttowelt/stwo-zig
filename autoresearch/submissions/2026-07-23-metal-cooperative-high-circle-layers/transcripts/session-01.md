# Autoresearch session 01 — cooperative high Metal transforms

## Mandate and starting point

The user asked for the largest possible Metal-backend steps, immediate
submission once a significant result existed, complete notes and transcripts,
and continued optimization after promotion. The repo-resident CLI was updated
before experimentation. The repository's five research skills were exercised:
algorithm matching, Zig profiling, Metal profiling, Metal performance design,
and submission transcripts. Their practical constraints were to compare exact
algorithms, profile verified end-to-end proofs, reason about GPU topology and
memory movement, preserve failed experiments, and never promote a fast kernel
whose proof or portfolio gate changed.

This epoch begins at clean predecessor `a01299b4c42c`, the merge result of the
resident transform/commitment architecture. Its clean 10-warmup/7-sample
diagnostics were:

| Shape | Prove median | Request median | RSS | Energy scope | Proof |
| --- | ---: | ---: | ---: | ---: | --- |
| `2^18 × 100` | 29.609 ms | 30.043 ms | 328.4 MiB | 1.257 J | 74,328 B, `f845...ced8f` |
| `2^20 × 100` | 109.440 ms | 109.918 ms | 877.3 MiB | 4.851 J | 86,383 B, `e660...c7e86` |
| `2^22 × 100` | 431.445 ms | 432.071 ms | 2,712.8 MiB | 17.219 J | 106,436 B, `2c0...76205` |

The Metal profile placed about 68 ms of log20 in main trace commitment.
Recurrence/IFFT used about 12.6 ms; high transform layers, forward tail, and
BLAKE Merkle hashing dominated the remainder. The architectural question was
therefore no longer whether to keep data resident—the predecessor already did
that—but how to stop rereading the same transform tile from global memory at
every high radix layer.

## Design map

The old high-layer schedule was conceptually:

```text
layer N:   global read -> butterfly -> global write -> command progress
layer N-1: global read -> butterfly -> global write -> command progress
layer N-2: global read -> butterfly -> global write -> command progress
```

The target schedule was:

```text
global read -> [threadgroup tile: layer N, N-1, N-2, ...] -> global write
                         256 cooperative threads
                         4096 values / 16 KiB
```

The important engineering constraint is that a fused tile is useful only
while butterfly partners remain inside the tile. Low layers still use the
existing wide sparse tail. Log22 also needs more outer groups than log20; the
host schedule must cover all groups and leave unsupported inverse remainder
layers to the generic path.

## First accepted micro-change: BLAKE leaf block structure

The BLAKE leaf shader's message-word loop was rewritten around complete
16-word blocks. This preserves the exact word sequence and digest but removes
repeated boundary/control work. It saved roughly 0.7 ms at log20. Attempts to
remove radix address arrays were compiler-neutral and were reverted rather
than retained as source churn.

## Cooperative high-layer kernel

The first working kernel used 256 threads and a 2,048-value tile. A 4,096-
value tile performed better and fit in 16 KiB threadgroup memory. The kernel
loads lane-major values, executes multiple butterflies with threadgroup
barriers, and writes once. It produced exact canonical proofs at log18 and
log20.

A log22 extension initially failed with `ConstraintsNotSatisfied`. The cause
was not arithmetic: host dispatch covered the first tile family but missed
outer groups. Extending the group schedule restored the exact `2c0...76205`
proof. That failure was useful because it showed the verifier caught a
plausible, deterministic GPU scheduling omission before performance evidence
could be accepted.

The first log22 inverse version fused all ten high layers. It was correct but
slow: about 28.8 ms versus roughly 19.5 ms for eight fused layers plus the
two-layer generic remainder. The final inverse policy caps at eight; forward
high layers remain fused. This is a structural layer-count decision, not a
benchmark-size lookup.

Replacing address divisions/moduli with explicit shifts and masks saved
roughly another 2 ms at large shape. Increasing recurrence workgroup size to
512 threads lost performance; a 1,024-thread experiment was neutral and was
also reverted. Increasing the cooperative transform itself to 512 threads
lost performance. The GPU wanted more residency and simpler scheduling, not
more threads per group.

## Layout experiments

The first coalesced layout appeared attractive from global-memory access but
created threadgroup-bank conflicts and regressed end-to-end time. It was
discarded. A lane-major/global tile mapping removed those conflicts and moved
the high-layer profile from about 9.4 ms per proof to about 7.3 ms per proof.

SIMD-group twiddle broadcast was then tested on the theory that adjacent lanes
shared twiddles. The extra shuffle/control work increased the high kernel to
roughly 8.6 ms, so direct indexed loads were restored. This is a useful
counterexample to assuming SIMD intrinsics are automatically cheaper than a
well-cached uniform device read.

## BLAKE cooperation experiment

A four-lane cooperative BLAKE leaf kernel assigned message preparation and
round work across lanes. It was bit-exact, but leaf plus first-parent time rose
to about 9.27 ms versus roughly 6.4 ms for the scalar-per-leaf mapping. The
hash has enough lane-local dependency that synchronization/shuffle overhead
outweighed shared work at this granularity. The experiment was fully removed;
only the accepted 16-word block organization remains.

## Pipeline-state iterations

Commit `fb31f69` introduced a dedicated cooperative pipeline. Commit `3fc4b49`
restored the locked parity fixture after the first implementation needlessly
touched it. The dedicated pipeline produced strong objectives: one xlarge
screen was 0.9421 [0.9331, 0.9508], and repeated huge screens ranged from
about 0.9326 to 0.9478. Yet the extra eagerly compiled source-JIT pipeline made
batch resource energy noisy, and tiny regression guards sometimes exceeded
their CI budgets. Those receipts remain in the external evidence directory.

Commit `0c552d6` folded the mode into the wide-tail pipeline to remove the
extra pipeline. Initialization improved, but hot performance regressed to
roughly 104.85 ms locally; its official xlarge ratio was 0.9489 with a wide
upper CI of 0.9865, below significance. This variant was rejected.

The final design at `f472bd1` reuses the existing
`stwo_zig_circle_rfft_last_sparse` pipeline. A forward declaration exposes the
cooperative helper from `circle_transform_wide.metal`; a packed configuration
bit selects it. The packed fields are flag bit 31, column count bits 0--8,
inverse bit 9, layer count bits 10--13, and lowest stage bits 14--18. The host
sets 16 KiB of dynamic threadgroup memory only for cooperative dispatches.
Ordinary last-layer dispatches set none. Export totals stay 91/82/22 and no
extra pipeline is compiled.

A final local 10+7 log20 screen measured 101.751 ms prove / 102.280 ms request,
roughly 7.8% below the 110.33 ms nearby baseline screen. Log18 measured 28.249
/ 28.696 ms, about 4.6% lower. Both had the exact canonical proofs and zero
fallbacks.

## Official scoreboards and honest guard handling

The final xlarge board ran nine paired rounds against the exact predecessor.
It passed all five gates and all 13 guards:

- prove ratio 0.952527, workload CI [0.930923, 0.968330];
- A/B medians 31.368521 / 30.015729 ms;
- verified-request ratio 0.945897;
- energy ratio 0.997417, upper CI 1.033400;
- RSS ratio 1.000144, upper CI 1.000479;
- 74,328 proof bytes, exactly unchanged; and
- pinned Rust-oracle acceptance.

The first final-identity huge board was also decisively positive: ratio
0.945592 [0.933435, 0.950595], with 113.027875 / 106.063833 ms medians.
Energy, RSS, request, proof, oracle, and the target matrix all passed. The
unrelated `wf_10x8` guard was 1.067297 [0.982479, 1.140906], so G4 failed.
A second complete run again showed a significant target, 0.9518 [0.9386,
0.9812], but `wf_10x8` and `xor_14` were noisy. Neither failed receipt is
packaged as a claim. No sample was removed and no receipt was overwritten.

## Log22 extreme evidence

The final clean extreme run used ten warmups and seven verified samples. Its
prove samples were 378.305, 379.959, 397.819, 368.390, 384.033, 378.240, and
389.611 ms. Median prove time was 379.959 ms and median request time 380.556
ms, versus the predecessor diagnostic 431.445 / 432.071 ms. This is an 11.93%
prove-time reduction at the largest currently runnable shape.

The run admitted exactly 419,430,400 cells and 6,710,886,400 accounted bytes.
Median throughput was 11.039 row-MHz and 1,103.882 committed-Mcells/s. Peak
physical footprint was 2,843,612,368 bytes, energy 16.327 J, instructions
47.891 billion, and cycles 16.297 billion over the measured process batch.
All seven proofs were 106,436 bytes with SHA-256
`2c0ca9f7a73ea80f4cc32f2e27785f9ccf6b11dc460a133ebc8f5cc441e76205`.
Each proof used 31 Metal dispatches and zero CPU fallbacks.

## Final profile and next architecture

A profiled log20 proof at the exact final commit measured 97.883 ms prove and
98.438 ms verified request. Main trace commitment was 54.888 ms; core proving
was 42.988 ms. Within core proving, quotient/FRI commit was 16.899 ms,
composition commit 8.805 ms, sampled values 8.210 ms, and composition
evaluation 4.742 ms.

For one warmup plus one sample, GPU totals ranked BLAKE parent-tail (23.56
ms), BLAKE parents (18.54 ms), BLAKE leaves (18.14 ms), wide recurrence/IFFT
(16.43 ms), reused cooperative high transform (14.60 ms), and the fused wide
tail (11.01 ms). The next large step should fuse or restructure BLAKE leaf and
parent production so values remain tile-local across the first Merkle levels,
then assess whether command-buffer overlap can reduce the remaining 181 ms
profiled host-wait total across warmup and sample.

## Validation and inherited failures

The exact final commit passes `test-native-metal`, `metal-check`,
`test-metal-core-aot`, and `test-metal-core-aot-probe`. The native Metal
lifecycle, source-JIT shader compilation, independent artifact verification,
259-source closure, fail-closed ABI checks, and AOT mutation fixture pass.
Proof hashes at logs 18, 20, and 22 are unchanged, and every measured request
reports zero CPU fallback.

The broad Metal suite reports 86/90 with two failures and two skips. Running
the same suite on untouched predecessor reproduces exactly those results: the
resident-FRI coordinate-policy test and the quotient-residency test that
rejects runtime-wide discovery. This epoch neither worsens nor conceals that
known architectural debt. The existing combined LDE/Merkle differential test
continues to force the combined implementation and compare it with generic
columns and Merkle roots.

## Complete rejected-idea ledger

- Radix address-array removal: compiler neutral; reverted.
- 2,048-value cooperative tile: correct and useful, but slower than 4,096.
- 512-thread and 1,024-thread recurrence schedules: losing/neutral; reverted.
- 512-thread cooperative transform: slower; reverted.
- All-ten-layer log22 inverse tile: correct but roughly 9.3 ms slower.
- First log22 host grouping: incomplete and rejected by constraint verification.
- First coalesced layout: threadgroup-bank conflicts; slower.
- SIMD twiddle broadcast: high kernel rose from about 7.3 to 8.6 ms.
- Four-lane cooperative BLAKE leaves: bit-exact but roughly 45% slower.
- Dedicated high-transform PSO: hot-fast but source-JIT/resource noisy.
- Wide-tail PSO reuse: lower initialization cost but slower hot requests.
- Two final huge claims: significant targets, intentionally withheld because
  unrelated tiny guard CIs failed closed.

## Status

This epoch has a clean significant xlarge claim and strong unclaimed log20/
log22 evidence. It does not yet include the complete PR6 workload matrix,
cold-process peer boundary, every seven-round peer ABBA cell, or an
authenticated locked-M5 judged verdict. **PR6 Supremacy: not achieved.**

