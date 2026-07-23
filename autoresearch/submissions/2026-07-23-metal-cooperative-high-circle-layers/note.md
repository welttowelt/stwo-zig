# Cooperatively fuse high Metal circle-transform layers

## Model and harness

Model: GPT-5 Codex. The repo-resident `stwo-perf` CLI was updated before this
epoch. Measurements use Zig 0.15.2, ReleaseFast, default parallel proving,
and Metal source JIT on the same arm64 macOS M5 Max host. The scored candidate
is clean commit `f472bd100b82f5b20dc4e306befc57ad53d97129`, based on immutable
predecessor `a01299b4c42c`, with harness `2290dbc5d935`. The candidate changes
only seven files under `src/backends/metal/**` (211 insertions, 21 deletions).

This submission claims `core_metal/xlarge/time` at S3. The log20 and log22
results are retained as strong diagnostic evidence, but log20 is deliberately
not claimed because two complete receipts each had an unrelated noisy tiny
guard above its 1.05 upper-CI budget.

## Hypothesis

The resident trace/commitment pipeline had removed the largest CPU/device
boundaries, leaving high circle-transform layers as a global-memory problem.
Every high radix layer launched across the full column domain and re-read
twiddles and values from device memory. A GPU should instead let one
threadgroup keep a contiguous transform tile resident, cooperatively execute
several high layers, and publish it once.

## Changes

The accepted implementation uses a 4,096-value / 16 KiB threadgroup tile with
256 threads. It reuses the already compiled `circle_rfft_last_sparse` pipeline
rather than adding another pipeline state. A packed structural mode carries
column count, inverse direction, layer count, and lowest stage; dynamic
threadgroup memory is set only for the cooperative mode. Ordinary callers
retain zero dynamic threadgroup memory and the original behavior. There is no
workload name, benchmark size, input digest, or statement special case.

For log22, inverse work deliberately stops after eight cooperative layers and
uses the generic remainder for the last two. Profiling showed that an all-ten
inverse tile took about 28.8 ms while the eight-plus-two schedule took about
19.5 ms. Forward high layers remain cooperatively fused. Explicit shift/mask
addressing and a lane-major global tile layout avoid division and threadgroup
bank conflicts. The BLAKE leaf loop is also organized in complete 16-word
message blocks, reducing loop/control overhead without changing a single
digest.

The core shader ABI advances fail-closed from 9 to 10 because an existing
binding gained a packed cooperative mode. Export counts remain unchanged at
91 total, 82 native, and 22 circle exports; source-JIT and AOT manifest tests
anchor those identities.

## Results

The complete xlarge receipt passes G1-G5, all 13 impact-mapped regression
guards, resource budgets, exact proof parity, and the pinned Rust Stwo oracle.

| Workload | Prove ratio (95% CI) | A / B median | Request ratio | Energy ratio (upper CI) | RSS ratio (upper CI) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `2^18 × 100` | **0.9525 [0.9309, 0.9683]** | 31.369 / 30.016 ms | 0.9459 | 0.9974 (1.0334) | 1.0001 (1.0005) |

Nine paired rounds establish a statistically significant 4.75% prove-time
reduction. Proof size is exactly 74,328 bytes, unchanged. Every cross-arm
proof digest is byte-identical, and the pinned Rust oracle accepted artifact
`49f9555c8a3d6d1f47045a7a22caf961745d503174d840b8e21a414aaf74cfb4`.

## Large-shape diagnostics

The same clean candidate generalizes more strongly as transform height grows:

| Shape | Evidence | Predecessor | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| `2^18 × 100` | official paired median | 31.369 ms | 30.016 ms | 4.31% median reduction |
| `2^20 × 100` | official paired median, unclaimed | 113.028 ms | 106.064 ms | 6.16% median reduction |
| `2^22 × 100` | clean 10+7 diagnostic | 431.445 ms | 379.959 ms | 11.93% reduction |

The first log20 receipt is significant at **0.9456 [0.9334, 0.9506]** and
passes proof, oracle, matrix, request, energy, RSS, and proof-size gates. Its
only failed gate is `guard_wf_10x8`, a sub-millisecond unrelated workload at
1.0673 [0.9825, 1.1409]. A complete resample again produced a significant
log20 objective, 0.9518 [0.9386, 0.9812], while the same tiny guard and
`guard_xor_14` were noisy. Both full receipts are retained; neither is
selectively promoted.

The log22 extreme-profile run admitted all 419,430,400 committed cells and
6,710,886,400 accounted bytes with checked fail-closed arithmetic. Seven
samples were 368.390--397.819 ms; prove median was 379.959 ms and verified-
request median 380.556 ms. Throughput was 11.039 trace-row MHz and 1,103.9
committed-Mcells/s. Peak physical footprint was 2,843,612,368 bytes, measured
batch energy 16.327 J, and the runtime reported 31 dispatches per proof with
zero CPU fallbacks. All seven proofs were the same 106,436-byte
`2c0ca9f7...76205` artifact.

## Profile evidence and remaining bottleneck

A final instrumented log20 proof measured 97.883 ms prove / 98.438 ms request
with the canonical 86,383-byte `e6609d05...c7e86` proof. The high-level stage
map was 54.888 ms for main trace commitment and 42.988 ms for core proving,
including 16.899 ms quotient/FRI commit, 8.805 ms composition commit, 8.210 ms
sampled-value evaluation, and 4.742 ms composition evaluation.

Across the profiled warmup and sample, the largest GPU pipeline totals were
BLAKE parent-tail 23.56 ms, BLAKE parents 18.54 ms, BLAKE leaves 18.14 ms,
wide recurrence/IFFT 16.43 ms, reused cooperative last-layer transform 14.60
ms, and fused wide transform tail 11.01 ms. This makes the next epoch clear:
reduce BLAKE leaf/parent traffic and overlap or fuse Merkle levels without
reintroducing host visibility.

## Validation

`test-native-metal`, `metal-check`, `test-metal-core-aot`, and
`test-metal-core-aot-probe` pass on the exact scored commit. Source-JIT
compilation, the device-only lifecycle, independent proof verification, the
259-source native-Metal closure, shader export/ABI checks, and AOT mutation
authority all pass. Canonical proof hashes are unchanged at logs 18, 20, and
22, and every measured Metal proof reports zero fallbacks.

The broad `metal-test` suite remains 86/90 with the same two failures and two
skips reproduced on untouched predecessor `a01299b4`: the resident-FRI
coordinate policy test and the known quotient-residency runtime-discovery
surface test. The candidate introduces no new broad-suite failure. The
existing focused combined LDE/Merkle differential test continues to force
the combined path and compare it with generic evaluation and Merkle output.

## Rejected designs retained in the transcript

The research record includes the losing 512/1,024-thread schedules, an
all-ten-layer inverse schedule, a cooperative four-lane BLAKE leaf kernel,
a bank-conflicted tile layout, SIMD twiddle broadcast, an eager standalone
pipeline that increased source-JIT/resource noise, and a wide-tail pipeline
reuse variant that lost hot performance. Proof failures from an incomplete
log22 outer-group schedule were caught by constraint verification and fixed
before any timing claim.

## Caveats

This is a significant repository Metal improvement and should be promoted on
its passing board. It does not satisfy the separate all-cell PR6 contract,
which still needs every exact workload, both verified-request and cold-
process peer comparisons, seven complete same-host ABBA rounds per cell, and
an authenticated locked-judge verdict. **PR6 Supremacy: not achieved.**
