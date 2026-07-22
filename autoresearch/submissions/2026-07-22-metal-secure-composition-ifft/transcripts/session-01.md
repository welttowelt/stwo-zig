# Metal secure-composition IFFT session

## Objective and promoted frontier

The user asked for architectural Metal work that makes the GPU materially
stronger rather than accumulating tiny shader tweaks. This cycle starts from
clean promoted frontier `40cd456fd998`, which includes PR #71's hardware-page
rotation and all four CPU/Metal xlarge/huge ledger promotions. The repository
CLI was updated before cloning this isolated workspace, and `stwo-perf setup`
is compiling the ReleaseFast CPU, Metal, and RISC-V products.

The previous cycle established the current architecture boundary. Metal huge
main-trace commitment was about 2x faster than CPU, but composition remained a
host callback over GPU-produced unified memory. Page rotation removed a large
address-geometry penalty and moved official Metal huge to 495.138 ms, yet its
post-composition `composition_interpolate_and_split` stage still costs about
28 ms and runs four independent secure-coordinate IFFTs on the CPU.

## Primary prior-art transfer

The repository's algorithm-matching instructions name ClementWalter/stwo#6.
I inspected the primary PR and its `backend/metal/fft.rs`, not a secondary
summary. Its transferable pattern is exact: page-aligned, page-multiple
columns are bound with `newBufferWithBytesNoCopy`; batched inverse FFT passes
are encoded before one command-buffer wait; the final pass applies `1/N` so
the result is bit-identical to scalar interpolation. Its larger AIR-specific
constraint kernel is not directly transferable because this repository's
editable component vtable exposes only an opaque whole-domain callback and the
wide-Fibonacci implementation is locked.

This codebase already owns almost all required machinery:

```text
composition evaluator
  -> SecureColumnByCoords: 4 contiguous mutable M31[N] columns (host)
  -> current secure_poly: duplicate each column + CPU IFFT + duplicate halves
  -> Metal composition commit: eight half-polynomials -> GPU LDE + Merkle

proposed
  -> same 4 contiguous mutable columns
  -> one zero-copy Metal buffer / one batched IFFT command
  -> copy the exact coefficient halves into existing owned polynomial types
  -> unchanged Metal LDE + Merkle commitment
```

## Problem match and Metal design brief

```text
Semantics:
  Convert four bit-reversed secure-field coordinate evaluations on the
  canonical circle domain into scaled natural-order coefficients, then split
  each coefficient vector at N/2 exactly as the existing CPU path does.

Scale:
  xlarge composition domain is expected at log 19; huge at log 21. Four huge
  coordinates are 32 MiB total. The transform is a direct product of four
  independent M31 IFFTs.

Canonical algorithm match:
  batched in-place FFT + zero-copy unified-memory binding. This preserves
  arithmetic order within every butterfly and changes only the execution
  device and pass scheduling.

Memory/lifetime:
  The composition evaluation remains its sole owner. Metal borrows it through
  a no-copy shared MTLBuffer only when base and byte length satisfy the real
  OS page contract; otherwise the existing copied buffer path remains valid.
  The command buffer completes before CPU split copies begin. No borrowed
  MTLBuffer survives the call or the source allocation.

Dispatch/synchronization:
  Add one telemetry-visible Metal circle-transform dispatch at large scale and
  one wait at the true CPU ownership boundary. Reuse existing pipelines and
  source-JIT/AOT manifest; no new command queue or detached work.

Scale gate:
  Select only composition log >=19 so small/wide/deep avoid GPU launch and
  buffer overhead. CPU keeps the exact existing implementation.

Prediction/falsifier:
  Reduce 28 ms huge interpolation/split below 8 ms and improve complete Metal
  huge by at least 3%, with an even larger xlarge percentage. Reject if proof
  bytes differ, dispatch/fallback telemetry is invalid, the stage does not
  move, RSS exceeds its gate, or any guard regresses.

Validation ladder:
  S1 differential Metal/CPU IFFT on live M31 data; ReleaseFast focused tests;
  profiled xlarge/huge complete proofs; exact digest and telemetry checks;
  paired S3 Metal verdicts with all guards and oracle; AOT/source-JIT CI.
```

The first implementation will expose a backend-optional large secure IFFT in
`secure_poly`/`prove`, plus direct no-copy binding in the existing Metal circle
transform. If the GPU transform is visible but runtime passes dominate, the
already-shipped fused 2^11 threadgroup tail can replace the first eleven
legacy global passes without changing the kernel interface.

