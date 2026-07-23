# System-level 2x session transcript

## Research request and operating contract

The requested objective was a fixed-protocol, system-level 2x acceleration
against frozen commit `0cca924`, scored by geometric mean over width-100 logs
14, 16, 18, 20, and 22. Promotion requires at least 1.5x, every point must
improve, no point may exceed ratio 0.80, and correctness, proof identity,
security parameters, trace work, and request boundaries must remain fixed.
The user explicitly requested profiling before implementation, structural
rather than benchmark-specific work, broad guards, complete notes and
transcripts, and immediate submission once a significant result existed.

I updated the canonical checkout before work. At final scoring the remote main
advanced only in the automerge workflow, so I refreshed the repository and
rebased the candidate onto `4259c8486593` before producing clean evidence.

## Grounding measurements

The immutable CPU baseline medians were 10.876250, 20.534459, 69.961875,
268.833292, and 1145.818167 ms. Each point retained protocol identity,
executable/source identity, resource data, and deterministic proof bytes.

Unmodified current-main CPU requests were:

| log rows | request ms | ratio to frozen CPU |
| ---: | ---: | ---: |
| 14 | 10.545875 | 0.969624 |
| 16 | 20.428583 | 0.994844 |
| 18 | 71.573542 | 1.023036 |
| 20 | 280.025042 | 1.041631 |
| 22 | 1142.079583 | 0.996737 |

The unmodified promoted Metal path was already the throughput plan:

| log rows | request ms | ratio to frozen CPU | peak physical bytes |
| ---: | ---: | ---: | ---: |
| 14 | 9.311083 | 0.856093 | 198,558,896 |
| 16 | 19.250667 | 0.937481 | 347,211,000 |
| 18 | 26.434292 | 0.377839 | 341,706,120 |
| 20 | 100.104875 | 0.372368 | 920,995,496 |
| 22 | 387.879875 | 0.338518 | 2,843,989,224 |

Every measured Metal proof matched CPU canonical bytes and reported zero CPU
fallbacks. Metal already reduced log22 physical footprint about 58.7% versus
the frozen CPU result. Its five-point geometric ratio was 0.520557, so the
largest leverage was the fixed-cost log14/log16 end rather than another large
throughput kernel.

## Profiles and architectural interpretation

CPU stage profiles and CPU Time Profiler samples were captured at logs 14, 18,
and 22 before edits.

- At log14, generic secure-composition evaluation cost about 4.18 ms. This
  was a fixed-cost opportunity large enough to change the whole request.
- At log18, main commitment cost about 27.4 ms, including about 11 ms of
  Merkle work; the proof core was about 39 ms and quotient/FRI about 20 ms.
- At log22, main commitment was about 480 ms (Merkle about 170 ms),
  composition evaluation about 60 ms, composition commitment about 89 ms,
  sampled-value evaluation about 65 ms, and FRI about 278 ms. Blake hashing,
  FFT passes, and memory traffic dominated.

Metal stage and command-buffer telemetry was captured at logs 14, 16, 18, and
22. Log14 paid ten command buffers per request and roughly 5.58 ms of GPU
time; line FRI, Merkle, and LDE were the largest GPU slices. Log16 paid seven
buffers and about 4.6 ms for combined LDE/Merkle. Logs 18 and 22 were
throughput-dominated and benefited from the already-promoted resident pipeline.

The resulting execution-plan map was:

```text
latency/cache-resident                 bandwidth/capacity
log14 -------- log16 -------- log18 -------- log20 -------- log22
 CPU packed       unresolved       promoted resident Metal pipeline
 recurrence
```

The guiding conclusion was that one backend should not be forced across every
regime. CPU has lower dispatch/fixed cost, while Metal wins decisively once
resident full-domain work amortizes command submission.

## Rejected experiments

All rejected edits were reverted before the final commit.

1. **Lower the combined/deferred Metal threshold to log14.** Proofs were exact,
   trace synchronization stayed absent, and fallbacks stayed zero, but request
   time worsened to 10.858 ms at log14 and 23.590 ms at log16 versus 9.311 and
   19.251 ms. Fixed command and transform overhead exceeded the saved copy.

