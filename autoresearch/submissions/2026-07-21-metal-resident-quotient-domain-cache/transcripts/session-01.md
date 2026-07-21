# Session 01 — quotient-domain conjugate-pair architecture

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and fresh grounding

PR #33 merged the log-aware linear quotient-domain walker and the recorder
advanced canonical main to `483275c35d73`. The repo-resident CLI was updated
to that recorded frontier before a fresh worktree passed setup. ReleaseFast
source-JIT profiles with ten warmups and seven verified samples gave:

| stage median (ms) | wide | deep |
| --- | ---: | ---: |
| prove | 10.898 | 5.570 |
| main trace commit | 1.863 | 0.650 |
| composition evaluation | 3.028 | 0.129 |
| composition commit | 1.628 | 0.761 |
| sampled values | 0.833 | 0.679 |
| FRI quotient/build/commit | 2.475 | 2.167 |
| proof of work | 0.350 | 0.261 |

Every proof retained its fixed hash, source-JIT admission, and zero fallback.
FRI remains the largest shared Metal stage after the previous improvement.

## Sampling attribution

A new five-second macOS stack sample used a log-18-by-32 proof and 31 total
requests. The previous indexed `CirclePointIndex.toPoint` hotspot is gone.
Within `computeQuotientsConfigured`, however, the linear domain iterator still
received roughly 55 main-thread samples versus 23 samples waiting for the
quotient command. The log-18 diagnostic magnifies host coordinate preparation,
but it shows the remaining algorithmic carrier clearly: the full-domain walk
performs one circle addition for all N points.

## Selected architecture: emit conjugate pairs from one half walk

A `CircleDomain` is a half-coset followed by its conjugate. Let N be the full
domain size and let `r = 2*i + parity` be an output row. Bit reversal moves the
least-significant bit of `r` to the half selector:

```text
bitrev_logN(2*i)     = bitrev_(logN-1)(i)             first half
bitrev_logN(2*i + 1) = N/2 + bitrev_(logN-1)(i)       conjugate half
```

Therefore each natural half-coset point `P[j]` can be scattered once to the
adjacent output pair selected by `i = bitrev(j)`:

```text
old full walk                         new half walk

P[0] P[1] ... P[N/2-1]               P[0] P[1] ... P[N/2-1]
  + N/2 additional group steps          |    |          |
conj(P[0]) ... conj(P[N/2-1])          scatter each P and conj(P)
          | bit-reversal |                  | paired bit-reversal |
          N output rows                         N output rows

group additions: N                       group additions: N/2
```

Circle conjugation preserves x and negates y, so the pair write is `(x,y)` and
`(x,-y)` with the existing M31 negation. No independent second iterator,
point reconstruction, multiplication, inversion, shader, dispatch, or upload
layout is needed.

Prediction: halve sampler attribution in coordinate materialization and remove
roughly 0.1--0.3 ms from wide/deep FRI, with exact proof bytes and unchanged
dispatch counts. Falsifiers are any mismatch against indexed lookup for shifted
domains, a changed proof digest, sampler weight that remains in the second half,
or clean paired timing that fails to separate from `483275c`.

## Prototype result and architectural supersession

The conjugate-pair implementation passed the shifted-domain differential test
for every log size from 2 through 15. A second log-18 sample reduced direct
quotient-domain iterator attribution from roughly 55 to 33 samples. Short stage
screens also moved FRI from 2.382 to 2.268 ms on wide and from 2.146 to 2.074 ms
on deep. This validates the algebra and bottleneck, but the expected end-to-end
gain is only around one percent because N/2 group additions, two host arrays,
two Metal buffer allocations, and two uploads remain in every proof.

The stronger production design is a bounded device-resident cache built with
the already authenticated `stwo_zig_quotient_domain_points_resident` pipeline:

```text
                         first warmup                 later proofs

host domain walk         removed                      removed
host x/y arrays          removed                      removed
shared-buffer upload     removed                      removed
Metal domain kernel      N rows, same command         cache hit, no dispatch
                         |                             |
                         v publish after success       v
runtime cache        [ x[0..N] | y[0..N] ]  <----------+
                              |
                              v
                     quotient / finalize kernel
```

The cache key is `(row_count, log_size, initial_index, step_size)`, so shifted
domains cannot alias. The runtime retains exactly one combined buffer and
replaces it when the shape changes. Reads and publication are synchronized;
the buffer is not published until its command has completed successfully.
Concurrent misses may compute equivalent private candidates, while each command
retains the buffer it actually encoded. Large domains use this route and small
domains retain indexed host materialization to avoid perturbing their short
schedule. Shader source, exported function inventory, function constants, and
AOT metallib ABI remain unchanged.

Prediction: after the first untimed warmup, sampler stacks contain no quotient
domain iterator, measured logical dispatch counts stay at 22/24, exact proofs
remain byte-identical, and FRI saves more than the half-walk prototype because
all recurring coordinate preparation and upload work disappears. A cache-key
mistake should be caught by shifted-domain or repeated mixed-shape validation;
incorrect publication ordering should surface under concurrent stress or Metal
API validation.

## Implementation

The production patch spans four editable Metal-runtime files. Zig selects a
resident domain at log 13 and above, passes the full-domain log plus the
half-coset initial and step indices, and omits the host x/y arrays. Smaller
domains retain the predecessor's indexed generation and upload path. The C
bridge accepts nullable coordinate pointers only for the resident mode.

