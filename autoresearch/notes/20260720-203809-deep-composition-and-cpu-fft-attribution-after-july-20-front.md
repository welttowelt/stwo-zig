---
title: Deep composition and CPU FFT attribution after July 20 frontier
author: welttowelt
created_utc: 2026-07-20T20:38:09Z
---

Current Apple result: CPU FFT task splitting plus constant-column folding on
top of main 5d2eb59 gives deep/time S3 0.9097 [0.8759, 0.9340] with default
workers and 0.8943 [0.8668, 0.9225] with four workers. Proofs are exact. The
stage attribution is direct: preprocessed/main interpolation drops from about
0.230-0.245 ms to 0.077-0.134 ms, extended evaluation from 0.279-0.315 ms to
0.168-0.231 ms, and composition evaluation from 0.501-0.523 ms to 0.162 ms.

The constant-column mechanism transfers across two 2-vCPU x86 Runpod lanes:
constant-only deep ratios were about 0.975-0.979 and composition evaluation
fell by roughly half. CPU FFT splitting was neutral on those two-core workers,
so treat it as topology-specific until the Apple judge reruns it. Apple wide
and small regression medians remained inside the 5% matrix-row budget.

Rejected or deferred directions:

- Four-lane packed FRI fold arithmetic improved the isolated fold to 0.8970
  [0.8739, 0.9105], but wide S3 was 1.0502 [0.9184, 1.2793].
- Accumulator ownership transfer was neutral at wide S3 1.0107
  [0.9761, 1.0395].
- Generic four-chain CM31 batch inversion was neutral end to end and 1.53-1.63
  times slower than the classic helper in x86 live-code microbenchmarks.
- Conjugate-pair quotient domain points passed differential tests and were
  favorable but not significant on Apple; x86 diagnostics suggest revisiting
  them only as a separately attributed quotient candidate.
- Reusing cached inverse FRI twiddles cut an isolated 2^14 line fold to 0.2545
  [0.2498, 0.2581], yet no small, wide, or deep S3 row cleared the gate.

Operational note: after the July 20 upstream refresh, stwo-perf sync raises a
missing-board argument error in its frontier view call. A normal rebase onto
current main supplied the full updated harness and source tree, so no policy
bypass was used.
