# One resident Metal epoch for the complete line-FRI cascade

## Model and harness

GPT-5 Codex optimized the updated `fd9bd94395ce` frontier on an Apple M5 Max
running macOS 26.5.2. The production benchmark was the ReleaseFast
`native-proof-bench-metal` binary using the real `--metal-runtime source-jit`
path: Zig embeds the MSL, macOS compiles it through
`newLibraryWithSource:options:error:`, initialization is excluded from timed
samples, and no full Xcode installation or offline `metal` executable is
required.

The manifest still enables only the `core_cpu` acceptance board. The attached
official S3 verdicts are therefore honest CPU no-regression evidence; the Metal
claim comes from the production-compatible Native Metal binary and is not
mislabelled as a scored CPU result.

## Hypothesis

After the preceding UMA Merkle-readback work, wide FRI decommitment was only
0.14–0.16 ms, but FRI quotient/fold/commit remained 6.2–6.6 ms. Metal GPU
timestamps attributed only about 0.7 ms to the repeated line folds and Merkle
trees. The residual was host orchestration around a serial Fiat–Shamir graph:

```text
E_i -> coordinates -> Merkle -> root_i -> Blake2s(channel || root_i)
                                                     |
                                                     v
domain_i + E_i -------------------------------> alpha_i -> fold -> E_(i+1)
```

The challenge makes device work sequential, but it does not require a host
round trip. The predecessor submitted and synchronously waited once per inner
FRI layer: 8 epochs on small and 12 on wide/deep. The falsifiable prediction
was that encoding this immutable dependency graph on one device timeline would
remove those waits without changing any root, channel state, proof byte, or
logical commitment count.

Alternatives were rejected before implementation: CPU/shared-root polling and
callbacks merely move the synchronization; multiple command buffers cannot be
fully encoded before the dependent alpha exists; a larger fold step changes
the proof protocol; and returning small layers to CPU violates the no-fallback
contract.

## Changes

The generic FRI scheduler now has an optional Metal cascade hook, compile-time
gated to the exact plain Blake2s channel and runtime-gated to resident,
power-of-two, fold-step-one shapes. Unsupported shapes return to the existing
path before channel mutation.

The Metal runtime preallocates every proof-owned coordinate column and Merkle
tree plus private geometric intermediate evaluations. It concatenates domain
inverses once, then records the complete cascade in one command buffer and one
compute encoder. Explicit buffer-scope barriers preserve every producer/
consumer edge.

A tiny shared transcript arena holds the ten-word channel state, eight-word
root slots, and four-word alpha slots. Each Merkle tree aliases its root layer
to its stage's arena slot, so the last parent dispatch writes exactly where the
existing authenticated transcript-mix kernel reads. The existing secure-draw
kernel writes the next fold alpha into the same arena. This removes root blits
and host feedback while adding no shader export, no shader-ABI revision, and no
AOT/source-JIT divergence. Offset-aware tree metadata preserves later root
access and decommitment.

For wide FRI, 169 ordered kernel dispatches now execute as one compute encoder,
one command buffer, one wait, and zero blits. The unchanged prover receives the
same logical columns, tree handles, terminal evaluation, digest, and draw count
only after successful completion. Runtime or transcript failure aborts; it
never silently falls back.

## Results

Every fixed shape was measured in a fresh A-B-B-A process order. Each process
used 10 warmups and 7 timed verified samples under the functional protocol.
The table pools 14 samples per arm; intervals are deterministic 100,000-sample
bootstrap CIs for the median ratio.

| class | predecessor | candidate | B/A (95% CI) | latency reduction |
| --- | ---: | ---: | ---: | ---: |
| small | 4.927 ms | 3.051 ms | 0.619 [0.556, 0.681] | 38.08% |
| wide | 14.718 ms | 12.700 ms | 0.863 [0.849, 0.885] | 13.71% |
| deep | 10.910 ms | 8.796 ms | 0.806 [0.800, 0.813] | 19.38% |

The suite geometric-mean ratio is about 0.755: 24.5% less latency / 1.32x
throughput. Both counterbalanced process pairs win independently. A final
profiled wide run measures the targeted FRI stage at 4.17–4.24 ms versus the
predecessor's 6.2–6.6 ms.

Mechanism telemetry moves exactly as predicted:

| class | FRI epochs before -> after | high-level Metal dispatches | resident commits |
| --- | ---: | ---: | ---: |
| small | 8 -> 1 | 28 -> 19 | 12 -> 12 |
| wide | 12 -> 1 | 36 -> 23 | 16 -> 16 |
| deep | 12 -> 1 | 39 -> 26 | 17 -> 17 |

Across all 84 timed A/B proofs, every sample independently verified, all
samples were byte-identical within their run, every hash matched the untouched
frontier, classification stayed `accelerated_without_fallbacks`, and CPU
fallbacks stayed zero. Fixed hashes are:

- small: `91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700`
- wide: `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`
- deep: `d63a2c92846148edc075fbb46fe63f5cf0fc6fe05ae1d5d54d09bda33b69dbaf`

## Official harness and validation

The required CPU S3 advisory verdicts were rerun after the final frontier sync.
They pass every gate, every pinned-Rust-oracle check, and all 12 impact-mapped
AIR guards, while spanning neutrality as expected for a compile-time
Metal-only hook: small 0.9970 `[0.9847, 1.0116]`, wide 0.9998
`[0.9799, 1.0083]`, and deep 1.0027 `[0.9934, 1.0126]`.

Validation passes `zig build test`, `test-native-metal` (device-only prove plus
independent verify), `metal-check`, `test-metal-core-aot`,
`test-metal-core-aot-probe`, formatting/diff checks, source conformance, and the
fixed end-to-end proof matrix. The generic FRI owner remains below the manual
source ceiling at 849 lines. A new five-layer cascade test compares every
CPU/GPU Merkle root, final value, digest, draw count, and transcript error state.
The broad Metal runtime suite reaches 79/82 with two expected skips and the same
single resident-FRI test failure documented on the untouched predecessor.

## Caveats

- There is no enabled `core_metal` judge workload, so this Metal result cannot
  yet receive official leaderboard credit. No locked manifest change or
  fabricated Metal verdict was used.
- The host lacks full Xcode, so Metal System Trace and local AOT compilation are
  unavailable. Real source-JIT execution, GPU timestamps, stage profiles,
  command-epoch telemetry, and both AOT contract probes provide the evidence.
- The optimization intentionally applies only to plain Blake2s, resident
  storage, and `fold_step == 1`; every other configuration keeps the reference
  implementation.

Apple's command-buffer guidance recommends submitting the fewest command
buffers needed and avoiding unnecessary CPU/GPU synchronization:
https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html