`StwoZigMetalRuntime` owns one strong `MTLBuffer` and its four-field cache key.
On a hit, the quotient command binds x at byte offset zero and y at
`N*sizeof(u32)` in that combined buffer. On a miss it allocates `2*N` words,
encodes the existing resident domain-point pipeline before the quotient grid
in the same command buffer, waits for successful completion, then publishes
the buffer and key under `@synchronized(runtime)`. Cache lookup is synchronized
too, and each proof holds a local strong reference. Thus replacement cannot
invalidate an in-flight hit; concurrent misses may duplicate bounded work but
cannot consume partially generated coordinates. The fixed scored log-15
domain retains only 256 KiB.

The source-JIT shader amalgamation, exported shader function, function-constant
inventory, and authenticated-AOT shader ABI do not change. This is important on
the Command-Line-Tools-only host: embedded MSL is still compiled by macOS via
`newLibraryWithSource`, and initialization remains outside the measured proof
samples. No offline `metal` compiler or full Xcode installation is assumed.

## Mechanism evidence

The first ReleaseFast product and lifecycle tests passed with exact proofs.
A log-18 five-second stack sample then showed the quotient call in its Metal
wait for 20/20 samples in one process segment and 13/14 in another. The one
remaining sample was a small buffer allocation. There was no quotient-domain
iterator under `computeQuotientsConfigured`; the visible coset iterators were
owned by later FRI folding code. This directly falsifies recurring host domain
materialization after warmup.

Clean matched seven-sample stage profiles after ten warmups gave:

| class | predecessor FRI | candidate FRI | reduction | topology |
| --- | ---: | ---: | ---: | ---: |
| wide | 2.430 ms | 2.096 ms | 13.7% | 22 / 22 |
| deep | 2.156 ms | 1.908 ms | 11.5% | 24 / 24 |

Both arms retained the fixed proof hashes and zero fallback. The per-proof
topology counters do not include the one-time warmup cache fill; they confirm
that cache hits add no measured command to the established proof schedule.

An initially alarming deep profile was rejected as a timing screen: its ten
warmups were still falling from 16.9 to 9.5 ms, unrelated stages moved with it,
and an immediate repeat showed the same frequency ramp. Clean interleaved A/B
resolved the ambiguity with seven of seven deep wins. This is why no claim is
based on isolated process order.

## Frozen clean Metal result

The implementation was frozen as `b63898f4a2f7` against exact current frontier
`483275c35d73`. Fifteen process pairs per class alternated A-B/B-A. Every
process used its own clean checkout, the real ReleaseFast Native Metal product,
source-JIT admission, ten excluded verified warmups, and seven timed verified
proofs. The repository Hodges--Lehmann estimator and deterministic 100,000-
resample percentile bootstrap produced:

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small | 2.610 ms | 2.581 ms | 0.98773 [0.97473, 0.99867] | 11/15 |
| wide | 10.015 ms | 9.795 ms | 0.97209 [0.96003, 0.98597] | 13/15 |
| deep | 5.525 ms | 5.246 ms | 0.95065 [0.94519, 0.95609] | 15/15 |

The three-class geometric ratio is 0.97004, or 3.00% lower latency. Wide
improves 2.79% and deep 4.93%, both with confidence intervals entirely below
the one-percent significance boundary. Small is intentionally left on the
predecessor algorithm and is treated as neutral because its interval does not
clear that boundary. Its first A process exhibited the known cold frequency
ramp (5.529 ms versus the later approximately 2.6 ms cluster); the robust
estimate is reported without deleting that unfavorable raw pair.

All 90 clean reports and 630 measured proofs independently verified. Cross-arm
hashes were fixed at `91741aec...bea5700` small,
`57a7d291...30f3374` wide, and `d63a2c92...b69dbaf` deep. Every report had
complete clean provenance, byte-identical samples, source-JIT admission, zero
CPU fallback, zero post-warmup direct compilation, and unchanged 18/22/24
topology counters.

## Validation and submission controls

The official CPU S3 deep control at the exact candidate is confirmed neutral
at 1.0054 `[0.9978, 1.0123]`. It passes G1--G5, selected regression guards,
cross-arm proof identity, and the pinned Rust oracle. This is the manifest's
required CPU-board control, not evidence for the Metal speedup.

ReleaseFast aggregate tests, Native Metal product/lifecycle tests,
`metal-check`, source conformance, formatting, and both authenticated-AOT
tooling/probe suites pass. Source conformance reports the same five explained
legacy findings and no new violations. The broad Metal runtime suite remains
80/83: its one resident FRI policy assertion and two stress skips are the exact
known frontier baseline; the changed cache path passes end-to-end coverage.

Finally, both Metal API Validation and Metal GPU Validation explicitly enabled
on the frozen commit. A cold-cache Plonk proof exercised domain generation,
quotient consumption, publication-after-success, and commitment with zero
fallback and the fixed 45,200-byte digest; a separate focused-product command
independently verified the artifact. This also validates the cache-miss path,
which timed post-warmup comparisons intentionally exclude.

The enabled autoresearch manifest still has no `core_metal` judge board, so the
official verdict is honestly a CPU no-regression control. The significant
Metal claim is bound to the production source-JIT paired experiment above.
