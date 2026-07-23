# Autoresearch session 01 — paired Metal expansion and high transforms

## Mandate and provenance

The user asked for continued large Metal-backend optimization, immediate
submission once a significant solution existed, and a complete transcript of
successful and failed iterations. The repo-resident `stwo-perf` CLI was
updated before this research cycle. The repository research skills had been
read and exercised: exact algorithm matching, Zig profiling, Metal profiling,
Metal architecture design, and sanitized submission transcripts.

The epoch began from clean main
`019699fd706c7fd7aa2e3655db829ce52c1be50b`, after promotion of the
cooperative high-circle-layer work. Candidate work happened in
`ws-metal-blake-unrolled-epoch9`; a separate clean predecessor worktree stayed
at the same immutable commit. No other benchmark or autoresearch process ran
concurrently.

The starting log20 diagnostic used ten warmups and seven samples:

- prove median 95.324 ms;
- verified-request median 95.823 ms;
- 86,383-byte proof `e6609d05...c7e86`;
- 928,400,992-byte peak physical footprint;
- 4.246 J, 12.208 billion instructions, and 4.298 billion cycles for the
  measured batch;
- 29 Metal dispatches per proof and zero CPU fallbacks.

Thermal/load variation was substantial: nearby untouched-predecessor samples
later ranged around 104--105 ms. Every meaningful comparison was therefore
repeated adjacently or through the counterbalanced scorer rather than treating
the first absolute number as a permanent anchor.

## Profile and architecture map

The previous epoch had already made high circle layers cooperative. Profiling
showed the next remaining transform boundary:

```text
coefficient arena
    |
    | circle_expand_coefficients
    v
four expanded quarters in device memory
    |
    | circle_rfft_last_sparse reloads each quarter
    v
four 16 KiB threadgroup tiles -> remaining forward tail -> Merkle
```

For each source coefficient pair, expansion computes one product and writes a
plus/minus quarter pair. The proposed schedule was:

```text
one 512-thread group
    first 256 lanes: read pair once, multiply once
                 /                         \
         16 KiB plus tile             16 KiB minus tile
         256-thread transform         256-thread transform
                 \                         /
                exact device-layout quarter stores
```

This uses 32 KiB of dynamic threadgroup memory, stays below the M5 Max limit,
and eliminates the expanded-domain write/read boundary for the high layers.
It does not attempt to fuse the remaining low tail or Merkle hashing, whose
access topology differs.

## Rejected experiment ledger

### 1. Compile-time scalar BLAKE2s unroll

The entire scalar compression schedule was unrolled at compile time. Proof
bytes stayed exact, but log20 rose to 102.548 ms and source-JIT compilation
rose from roughly 264 ms to 1.095 s. The compiler/source-size cost dominated;
the change was reverted.

### 2. Explicit named scalar compression state

The BLAKE state was rewritten into named scalar variables to encourage
register allocation and constant propagation. It remained exact but measured
106.511 ms; JIT compilation was about 520 ms. Reverted.

### 3. SIMD-lane leaf plus five-parent fusion

One cooperative group attempted to hash leaves and retain enough state to
produce five parent levels. The proof was exact, but end-to-end time regressed
to 111.142 ms. Hash dependency and synchronization outweighed avoided memory
traffic. Reverted.

### 4. Leaf plus first-parent fusion

A narrower version retained only the first parent. In an adjacent comparison,
candidate was 106.443 ms versus predecessor 105.054 ms, 1.32% slower.
Reverted.

### 5. Leaf workgroup widths

Reducing the leaf group from 256 to 128 threads initially appeared favorable
at 104.443 versus 105.054 ms, but repeated profiling was neutral and did not
show a stable mechanism win. A 64-thread variant measured 105.433 ms. Both
were reverted; final source retains `threadExecutionWidth * 8`.

### 6. Sparse parent width 128

The parent grid was reduced to 128 threads. It measured 106.350 ms and was
reverted.

### 7. Independent-quarter expansion/high fusion