2. **Smaller fused trace tiles.** Tile 11 and tile 10 produced exact log16
   requests of 22.612 and 22.377 ms. Both lost to the split plan.

3. **Split recurrence generation and inverse FFT in one deferred command.**
   An initial normalization mistake correctly failed constraint verification.
   After fixing normalization, proof bytes were exact and fallback count was
   zero, but paired request time was 21.079 ms versus 19.442 ms current. The
   extra global pass and synchronization outweighed the producer benefit.

4. **Static contiguous CPU column ranges.** Eighteen fixed jobs made one log14
   screen about 7 ms but regressed log16 to 22.53 ms versus about 20.28 ms.
   Worker sweeps at 4/8/12/16 threads gave 48.35/30.33/24.18/20.74 ms; the
   default 18-worker dynamic schedule was best. Merkle worker sweeps also
   favored the default. Apple heterogeneous cores need fine-grained work
   stealing here.

5. **Adopt one contiguous CPU trace arena as coefficient storage.** This
   removed a detach copy and screened with lower RSS at log16/log18/log20,
   while requests moved only modestly. The decisive clean S3 xlarge run was a
   regression: ratio 1.0147, CI [1.0003, 1.0294], 66.007 ms predecessor versus
   67.444 ms candidate. The entire ownership implementation and extraction
   were removed rather than carried as uncredited complexity.

The rejection ledger matters because several mechanisms looked attractive in
isolated stage timing. Full verified requests and paired scheduling reversed
those conclusions.

## Accepted mechanism

Main already contained a specialized recurrence composition evaluator, but it
admitted only evaluation logs at least 17 and traces with at least 64 columns.
It is not a benchmark shortcut. Admission requires:

- exactly one component with the quadratic-sum-of-squares backend capability;
- the declared trace-tree index and no unrelated nonempty tree;
- `constraints == columns - 2`;
- a uniform power-of-two evaluation domain;
- packed row divisibility;
- strictly contiguous columns with one stable stride.

Once admitted, it walks trace storage directly, reuses adjacent squares,
evaluates two independent packed row groups to break the multiply dependency
chain, pre-packs random secure powers, uses the two coset denominator values,
and partitions rows over the persistent worker pool. The generic evaluator
otherwise pays component/constraint abstraction overhead across the full
domain.

Profiling predicted that worker fan-out would amortize at an evaluation domain
of 2^15. A width-100 screen confirmed a request near 7 ms. Lowering only the
domain threshold admitted that point. A second structural screen lowered the
minimum column count to 32, which admitted the manifest-owned width-32 shape
and changed prove time from about 6.18 ms to 4.93 ms while retaining exact
proof bytes. The final diff therefore changes only the two admission bounds
and comments.

## Clean scored result

Candidate `932aa7d2458b` was built ReleaseFast from a clean tree and paired with
current main `4259c8486593`.

| metric | predecessor | candidate | ratio / CI |
| --- | ---: | ---: | ---: |
| prove median | 6.286708 ms | 4.960083 ms | 0.791173 [0.783665, 0.801629] |
| verified request | — | — | ratio 0.807709 |
| energy | — | 1.283553 J | 0.943872 [0.809603, 0.948983] |
| peak RSS | — | 21.7196 MiB | 0.998743 [0.996406, 1.000721] |
| proof bytes | 41,840 | 41,840 | 1.0 |

Seven ABBA rounds were retained. G1-G5 passed, the pinned Rust Stwo oracle
accepted the workload, and all 13 impact-mapped regression guards stayed
inside their 1.05 upper-CI budgets. Proof digest was
`57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`.

The final clean width-100 log14 diagnostic recorded 7.436208 ms verified
request, ratio 0.683711 against the frozen 10.876250 ms baseline, with seven
identical verified 48,180-byte proofs and digest
`ee3cb0957a56876a3d4c0ce6332115137ddb9b9766ac902beafd002fbe0b74ed`.

Correctness validation included:

- Native CPU product closure;
- prover source closure;
- source-conformance checks with no new findings;
- a 13-row holistic Native CPU/Metal smoke across wide Fibonacci, XOR, Plonk,
  state machine, Blake, and Poseidon;
- identical CPU/Metal canonical proof bytes on all 13 rows;
- the scored Rust-oracle acceptance and paired proof equality.

