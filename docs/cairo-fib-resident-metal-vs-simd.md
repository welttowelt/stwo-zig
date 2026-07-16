# Cairo Fib: Resident Metal vs SIMD

Status: corrected bounded evidence, 2026-07-16.

The earlier fresh-process Cairo table charged runtime Metal initialization to every proof and did
not measure resident backend throughput. This report separates the first cold proof from two warm
proofs in the same process. It is the current Cairo Fib evidence for 25k through 2M.

## Acceptance contract

- Workload: the same compiled Cairo recursive Fibonacci program and requested Fib N.
- Cairo cycles: `7 * N + 16`.
- Protocol: Blake2s, 96-bit configuration, 70 queries, query PoW 26, FRI fold step 3.
- Build features: Stwo `parallel` and `prover`; Metal backend `parallel`. Upstream Stwo does not
  enable `parallel` by default; these features are explicit in the Cairo GPU prover dependency
  graph. The benchmark pins the active Rayon pool to 16 threads on an 18-CPU host.
- Process: one cold proof followed by two warm proofs over `--reuse-input`; the warm result is
  their median.
- Every proof is accepted by canonical Rust `verify_cairo`.
- Repeated proofs within each process must be byte-identical.
- SIMD and Metal Fib25k proof files were compared directly and are byte-identical.
- Runs were strictly sequential with `RAYON_NUM_THREADS=16`.

A direct runtime control against the same current Stwo checkout reported
`rayon::current_num_threads() == 16` with the benchmark environment and 18 with
`RAYON_NUM_THREADS` unset. The `nproc=18` field emitted by `gpu_bench` is host CPU availability,
not evidence that the measured prover used an 18-thread Rayon pool.

Artifacts:

- 25k--50k: `vectors/reports/cairo_fib_metal_vs_simd_resident_report.json`
  (SHA-256 `e73295a8ea3df6a219ce0d9b20edcf4b62824f090a0b49bb41f84538a1a22b75`).
- 100k--250k: `vectors/reports/cairo_fib_metal_vs_simd_resident_100k_250k_report.json`
  (SHA-256 `ab1e62186b9fa6de56fb70532b4255851fd408cec72d5a036eb50f9a5f56186d`).
- 500k--2M: `vectors/reports/cairo_fib_metal_vs_simd_resident_500k_2m_report.json`
  (SHA-256 `b24a68717a9b976c83ba66c4385874ae836e7ded3d43bc7d4bfe87d1328fe189`).

Cross-backend proof evidence:
`vectors/reports/cairo_fib25k_cross_backend_proof_parity.json`.

## Corrected results

| Fib N | Backend | Cold prove | Cold MHz | Warm prove | Warm MHz | Three-proof process wall |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 25,000 | Rust SIMD | 1.397 s | 0.125 | 0.7355 s | 0.2380 | 2.959 s |
| 25,000 | Apple Metal | 1.810 s | 0.097 | 0.7565 s | 0.2313 | 3.444 s |
| 50,000 | Rust SIMD | 1.541 s | 0.227 | 0.869 s | 0.4028 | 3.414 s |
| 50,000 | Apple Metal | 1.898 s | 0.184 | 0.864 s | 0.4051 | 3.790 s |
| 100,000 | Rust SIMD | 1.591 s | 0.4400 | 0.9270 s | 0.7551 | 3.577 s |
| 100,000 | Apple Metal | 5.173 s | 0.1353 | 0.8490 s | 0.8245 | 7.070 s |
| 250,000 | Rust SIMD | 2.084 s | 0.8397 | 1.3905 s | 1.2586 | 5.192 s |
| 250,000 | Apple Metal | 3.166 s | 0.5528 | 1.2450 s | 1.4056 | 5.964 s |
| 500,000 | Rust SIMD | 2.661 s | 1.3153 | 1.9680 s | 1.7785 | 7.034 s |
| 500,000 | Apple Metal | 7.485 s | 0.4676 | 1.5735 s | 2.2244 | 11.108 s |
| 1,000,000 | Rust SIMD | 4.317 s | 1.6215 | 3.5805 s | 1.9550 | 12.423 s |
| 1,000,000 | Apple Metal | 6.326 s | 1.1065 | 2.7525 s | 2.5431 | 12.728 s |
| 2,000,000 | Rust SIMD | 7.217 s | 1.9399 | 6.7240 s | 2.0821 | 22.515 s |
| 2,000,000 | Apple Metal | 8.546 s | 1.6382 | 5.0080 s | 2.7955 | 20.216 s |

The current warm Metal lane is 2.9% slower at Fib25k and crosses SIMD at Fib50k. With the explicit
16-thread policy, its proof-latency advantage grows from 9.2% at Fib100k to 34.3% at Fib2M. Warm
throughput reaches 2.7955 MHz at Fib2M versus 2.0821 MHz for SIMD. This is the expected scaling
direction once fixed orchestration cost is amortized, although the hybrid path still leaves much
of the available GPU throughput unused.

Cold Metal remains volatile: the first proof ranges from 1.810 seconds at Fib25k to 8.546 seconds
at Fib2M and contains runtime/JIT, preprocessed-state, and cache construction. Metal therefore
loses the three-proof process wall through Fib1M even when its warm proofs are faster. At Fib2M it
finally wins that full wall measurement as well, 20.216 seconds versus 22.515 seconds. A production
backend must still prepare immutable state once, retain it by authenticated geometry key, and
report cold setup separately from warm proof latency and sustained queue throughput.

The three-proof wall includes process launch, one VM/adaptation pass, input cloning, proof
serialization, three verifications, and process exit. It is not a single-proof latency. Warm prove
time excludes VM execution and adaptation because the benchmark intentionally reuses the adapted
input to measure a resident proving service.

