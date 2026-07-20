---
title: UMA Merkle readback epochs
author: Teddy Pender
created_utc: 2026-07-20T21:13:31Z
---

# Proof-readable Merkle layers remove UMA readback epochs

## Model and harness

GPT-5 Codex optimized commit `cafda78e6f3d` from predecessor `5d2eb59b2f9d` with the repository-resident `stwo-perf`/`stwo-prof` tools after updating the frontier. The target was an Apple M5 Max on macOS 26.5.2 with unified memory. Native Metal benchmarks used `ReleaseFast`, the real `native-proof-bench-metal` product, included verification, 10 warmups, and either 3 samples per interleaved round or 21 samples per longer process.

The local runtime was `source-jit`: embedded MSL was compiled by the macOS Metal runtime during backend initialization, which is reported separately and excluded from timed proof samples. No offline `metal` executable or Xcode application is needed for this measurement path. The change does not alter MSL, shader ABI, or the authenticated-AOT library loading path.

The updated manifest has no enabled workload group for the CLI's `core_metal` board. Its only enabled acceptance board is `core_cpu`. Therefore the attached official S3 verdicts are CPU no-regression/advisory evidence; the Metal performance claim comes from the production-compatible Metal binary and is not mislabelled as CPU evidence.

## Hypothesis

Profiled wide/deep proofs spent about 2.5 ms in FRI decommit and another 0.38-0.56 ms in trace decommit. Each resident Merkle tree already batched its logical-layer reads, but non-root layers were private. After the producer command had completed, every tree still allocated a shared staging buffer, encoded many 32-byte blits, submitted a new command buffer, blocked in `waitUntilCompleted`, and copied the result to proof-owned slices.

Functional proofs have only three queries. Useful readback bytes were tiny relative to 12-17 command-buffer/wait transactions. Apple documents shared buffers as CPU/GPU accessible and requires GPU writes to complete before CPU access. Tree constructors already wait for successful producer completion before returning and mixing the root, so immutable proof-lifetime hash layers can be gathered directly on unified-memory devices without another GPU epoch.

Expected falsifier: if shared hash writes slowed commitments by more than the eliminated readback waits, or if any proof/hash/fallback telemetry changed, reject the design.

## Changes

One mechanism changes three files under `src/backends/metal/runtime/`:

- Generic, quotient, and fused-FRI Merkle hash storage selects `MTLStorageModeShared` when `MTLDevice.hasUnifiedMemory` is true.
- Single and batched selective hash reads detect shared layers and directly copy validated 32-byte records from immutable buffer contents.
- Non-unified devices retain private non-root layers and the exact previous allocation/blit/wait/status-check fallback.

Cryptographic work, roots, ordering, dispatch telemetry, PSOs, source-JIT/AOT identity, and proof encoding are unchanged. A narrower experiment that shared only FRI trees was rejected because 21-sample medians worsened on all classes.

## Results

Seven harness-shaped rounds per class alternated baseline/candidate process order. Each process used 10 warmups and 3 verified samples. Repository Hodges-Lehmann/bootstrap statistics over candidate/baseline ratios reported:

| Metal class | R | 95% CI | speedup |
| --- | ---: | ---: | ---: |
| small | 0.755333 | [0.741314, 0.786567] | 32.4% |
| wide | 0.879952 | [0.860304, 0.907340] | 13.6% |
| deep | 0.735199 | [0.583555, 0.983817] | 36.0% |

The suite geometric-mean ratio is 0.787652: about 21.2% less latency / 1.27x throughput. Deep timings were bimodal; an independent 21-sample A-B-B-A comparison gives a more conservative 18.8% deep reduction. That comparison also measured 32.5% small and 13.0% wide reductions.

The predicted stages moved by roughly 93-96%:

| stage | small before -> after | wide before -> after | deep before -> after |
| --- | ---: | ---: | ---: |
| FRI decommit | 1.764 -> 0.093 ms | 2.509 -> 0.158 ms | 2.470 -> 0.158 ms |
| trace decommit | 0.333 -> 0.014 ms | 0.383 -> 0.026 ms | 0.558 -> 0.034 ms |

All fixed proofs exactly match the untouched CPU/Metal SHA-256 values, every timed sample verifies and is byte-identical, telemetry remains `accelerated_without_fallbacks`, CPU fallbacks remain zero, and high-level Metal dispatches remain 28/36/39. A 70-query secure proof also matches the untouched hash and verifies without fallback.

Official CPU S3 advisory ratios were 1.0021 small, 1.0018 wide, and 0.9871 deep, with every gate passing and every CI spanning neutrality/significance. This is the expected no-regression result for a Metal-only source change, not the optimization claim.

Validation passed `test-native-metal`, `metal-check`, `test-metal-core-aot`, `test-metal-core-aot-probe`, diff checks, commitment/readback parity, fused FRI-tree parity, independent verification, and exact end-to-end proofs. The broad Metal runtime suite reports 78/81 passed and two stress skips; its one resident FRI fold/coordinate failure reproduces identically on the untouched predecessor on this host.

## Caveats

- No `core_metal` manifest workload exists, so the current autoresearch judge cannot score or promote this Metal result. The attached CPU verdicts exist only because `stwo-perf submit` requires a claimed verdict. No locked manifest change or fabricated Metal verdict was used.
- Full Metal System Trace was attempted but `xctrace` is unavailable without full Xcode. Attribution instead uses stage timers, source wait topology, command-epoch counters, pipeline reflection, and `GPUStartTime`/`GPUEndTime` timestamps. Real Metal execution and source-JIT benchmarking do not require Xcode.
- The fast path is feature-gated by unified memory. The private/blit fallback compiles but cannot be executed on this M5 Max.
- AOT shader compilation was not locally possible without the offline Metal toolchain; deterministic AOT tooling/probe contracts pass, and this host-only storage policy does not alter shader artifacts.
- Secure-protocol headline time is dominated by 26-bit proof of work, so the fixed functional suite is the meaningful latency target for this mechanism.

Metal storage contract: https://developer.apple.com/documentation/metal/mtlstoragemode/shared

Command completion contract: https://developer.apple.com/documentation/metal/mtlcommandbuffer/status