## System-level status and next bottleneck

Using the clean CPU log14 result and the already-promoted Metal medians for
logs 16 through 22 gives ratios:

```text
log14  0.683711  CPU packed recurrence
log16  0.937481  Metal — blocking cell
log18  0.377839  Metal resident pipeline
log20  0.372368  Metal resident pipeline
log22  0.338518  Metal resident pipeline
geomean 0.497667 = 2.0094x
```

That geometric mean crosses 2x diagnostically, but the task is not complete:
log16 violates the required 0.80 individual ceiling, cold-process ABBA has not
been run, and the product does not yet expose one automatic structurally
selected CPU/Metal execution plan. The next material target is therefore
log16 fixed overhead: fewer FRI/Merkle command-buffer waits or a CPU compiled
component plan that also reduces commitment and FRI cost. Repeating large
resident-pipeline work has much less portfolio leverage.

**PR6 Supremacy: not achieved.**

## Metal quotient-to-FRI epoch

### Why the next epoch targeted log16

After the CPU recurrence-plan promotion, the diagnostic best-backend envelope
had already crossed a 2x geometric mean, but Metal log16 remained at ratio
0.937481 against the frozen CPU request baseline and violated the task's 0.80
per-cell ceiling. Logs 18--22 were already strong because the resident Metal
pipeline amortized its fixed costs. The new epoch therefore targeted
proof-wide waits and copies rather than another large-domain shader kernel.

The starting architecture committed trace/LDE data into resident Metal trees,
but quotient construction still accepted host column slices. It used explicit
tree handles for safety, then selected either a flat shared upload or GPU raw
numerator path. Below 64 MiB, width-100 log16 flattened 108 raw columns into a
fresh shared buffer. Profiling showed this host preparation was far larger than
the quotient kernel itself.

### First checkpoint: circle fold into line cascade

The first implementation added a generic optional
`commitFriCircleLayers` hook and extended the Metal FRI line cascade with an
optional resident circle source and alpha. The circle fold and every line FRI
fold/Merkle commitment then executed inside one command-buffer epoch and one
host wait.

A clean short A-B-B-A checkpoint against main measured:

- main A1 20.5095 ms;
- checkpoint B1 18.735042 ms;
- checkpoint B2 18.434833 ms; and
- main A2 22.329 ms.

Both halves won and canonical proof bytes remained exact. This established
that collapsing the synchronization boundary helped, but the remaining
quotient preparation was still dominant.

### Second checkpoint: explicit quotient transcript dependency

The second implementation added `commitLazyFriTransaction`. Quotient
construction and the first Merkle root run in command buffer A. Its root is
mixed and the circle challenge drawn into a GPU transcript buffer. Command
buffer B copies that state, consumes the challenge, folds circle to line, and
commits every remaining FRI layer. Both command buffers are submitted in order
to one queue without a host wait between them; the host waits only after B.

This is an explicit dependency graph:

```text
explicit resident trace handles
          |
          v
quotient + first Merkle + transcript draw   command A
          |
          | same queue, GPU transcript buffer
          v
circle fold + all line FRI commitments      command B
          |
          v
one final wait -> canonical host channel
```

Incremental A-B-B-A against the first checkpoint measured 18.877042 and
19.162708 ms for the checkpoint versus 18.676833 and 18.821542 ms for the
full transaction. Both halves won by roughly 1.1--1.8%.

### Dominant discovery: the resident host copy

Temporary stage instrumentation then separated preparation, Objective-C FFI,
GPU quotient, and FRI work. Before the final change:

- quotient input preparation: about 6.3--7.4 ms;
- complete quotient FFI: about 9--10 ms;
- quotient GPU work: about 0.54--0.70 ms; and
- FRI GPU work: about 1.1 ms.

The surprising result was that the "resident" proof still copied a complete
log16 raw domain on the host. The existing GPU-raw threshold was 64 MiB, so
the structurally resident log16 source remained on the flattening route.

The accepted fix makes the route conditional on explicit residency:

```text
raw bytes >= 64 MiB
    OR
explicit resident tree set is nonempty AND raw bytes >= 8 MiB
```

