# Raw Stwo Wide Fibonacci: Metal vs SIMD

Status: fresh verified evidence, 2026-07-16.

This is the core Stwo `wide_fibonacci` example, not the Cairo recursive Fib program. Each row is
an independent 100-column recurrence with `c = a^2 + b^2`. The size is therefore a power-of-two
trace-row count. Row MHz below means millions of independent trace rows proved per second; it is
not Cairo VM-cycle MHz and cannot be compared numerically with the Cairo Fib table.

## Acceptance contract

- Source harness: `/Users/theodorepender/code/personal/stwo-metal` at commit
  `4c10c4691b538e364a033489ad533ccff375bb40`, plus the local compatibility changes described
  below.
- Workload: upstream Stwo `wide_fibonacci`, 100 columns and 98 recurrence constraints.
- Protocol: Blake2s and `PcsConfig::default()` with 13-bit functional security, three FRI queries,
  and PoW 10. This is backend evidence, not a production-security throughput claim.
- Build features: Stwo and the constraint framework explicitly enable `parallel`; the Metal lane
  also enables `stwo-metal/parallel`. None of those parallel features is an upstream default.
- Process: one explicit warmup followed by three timed proof-and-verify samples per lane and size.
- SIMD: stock Stwo `SimdBackend`; every sample calls stock `stwo::core::verifier::verify`.
- Metal: generated `MetalBackend` lane; every sample calls the same stock verifier.
- Execution: `RAYON_NUM_THREADS=16`, strictly sequential, alternating lane order by log size, with
  ten seconds of cooldown after every process.
- Headline latency: median of all three post-warmup timed samples for both lanes.

The host has Command Line Tools but not the full Xcode offline `metal`/`metallib` executables. The
Metal binary therefore used a bounded source-JIT compatibility path: build-time preprocessing
embeds each Metal translation unit separately, and `MTLDevice.newLibraryWithSource` compiles them
when the process starts. The explicit warmup absorbs library and pipeline compilation. Production
AOT metallib performance may differ, so this lane is labeled `Metal source-JIT`.

## Results

| log2 rows | Trace rows | SIMD prove | Metal source-JIT prove | Metal speedup | SIMD row MHz | Metal row MHz | SIMD prove+verify | Metal prove+verify |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 15 | 32,768 | 56.902 ms | 39.663 ms | 1.435x | 0.5759 | 0.8262 | 57.042 ms | 39.787 ms |
| 16 | 65,536 | 95.811 ms | 49.159 ms | 1.949x | 0.6840 | 1.3331 | 95.958 ms | 49.295 ms |
| 17 | 131,072 | 183.414 ms | 59.899 ms | 3.062x | 0.7146 | 2.1882 | 183.567 ms | 60.041 ms |
| 18 | 262,144 | 333.564 ms | 85.104 ms | 3.919x | 0.7859 | 3.0803 | 333.726 ms | 85.262 ms |
| 19 | 524,288 | 655.217 ms | 144.489 ms | 4.535x | 0.8002 | 3.6286 | 655.392 ms | 144.646 ms |
| 20 | 1,048,576 | 1,463.780 ms | 248.766 ms | 5.884x | 0.7163 | 4.2151 | 1,463.969 ms | 248.942 ms |
| 21 | 2,097,152 | 2,595.985 ms | 472.593 ms | 5.493x | 0.8078 | 4.4375 | 2,596.171 ms | 472.765 ms |

Metal wins every measured size. Its advantage grows sharply when the generated fused composition
path activates at log17, reaching 4.44 row MHz and a 5.49x proof-latency speedup at 2,097,152 rows.
The SIMD input vector is constructed inside its prove timer, while the Metal host input vectors are
constructed once before timed samples. That is a small remaining harness asymmetry and should be
removed before treating sub-millisecond differences as meaningful; it does not explain the large
high-log speedups.

## Evidence

Raw per-lane JSON is under
`vectors/reports/raw_stwo_wide_fibonacci_20260716/{simd,metal}`. Each completed JSON is written only
after every timed proof verifies. `SHA256SUMS` binds all 14 artifacts.

Benchmark executable identities:

- SIMD: `4e92c4032c555ac779295d17aa654e6d6f4baef5b866c7e54ae5a3d352ce1c8d`
- Metal source-JIT: `280322d0c513ca56bcbdbc6f014c18516228c0a749808af096e4e59e78cbe1bf`

The compatibility build restored the repository's deleted Rust CUDA facade and no-CUDA panic
stubs because its current public API still imports them, but it did not restore or enable CUDA
kernels. It also added an isolated SIMD benchmark feature and the multi-library Metal source-JIT
loader. These changes are build plumbing for this otherwise broken historical harness; they are
not part of the new Zig Metal backend.
