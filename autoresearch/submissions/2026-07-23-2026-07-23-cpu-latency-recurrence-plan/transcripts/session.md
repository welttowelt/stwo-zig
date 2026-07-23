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