For each call, Objective-C validates the supplied trees against the current
runtime, searches only that explicit array for containing source ranges, and
binds the owning Metal buffer at a checked byte offset. No tree registry,
last-proof pointer, or runtime-wide discovery exists. Columns not covered by
an explicit tree retain the call-local upload/alias path.

After this change, preparation fell to roughly 19--30 microseconds, the warmed
FFI boundary to about 2.44--2.60 ms, and log16 peak physical footprint from
roughly 347--355 MB to about 250--252 MB. A first clean screen measured
16.214792 ms; after the complete transaction was rebuilt cleanly and warmed,
the stable paired candidate arms measured 11.985958 and 11.580167 ms.

### Rejected Metal variants

Two additional variants were evaluated and removed.

1. An Objective-C FRI scratch arena reduced allocation churn in one half but
   lost the reverse half. It was not stable enough to retain.
2. A shader that fused the fold with a Merkle subtree preserved exact output
   but increased FRI GPU time from about 0.6 ms to more than 1.3 ms and pushed
   the full boundary from about 8 ms to 9.5 ms or more. Register/threadgroup
   pressure and reduced scheduling flexibility outweighed the removed
   dispatch.

These failures reinforced that GPU fusion is profitable only when it removes
real synchronization or traffic. Combining kernels merely to reduce dispatch
count can regress the complete proof.

### Clean exact-head portfolio

The source-only PR head is
`3bcf62a34357b67f64cd9a7de090aaf892a4bf6a`, paired against current main
`2beae9d03b33bc9c5b0b21bb445439799786f2fb`. It was rebuilt ReleaseFast from a
clean tree after updating the canonical autoresearch CLI.

Ten warmups and seven verified requests at every width-100 point produced:

| log | Metal request ms | proof bytes | proof SHA-256 prefix | peak bytes |
| ---: | ---: | ---: | --- | ---: |
| 14 | 9.314250 | 48,180 | `ee3cb0957a56` | 172,770,408 |
| 16 | 11.705125 | 61,470 | `70d26c4a0c79` | 251,856,168 |
| 18 | 26.133375 | 74,328 | `f845568c1459` | 348,898,336 |
| 20 | 96.701041 | 86,383 | `e6609d0564a4` | 923,993,696 |
| 22 | 358.135416 | 106,436 | `2c0ca9f7a73e` | 2,978,026,656 |

All 35 proofs independently verified, every point was internally
byte-deterministic, and Metal reported zero CPU fallbacks. Using the promoted
CPU log14 plan at 7.436208 ms and Metal for logs 16--22 yields frozen-baseline
ratios:

```text
log14  0.683711  CPU packed recurrence
log16  0.570024  Metal explicit quotient-to-FRI transaction
log18  0.373537  Metal resident throughput plan
log20  0.359706  Metal resident throughput plan
log22  0.312559  Metal resident throughput plan
geomean 0.439335 = 2.2762x
```

Every point is improved and every ratio is below 0.80. This is the first clean
candidate lineage in the session to meet the requested system-level planning
goal at all five points.

### Paired verdict and guard interpretation

The exact-head manifest-owned `core_metal/wide` objective used 12 paired
rounds. Prove time fell from 4.610666 to 4.160917 ms, ratio 0.905699 with 95%
CI `[0.879904, 0.915178]`. Verified-request ratio was 0.918181, proof size
remained 41,840 bytes, energy ratio was 0.998820, and RSS ratio was 1.017622.
G1--G5 passed and the pinned Rust oracle accepted the proof.

A preceding full-impact run exercised all 13 guards after 15 objective rounds.
Eleven guards passed; Blake log12x16 and Poseidon log13 exceeded the 1.05
budget. Its wide objective still improved 8.3%, with CI ending at 0.9613,
approximately one basis point outside the significance boundary. No sample was
discarded. The failed result is retained in
`verdict-metal-resident-fri-wide.json` and its 174 raw files are preserved in
`runs-wide-full-3bcf62a/`. The passing objective verdict is
`verdict-metal-resident-fri-wide-objective.json`. The remote judge must settle
the long-portfolio guard result.

### Correctness, API, and test-path handling