## Proof parity

The final Fib25k proof artifacts from the SIMD and Metal lanes are both 1,147,947 bytes and compare
equal byte for byte:

`084616bf75ae1d6d248bc55a1f249a11dbfb10f0701213afc7a78c7758096a4d`

This is stronger backend-parity evidence than merely observing that each proof verifies. It does
not by itself complete the Zig Cairo frontend or compact-proof independent-verifier work.

## What removed the warm deficit

A same-process Fib25k phase trace before the upload fix showed the warm 188 ms deficit directly:

| Warm phase | SIMD | Metal private upload | Delta |
| :--- | ---: | ---: | ---: |
| Composition | 123 ms | 81 ms | -42 ms |
| Base trace write | 20 ms | 72 ms | +52 ms |
| Interaction trace write | 76 ms | 147 ms | +71 ms |
| FRI commit | 12 ms | 61 ms | +49 ms |
| OODS evaluation | 184 ms | 206 ms | +22 ms |

Metal composition was already faster. The end-to-end lane lost that gain because the prover was a
hybrid pipeline: fallback witness columns were generated on SIMD, copied to a shared staging
buffer, blitted to a private Metal buffer, and synchronously waited per column. Interaction LogUp
was also finalized on SIMD and uploaded through the same path.

Apple Silicon now defaults those witness transfers to shared unified-memory buffers. The bounded
A/B reduced warm Metal Fib25k from 0.930-0.936 s to 0.810-0.814 s. Base trace write fell from 72 ms
to 26 ms and interaction trace write from 147 ms to 74 ms, while proof bytes remained identical.
Other platforms retain private storage unless explicitly overridden by
`STWO_METAL_WITNESS_UPLOAD_MODE=shared`.

The next loss was FRI packed-leaf construction. The old path read four coordinate buffers back to
the host, performed an O(N) CPU transpose, uploaded 16 columns, and introduced queue fences. A
fixed four-input/16-output Metal gather now keeps this transformation on the GPU and is the Apple
Silicon default; `STWO_METAL_FRI_PACK_LEAVES_MODE=host|gpu` remains available for strict A/B.
Shared and private input buffers match the host oracle exactly at lengths 4, 64, and 1024. In the
Fib25k trace, warm FRI commit fell from 66.956 ms to 18.932 ms and warm proof time from about
0.813 s to 0.775 s. The final untraced three-proof report records 0.7565 s. Fib50k FRI commit was
19.180 ms in the gated trace and the final warm Metal proof is 0.864 s, matching SIMD.

The rebuilt default Metal proof remains exactly 1,147,947 bytes with the same recorded Fib25k
SHA-256 above, so the optimization did not change the transcript or protocol result.

## Why cold and short-batch totals lag at smaller sizes

Metal still pays first-use preprocessed commitment, pipeline/runtime creation, and device-state
construction inside the first proof. The current three-proof proving totals are 3.323 s Metal vs
2.868 s SIMD at Fib25k and 3.626 s Metal vs 3.279 s SIMD at Fib50k. The corresponding launch-to-exit
walls are 3.444 vs 2.959 s and 3.790 vs 3.414 s. A production resident service must retain those
immutable objects across blocks; repeatedly launching a fresh process is the wrong lifecycle and
will make Metal look worse at small sizes even when warm proof latency is equal. Scaling eventually
amortizes that cost: the three-proof Fib2M process wall is 20.216 s Metal vs 22.515 s SIMD.

One post-link sample was rejected after CPU PoW grind and OODS time inflated sharply while proof
bytes remained unchanged. A cooldown rerun restored Fib50k to 0.860 s Metal vs 0.859 s SIMD. This
is also why the accepted report uses two warm repetitions per resident process rather than one.

## Next architecture work

1. Extend the GPU packed-leaf gather into a fully resident FRI fold/decompose/commit command chain.
   The first CPU transpose/readback is gone, but command submission and remaining queue drains are
   not yet fused into one dependency graph.
2. Keep OODS point evaluation and its factors resident. Metal remains about 18-22 ms behind SIMD at
   Fib25k despite the grouped barycentric improvement.
3. Replace per-component trace bridges with resident column offsets and an argument table. Shared
   memory removes the worst waits, but it still copies CPU-generated columns and does not make the
   witness pipeline device-native.
4. Move remaining LogUp finalization and high-value Cairo witness components to Metal, preserving
   per-component cumulative comparison against the Rust SIMD oracle.
5. Batch the proof command graph. The Metal runtime still contains many synchronous
   `waitUntilCompleted` boundaries, preventing overlap across commitments, composition, and FRI.
6. Measure cold startup, warm latency, and sustained multi-proof throughput separately at each Fib
   geometry. Do not publish a fresh-process proof as resident Metal throughput.

## Correctness boundary

The current RISC-V Fib path is not a correctness oracle for this work. Its registered components
contain no trace-dependent RISC-V AIR constraints, so its acceptance is diagnostic PCS/FRI evidence
only. It must not be ranked against Cairo as a sound VM proof.

The independent Rust Cairo adapter now deserializes complete JSON Cairo proofs at exact pinned
Stwo/Stwo-Cairo revisions and calls canonical `verify_cairo`. It has accepted a real SN PIE 2
reference proof and a real `gpu_bench` Fib25k proof. A strict compact v1 decoder now validates typed
public data, all 83 enable slots, active-log and memory-big geometry, the preprocessed variant, four
trace commitments, eight FRI commitments, 12 decommitments, and the observed single final QM31
coefficient. Its 30 tests and release build pass. Compact Zig/Metal proof reconstruction remains
explicitly unsupported until those validated fields are converted into the canonical Rust proof
object and accepted by `verify_cairo`.