## Promoted baseline and first ablation

Fresh profiled ReleaseFast proofs on promoted main established:

| class | prove | composition evaluation | secure interpolate/split | composition commit | telemetry |
| --- | ---: | ---: | ---: | ---: | --- |
| Metal xlarge | 139.820 ms | 70.920 ms | 6.139 ms | 9.030 ms | 26 dispatch, 0 fallback |
| Metal huge | 505.108 ms | 283.292 ms | 27.360 ms | 32.552 ms | 28 dispatch, 0 fallback |

The first candidate adds a backend-optional large secure IFFT. At composition
log >=19, Metal transforms the four mutable coordinate columns as one batch,
then the existing coefficient split copies their exact halves. CPU and smaller
Metal shapes retain the old function. Without changing the Objective-C runtime
yet, the result was:

| class | prove | secure interpolate/split | composition commit | telemetry |
| --- | ---: | ---: | ---: | --- |
| Metal xlarge | 137.506 ms | 3.053 ms | 8.438 ms | 27 dispatch, 0 fallback |
| Metal huge | 499.391 ms | 8.814 ms | 29.115 ms | 29 dispatch, 0 fallback |

Proof digests remain the canonical `f845568c...ced8f` and
`e6609d...c7e86`. The stage moved decisively, but the legacy runtime always
allocates a second shared MTLBuffer, copies all four columns in, waits, and
copies them out. At huge that is 64 MiB of avoidable CPU traffic. It also
dispatches every IFFT layer globally although the LDE path already ships a
correct fused 2^11 threadgroup tail. The next ablation adds page-contract
zero-copy binding and reuses that fused inverse tail, with the copied legacy
path retained for non-contiguous/non-page-aligned callers.

## Zero-copy and fused-tail result

The runtime now checks the actual OS page contract, aliases a contiguous
page-aligned/page-multiple column batch with `newBufferWithBytesNoCopy`, and
skips both host copies. Nonconforming callers retain the old allocation/copy
path. Large inverse transforms also dispatch the already-shipped 2^11
threadgroup IFFT tail, then resume the unchanged global layers at layer 11;
twiddle offsets are advanced exactly as if layers 1–10 had run separately.

Three alternated exact-frontier/candidate profiles produced:

| class / stage | predecessor range | candidate range |
| --- | ---: | ---: |
| xlarge complete prove | 139.293–140.487 ms | 131.129–134.120 ms |
| xlarge interpolate/split | 6.107–6.442 ms | 2.108–2.272 ms |
| xlarge composition commit | 8.519–9.209 ms | 6.836–6.873 ms |
| huge complete prove | 505.850–508.004 ms | 477.131–484.136 ms |
| huge interpolate/split | 27.073–27.114 ms | 5.633–5.819 ms |
| huge composition commit | 32.319–32.847 ms | 22.997–26.839 ms |

The objective signature is clean: composition evaluation remains 70–72 ms
xlarge and 282–285 ms huge, while the two transform stages fall. Peak RSS is
flat (about 518 MiB and 1646.5 MiB). Every proof digest is canonical, xlarge /
huge telemetry becomes 27/29 dispatches with zero fallback, and both products
report exact promoted implementation commit `40cd456`.

Two paired screens of the other Metal classes also remained exact and
zero-fallback. Small was 5.20/5.52 ms predecessor versus 5.02/4.97 ms
candidate; wide 12.52/12.40 versus 11.77/9.63 ms; deep 8.42/7.88 versus
8.43/6.84 ms. These shapes do not take the new secure-composition dispatch
(their counts remain 18/22/24); any movement comes from reusing the fused
inverse tail in existing Metal transforms. A longer warmed screen will decide
which broad classes deserve official verdicts rather than claiming noise.

Ten-warmup/ten-sample ABBA processes resolved those apparent movements as
startup variance. The second small predecessor was 2.352 ms versus candidate
2.412–2.904 ms; wide was 7.390/7.426 ms versus 7.471/7.564 ms; deep was
3.969/3.916 ms versus 3.910/3.944 ms. All proofs and telemetry remained exact.
Only xlarge/huge deserve claims. To minimize even scheduling-level guard
surface, the fused inverse tail is therefore gated at log 19 as well; smaller
transforms retain their exact prior pass sequence. Page-contract zero-copy
binding remains generally safe, with the copied path as fallback.

