# Vectorize shared quotient denominators across CPU and Metal

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf` at `20e097517010`,
candidate `8a3b16047112`, clean promoted predecessor `0a04f85af1e2`, Zig
0.15.2, ReleaseFast on arm64 macOS. The claimed board is RISC-V `deep/time` at
S3. Adaptive same-host paired measurements used the harness's ABBA policy.
Every timed proof verified, cross-arm proof bytes matched per round, and the
pinned Stark-V oracle accepted all seven workloads. A reasoning-first
sanitized transcript is attached as `transcripts/session-01.md`.

## Hypothesis

Quotient denominators repeat two full CM31 products for every domain row and
sample point even though the sample terms are proof-session constants. They
are then stored row-major and gathered across four rows by SIMD finalization.
Precomputing the constant determinant, evaluating adjacent rows in native M31
vectors, and retaining inverses batch-major should remove arithmetic and
strided loads without changing the quotient identity. The same algebra should
also reduce Metal shader work rather than leaving divergent CPU/GPU formulas.

## Changes

The workspace now precomputes `det = prx*piy - pry*pix` and evaluates each
denominator as `det - x*piy + y*pix`. The CPU tile path groups four adjacent
rows per sample, deinterleaves domain x/y vectors, performs packed base-field
products, stores batch-major CM31 values, batch-inverts them, and finalizes via
contiguous vector loads. Layout state fails closed if a row-major accessor is
used after batch-major preparation. Scalar tails and generic row-major callers
remain supported.

Metal's runtime uploads the same determinant in its existing eight-word ABI.
Direct, raw, and split-finalize quotient shaders use two CM31-by-M31 products
instead of two full CM31 products. The independent resident FRI point ABI is
unchanged. The broader stack also includes packed CM31 inversion, exact dot4
compact quotient reduction, coordinate SIMD, fused FFT normalization and 2x
LDE expansion, and four-chain BLAKE2 scheduling. No workload name, input
digest, benchmark size, statement, protocol, transcript, or proof format is
special-cased.

## Results

The focused SHA2-2048 screen removed 2.82 billion instructions (1.21%) and 653
million cycles (0.95%); proving moved from 2.029 to 1.983 seconds. Canonical
proof bytes were identical.

The final clean seven-workload verdict used 23 paired rounds. Portfolio proving
ratio is **0.982416**, 95% CI **[0.980101, 0.984837]**, clearing theta
0.012888. Every row won: xorshift 0.9830, Fibonacci 0.9814, GCD 0.9855,
multi-shard 0.9920, SHA2-512 0.9734, SHA2-1024 0.9769, and SHA2-2048 0.9849.
Verified-request ratios were also below 1.0 for all rows. Energy ratio is
**0.952201**, peak-RSS ratio **0.998642** with upper-CI geomean 1.001208, and
proof-byte ratio exactly **1.0**. G1-G5 pass.

ReleaseFast closures passed for the 377-source aggregate, 352-source RISC-V
CPU product, 210-source Native CPU product, and 256-source Native Metal
product. Source conformance passed. Metal source-JIT, device-only lifecycle,
independent verification, and zero-fallback policy passed.

## Caveats

This is a local claimed verdict; only the authenticated judge's rerun can
promote it. A first run on the final identity was favorable but narrowly
inconclusive at 0.984744 [0.981673, 0.987511]; it and the successful declared
confirmation are both retained. The harness-wide guard route has a known
manifest classification bug for `guard_blake_10x10`, so explicit Native CPU,
RISC-V CPU, and Native Metal product gates were run and recorded. No separate
Metal timing verdict is claimed from the cross-backend arithmetic change.

The separate PR6 all-cell contract is incomplete: exact full workload parity,
log22 oracle vectors, both timing boundaries, and a locked-M5 judged verdict
remain outstanding. **PR6 Supremacy: not achieved.**