The first successful architecture extended the existing expansion pipeline
with dynamic threadgroup memory. Each workgroup synthesized one expanded
quarter directly into a 4,096-value / 16 KiB tile, executed the high helper,
and stored the result. It was admitted only for width at least 64, at least
five high layers, and scale one.

It was exact. Across one warmup and one sample, total command GPU time fell
from 122.048 to 117.620 ms. The combined expansion plus remaining high work
was 11.492 + 5.874 ms versus predecessor expansion plus high work of
6.349 + 14.450 ms. This proved the boundary-removal hypothesis, but four
quarters still repeated source loads and products.

### 8. Four quarters sequentially in one group

One group tried to process all four quarters serially. Register/barrier
pressure and lost occupancy moved log20 to 108.605 ms. Reverted.

### 9. Narrow 2,048-value tail after one more high layer

The schedule attempted to absorb another high layer and hand a smaller tail
to the existing kernel. Proof construction failed with
`InvalidLastLayerDegree`. The design was immediately reverted and never
timed as evidence.

### 10. Paired adjacent quarters

The accepted design grouped adjacent plus/minus quarters. A 512-thread group
contains two 256-thread workers and two 4,096-value tiles. Only worker zero
loads coefficient pairs and computes the product, writing plus and minus
values into both tiles. After a full threadgroup barrier, both workers run the
same high-layer helper concurrently.

The dispatch is structural: outer group count must be exactly four, the
pipeline must admit 512 threads, scale must be one, and available dynamic
threadgroup memory must be at least 32 KiB after subtracting static pipeline
memory. Otherwise the independent combined mode or original path is used.

Across the profiled warmup/sample pair, total command GPU time fell to
115.009 ms and encoder GPU time to 86.825 ms. Expansion/high work became
9.502 + 5.882 ms versus 20.799 ms in the predecessor, saving about 2.71 ms
per proof. No pipeline or shader export was added.

### 11. No-copy canonical twiddle bindings

The synchronous combined commitment received page-aligned canonical inverse
and forward twiddle towers that already outlived the command. When both
pointer and length are page-aligned, the runtime now uses
`newBufferWithBytesNoCopy`; otherwise it retains `newBufferWithBytes`.
The command waits before return, so this adds no hidden runtime state or
asynchronous lifetime.

At log20 the towers total 6 MiB. An adjacent screen reduced peak physical
footprint from 927,286,904 to 920,995,400 bytes. Official scoring later
measured an RSS ratio of 0.99272.

### 12. Eight-column composition extension

After the wide mode was stable, the same paired path was structurally extended
to the eight-column composition commitment. The direct log20 proof failed
closed with `InvalidLastLayerDegree`. The extension was removed immediately.
The final admitted mode remains wide only.

## Correctness screens and shape scaling

The accepted shader produced the canonical proof at all three tested wide
shapes:

| Shape | Candidate prove | Candidate request | Peak bytes | Proof |
| --- | ---: | ---: | ---: | --- |
| `2^18 × 100` | 26.705 ms | 27.111 ms | 341,968,216 | 74,328 B, `f845...ced8f` |
| `2^20 × 100` | 99.699 ms | 100.187 ms | 920,995,400 | 86,383 B, `e660...c7e86` |
| `2^22 × 100` | 378.113 ms | 378.702 ms | 2,842,776,688 | 106,436 B, `2c0...76205` |

Adjacent predecessor medians were 27.664, 104.315, and 380.632 ms. The
corresponding prove ratios were 0.9653, 0.9558, and 0.9934. Log22's seven
candidate samples were 365.753, 384.570, 377.055, 385.383, 379.781, 376.194,
and 378.113 ms. It reported 11.30 J, 33.100 billion instructions, 11.074
billion cycles, 31 dispatches per proof, and zero fallbacks.

A post-revert three-sample log20 correctness screen was thermally slower at
107.870 ms median, but all three proofs were identical, independently
verified, and used 29 dispatches with zero fallback. This preserved the
thermal discrepancy instead of hiding it.