`test-native-metal` passed product identity, device-only lifecycle,
independent proof verification, and a 259-source closure. A test-only commit
then updated the old line-cascade call and added a forced combined
circle/line-cascade comparison. It checked every Merkle root, transcript
challenge, final value, command-buffer count, wait count, and dispatch count
against the generic CPU calculation. The complete Metal unit run passed 88
tests with two intentional skips.

Repository policy prohibits test files in a performance submission. The
passing test-only commit `b5f367a` was therefore retained in history and
reverted from PR #100. Production source gained a compatibility wrapper so
the legacy line-only API remains valid; the combined production call has an
explicit separate name. The coverage change is suitable for a governance
follow-up.

### Remaining contract work

The system-level five-point screen and one manifest-owned claimed verdict are
not the final authenticated task verdict. Remaining work includes seven
complete ABBA rounds at every size, cold-process boundaries, final broad
guards on the locked judge, and the full exact PR6 oracle matrix.

**PR6 Supremacy: not achieved.**

## Final conformance split and verdict rebinding

After packaging the first submission, the local source-conformance gate caught
three files above the 850-line manual-source ceiling. The transaction logic was
mechanically split into:

- `src/backends/metal/runtime/resident_fri_transaction.zig`;
- `src/backends/metal/runtime/fri_cascade_operations.zig`; and
- `src/prover/pcs/fri_lazy_commit.zig`.

The first location chosen for the prover helper was beside `fri.zig`. A
re-verdict correctly failed G2 because new root-level prover files are outside
the editable surface. Moving the helper under the manifest-approved
`src/prover/pcs/**` subtree resolved the policy failure. No arithmetic,
dispatch, threshold, ownership, or transcript code changed during either move.

Intermediate split candidate `a94b70436d2f` had all manual source files at or
below 850 lines, source-conformance reported no new violations, and the
ReleaseFast Metal benchmark built. A post-split log16 check measured 11.913167
ms, preserved 61,470 proof bytes and SHA-256
`70d26c4a0c7928195f8ea6311a8b109acfa42a0559313b80700aee8c924a8601`,
verified all seven samples byte-identically, and reported zero fallbacks.

The verdict was re-run rather than attributing pre-split evidence to the new
tree. The first intermediate-tree run landed just outside significance:
ratio 0.930549, CI `[0.897184, 0.961957]`, versus a 0.961162 boundary. It was
retained without discarding samples. The independent repeat passed:

| metric | predecessor | candidate | ratio / 95% CI |
| --- | ---: | ---: | ---: |
| prove | 4.706750 ms | 4.262042 ms | 0.904337 [0.882816, 0.923730] |
| request | — | — | 0.905364 |
| energy | — | 0.303531 J | 0.997752 [0.986580, 1.007611] |
| RSS | — | 165.173 MiB | 1.017520 [1.017082, 1.017618] |

All G1--G5 gates passed over 15 paired rounds. This verdict was temporarily
packaged, then superseded when aggregate product-closure CI exposed one final
file-placement issue.

## Product-closure correction and immutable final verdict

Focused macOS CI compiled the Metal product and passed all 72 tests, then
failed the aggregate product-closure receipt because
`resident_fri_transaction.zig` was a new file at the Metal backend root. The
aggregate closure explicitly admits `src/backends/metal/runtime/**`, so the
helper moved there and its three imports changed to parent-relative paths.
The exact CI command,
`zig build test stwo-zig -Daggregate-metal=true -Doptimize=ReleaseSafe -j2`,
then passed locally with a 433-source closure.

Because this file move changed the source tree, the verdict was bound again.
The first `63de90c16ca7` run retained all samples but was inconclusive:
ratio 0.9164 with CI `[0.8985, 0.9698]`. The independent repeat was
significant over 15 rounds:

| metric | predecessor | candidate | ratio / 95% CI |
| --- | ---: | ---: | ---: |
| prove | 4.690500 ms | 4.272916 ms | 0.917360 [0.890170, 0.941496] |
| request | — | — | 0.925558 |
| energy | — | 0.309276 J | 1.004248 [0.991469, 1.020370] |
| RSS | — | 164.923 MiB | 1.016173 [1.015834, 1.016466] |

All G1--G5 gates pass, proof bytes remain exactly 41,840, and the pinned Rust
oracle accepted the measured proof. This is the immutable verdict used by the
final package.

**PR6 Supremacy: not achieved.**