## Editable-boundary correction

The first official huge run measured ratio 0.9308 [0.9223, 0.9392], 507.174
ms predecessor versus 470.182 ms candidate. Proof parity, the oracle, all 13
guards, request time, and resources passed, but G2 correctly rejected the
candidate because the generic call-site edit was in `src/prover/prove.zig`,
outside the manifest's editable surface. That verdict is discarded.

The orchestration file is restored exactly. The same mechanism moves behind
an editable backend hook owned by `secure_poly`: Metal installs its static IFFT
function during runtime initialization/warmup; CPU leaves the hook null. The
hook returns false below log 19 or when no initialized Metal runtime exists,
so reference interpolation remains the fallback. This preserves the existing
prove call and makes runtime ownership explicit without importing Metal into
backend-neutral prover code. Fresh build and proof evidence is required; none
of the rejected verdict will be claimed.

The corrected official huge verdict then passed G1–G5 and all 13 guards at
ratio 0.9274 [0.9171, 0.9382], 491.325 ms predecessor versus 458.046 ms
candidate. Two xlarge objectives were also independently significant at
0.9505 and 0.9495, but each tiny `wf_log10x8` guard had a favorable/near-neutral
median (1.036 and 1.024) with an exceptionally wide upper CI (1.119 and
1.193), so neither verdict is claimed.

That repetition exposed one remaining scale-policy mismatch: the fused IFFT
was log-gated, but the general runtime could still choose a no-copy binding at
small logs. Warmed screens suggested no durable slowdown, yet small buffers do
not amortize MTLBuffer alias setup. The final policy gates zero-copy at log 19
too and stores the minimum log beside the backend hook, so smaller secure
interpolations do not even call the hook. Both previous passing/failing
verdicts are invalidated by this source change and will be regenerated.

## Final verification and verdicts

The scale-gated candidate is clean commit `96fa8908f28e` with only three
editable files. The complete ReleaseFast closure passes across 363 transitive
Zig sources. Clean post-commit profiles retain canonical proofs and show:

| class | prove | interpolate/split | composition commit | telemetry |
| --- | ---: | ---: | ---: | --- |
| Metal xlarge | 127.419 ms | 2.634 ms | 6.607 ms | 27 dispatch, 0 fallback |
| Metal huge | 477.436 ms | 5.725 ms | 26.736 ms | 29 dispatch, 0 fallback |

The first final-source huge suite had a significant 0.9443 objective but two
neutral guard medians of 0.996 whose upper CIs missed the budget by 0.0038 and
0.0053. A clean sequential retry, with no source change, passed all guards.
The final claimed S3 evidence is:

| class | predecessor | candidate | ratio (95% CI) | improvement | rounds |
| --- | ---: | ---: | ---: | ---: | ---: |
| Metal xlarge | 138.211 ms | 131.834 ms | 0.945168 [0.933726, 0.957120] | 5.48% | 9 |
| Metal huge | 502.099 ms | 468.573 ms | 0.938229 [0.929261, 0.942724] | 6.18% | 5 |

Both pass G1–G5, all 13 regression guards, request-time and named resource
budgets, cross-arm digest equality, and the pinned oracle. Request ratios are
0.964295/0.963881, RSS ratios 1.000331/1.000019, and energy ratios
0.942819/0.936785 for xlarge/huge. Proof sizes remain 74,328/86,383 bytes.

The final architecture has one synchronization boundary:

```text
CPU composition callback finishes four contiguous evaluation coordinates
                              │
                  Metal runtime already initialized
                              ▼
  page-aligned 4N buffer ── newBufferWithBytesNoCopy ──┐
                                                       │ one command
          fused IFFT layers 0..10 in 2^11 tiles        │ buffer
          unchanged global IFFT layers 11..L-1         │ + one wait
          scale by 1/N                                 │
                                                       ▼
  CPU resumes after completion, copies exact coefficient halves
                              │
                              ▼
       unchanged Metal coefficient LDE + Merkle composition commit
```

This is a faithful transfer of the zero-copy batched IFFT pattern from the
named upstream prior art. The more ambitious upstream AIR-templated GPU
constraint accumulator is not copied: this repository cannot describe the
locked wide-Fibonacci callback through its editable vtable without an unsafe
workload guess. The next safe architectural target is fusing the transformed
coefficient split with the already-Metal composition LDE/commit epoch.
