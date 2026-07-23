# Explicit resident quotient-to-FRI transaction

## Model and harness

Model: GPT-5 Codex. The final candidate is clean commit
`63de90c16ca7`, rebased onto and paired against
current main `2beae9d03b33bc9c5b0b21bb445439799786f2fb`. The repository-resident
`stwo-perf` harness identity is `6895a1942700`; builds use Zig 0.15.2
ReleaseFast on the designated arm64 macOS Apple M5 Max host. The claimed board
is `core_metal/wide/time` at S3.

The final source delta touches only manifest-approved Metal backend paths,
`src/prover/fri.zig`, and `src/prover/pcs/fri_lazy_commit.zig`. It does not
change an AIR, statement, trace, protocol, security parameter, transcript
order, proof encoding, admission budget, or fallback policy.

## Hypothesis

The resident Metal pipeline already retained committed trace trees and computed
quotients on the GPU, but two proof-wide boundaries remained:

1. quotient construction flattened resident host columns into a new shared
   upload buffer below a 64 MiB raw-input threshold, even when explicit
   proof-session tree handles already owned matching GPU buffers; and
2. quotient commitment, transcript challenge generation, circle-to-line
   folding, and the remaining FRI layers each crossed host synchronization
   boundaries.

At width 100, log16, profiling attributed about 6.3--7.4 ms to quotient input
preparation while the actual quotient GPU work was below 1 ms. The predicted
win was therefore not a faster field kernel. It was removal of a complete
proof-domain copy plus one ordered quotient-to-FRI transaction.

## Changes

The candidate adds an explicit backend hook for a lazy FRI transaction. The
Metal implementation:

- receives the quotient provider's explicit resident tree handles;
- validates every handle against the current runtime and proof-session owner;
- binds structurally matching resident source ranges directly;
- commits the quotient tree, mixes its root, and draws the circle-fold
  challenge into a GPU transcript buffer;
- submits the circle fold and complete line-FRI Merkle cascade on the same
  queue without an intervening host wait; and
- performs one final synchronization before canonical host transcript state is
  consumed.

The direct resident route is admitted from ownership and byte-range structure,
not workload names or benchmark sizes. It begins at 8 MiB only when at least
one explicit resident tree is present. Nonresident inputs retain the existing
safe upload path; raw inputs of at least 64 MiB retain the existing GPU
numerator route. A compatibility wrapper preserves the public line-only FRI
cascade API.

There is no runtime-wide tree discovery or hidden address registry. Address
arithmetic is used only inside the call-local, explicitly supplied residency
set. Runtime ownership, range, overflow, and buffer-size checks fail closed.

## Profiles and rejected variants

Before the accepted change, log16 quotient preparation cost about 6.3--7.4 ms,
the quotient FFI boundary about 9--10 ms, GPU quotient work about 0.54--0.70
ms, and FRI GPU work about 1.1 ms. With direct resident sources, quotient
preparation fell to roughly 19--30 microseconds and the warmed quotient FFI
boundary to about 2.44--2.60 ms. Peak physical footprint at the same point fell
from roughly 347--355 MB to about 250--252 MB.

Two plausible variants were rejected:

- An Objective-C FRI scratch arena won one short half and lost the second.
- A fold-plus-Merkle-subtree shader fusion preserved exact proofs but increased
  FRI GPU time from roughly 0.6 ms to more than 1.3 ms and worsened the full
  FFI boundary.

Both were completely removed. The first accepted checkpoint fused the circle
fold with the line cascade. The second made quotient root/challenge production
an explicit predecessor command buffer. The final change removed the resident
host flattening copy.

## Results

The final manifest-owned `mwf_log14x32` objective ran 15 paired rounds:

| metric | predecessor | candidate | ratio / 95% CI |
| --- | ---: | ---: | ---: |
| prove median | 4.690500 ms | 4.272916 ms | **0.917360 [0.890170, 0.941496]** |
| verified request | — | — | 0.925558 |
| energy | — | 0.309276 J | 1.004248 [0.991469, 1.020370] |
| peak RSS | — | 164.923 MiB | 1.016173 [1.015834, 1.016466] |
| proof bytes | 41,840 | 41,840 | 1.0 |

The objective-only claimed verdict passes G1--G5 and is statistically
significant under the board's 0.038838 threshold. Every timed proof verified,
cross-arm canonical digests matched in every round, and the pinned Rust Stwo
oracle accepted the workload.

A separate full-impact run retained all 13 guards. Eleven passed; Blake
log12x16 and Poseidon log13 exceeded the 1.05 guard budget in that thermally
long run. The scored wide point still improved 8.3%, with CI
`[0.8731, 0.9613]`, missing significance by approximately one basis point.
This failed full-guard diagnostic is published with the session and is not
represented as a passing verdict. The remote judge must re-run the complete
guard portfolio.

## System-level series

At clean measured source commit `3bcf62a`, ten warmups and seven verified
samples per point produced the following Metal medians:

| log rows | request ms | proof bytes | peak physical bytes |
| ---: | ---: | ---: | ---: |
| 14 | 9.314250 | 48,180 | 172,770,408 |
| 16 | 11.705125 | 61,470 | 251,856,168 |
| 18 | 26.133375 | 74,328 | 348,898,336 |
| 20 | 96.701041 | 86,383 | 923,993,696 |
| 22 | 358.135416 | 106,436 | 2,978,026,656 |

All 35 measured proofs verified, were byte-identical within each point, and
reported zero Metal CPU fallbacks. The already-promoted structural CPU plan is
still the lower-latency log14 route at 7.436208 ms. Using that CPU log14 point
and the exact-head Metal points for logs 16--22 gives ratios
`0.683711, 0.570024, 0.373537, 0.359706, 0.312559` against the frozen
fixed-protocol baseline. Their geometric mean is **0.439335**, or **2.2762x**
portfolio-wide.

The transaction was subsequently split into focused modules to satisfy the
repository's 850-line manual-source ceiling. Final candidate `63de90c16ca7`
passes source conformance, preserves the exact log16 proof digest, and records
11.913167 ms in the post-split check. Its final manifest-owned paired verdict
is the result reported above.

This clean screen satisfies the task's planning thresholds, but it is not a
replacement for seven complete same-host ABBA rounds at all five sizes and
both timing boundaries. A clean log16 A-B-B-A screen against then-current main
measured 20.004 vs 11.986 ms and 21.767 vs 11.580 ms; both halves won.

## Correctness and lifecycle validation

- `zig build test-native-metal -Doptimize=ReleaseFast` passed product closure,
  device-only proving, and independent artifact verification.
- The full Metal unit suite passed 88 tests with two intentional skips on a
  retained test-only commit.
- A focused test forced the combined circle/line cascade and compared every
  Merkle root, transcript challenge, terminal value, command-buffer count, and
  wait count with the generic CPU path.
- Existing simultaneous-proof, allocator-address-reuse, mixed
  resident/nonresident, ownership-transfer failure, live-tree shutdown, and
  stale-discovery tests remain applicable because the production API uses
  explicit handles.
- Canonical proof bytes and sizes are unchanged at all five fixed-protocol
  sizes.

The focused test commit is deliberately not part of this performance
submission because repository policy marks tests as a locked path. It is
retained for a separate governance follow-up rather than weakening the
source-only promotion contract.

## Caveats

This is a claimed advisory verdict; only the locked judge can authenticate a
promotion. Cold-process ABBA, the complete all-size statistical experiment,
and the remaining exact PR6 workload/oracle matrix are still incomplete.
Consequently:

> **PR6 Supremacy: not achieved.**