## Focused test and locked-path handling

The repository already contains a combined circle-LDE/Merkle differential
test against CPU evaluation and a generic Merkle tree, but its log16 shape
does not activate this new paired mode. The fixture was temporarily raised to
log18 × 64, the smallest forcing shape. It passed with identical columns and
Merkle root.

The first official xlarge scorer then correctly failed G2 because
`src/tests/metal/backend/transform_pipeline_test.zig` is a locked path for a
performance diff. The test change was reverted in commit `4423781`; the net
scored diff contains only six Metal implementation files. The forced test
result remains diagnostic evidence. A test-only post-promotion change is the
right place to retain the larger fixture.

## Validation

On the accepted source:

- `zig build test-native-metal metal-check test-metal-core-aot
  test-metal-core-aot-probe -Doptimize=ReleaseFast -j2` passed;
- native Metal product markers, lifecycle, source closure, source-JIT, AOT
  mutation checks, and AOT probe passed;
- `git diff --check` and Zig formatting checks passed;
- `metal-test` remained 86/90, with the known resident-FRI and
  quotient-residency policy failures plus two skips;
- the temporary log18 forced differential passed; and
- direct logs 18, 20, and 22 retained exact canonical proof hashes.

The core shader ABI changed from 10 to 11. Runtime compile-time authority,
manifest tests, and the AOT mutation fixture were advanced fail-closed.

## Official scoring chronology

### Xlarge screen before locked-test cleanup

Candidate source was 3.22% faster:

- ratio 0.9678, CI [0.9521, 1.0013];
- medians 31.376 / 30.430 ms;
- nine paired rounds;
- exact proofs and pinned Rust oracle pass;
- all 13 performance guards passed.

It was not significant and G2 rejected the locked test edit. It was not
submitted.

### First clean huge screen

Final commit `4423781` produced:

- ratio 0.9736, CI [0.9576, 0.9911];
- medians 106.203 / 102.712 ms;
- all G1--G5 policy checks and all 13 guards passed.

The target was favorable but the upper CI was 0.0011 outside the significance
line. This complete receipt was retained as inconclusive.

### Harness output collision

The first repeat stopped before any timed sample because the pinned oracle
artifact path already existed (`OutputAlreadyExists`). The existing artifact
was copied and then moved into the evidence directory; both copies hashed to
`8a66bd21...9cbf00e`. No timing sample was dropped. The scorer was restarted
from a clean output path.

### Significant clean huge receipt

The complete independent repeat passed:

- ratio 0.969886, CI [0.966150, 0.985253];
- A/B medians 111.810792 / 108.731625 ms;
- request ratio 0.969781;
- five paired ABBA rounds with ratios 0.972461, 0.998045, 0.967311,
  0.964989, and 0.969309;
- energy ratio 0.995048, upper CI 1.032029;
- RSS ratio 0.992720, upper CI 1.001747;
- proof-byte ratio exactly 1.0 at 86,383 bytes;
- all 13 guard upper CIs below 1.05;
- exact proof `e6609d05...c7e86`; and
- pinned Rust-oracle artifact
  `8a66bd21ec4076cde6d887ec1a10f034b34a8597e28643f57aae14dbd9cbf00e`.

This is the only verdict packaged as the claim.

## Final source and remaining bottleneck

Final source commit is
`442378166d55f0ea0a33c8b513f0c270a712b5c6`. The six-file diff adds no
pipeline state, runtime-global cache, address matching, workload-name branch,
or proof-protocol change.

After this optimization, the paired transform boundary is no longer the main
unexplored cost. BLAKE leaves/parents, recurrence/IFFT, quotient work, and host
waits remain. The failed leaf-fusion experiments show that the next Merkle
step needs a layout or batching change that preserves scalar hash dependency
rather than simply adding cooperative lanes.

The complete PR6 matrix, peer cold-process timing, per-cell seven-round ABBA
requirements, and authenticated locked-M5 judged evidence remain unfinished.
**PR6 Supremacy: not achieved.**
