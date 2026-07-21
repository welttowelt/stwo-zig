# Session 01 — device-resident FRI inverse domains

Date: 2026-07-21
Model: GPT-5 Codex

## Recorded frontier and fresh grounding

PR #34 removed recurring quotient-domain construction with a bounded resident
Metal buffer, and the autoresearch recorder advanced the exact frontier to
`c14ef9789118`. A fresh worktree passed setup and rebuilt the real ReleaseFast
Native Metal product in source-JIT mode. The previous frozen paired result was
3.00% lower end-to-end geometric mean, with the fixed proof hashes, no fallback,
and a neutral scalar control.

Fresh strict runtime-event profiles of the current frontier show that the line
FRI cascade is now the largest shared Metal command. Encoder counters attribute
37.9% of wide GPU time and 37.5% of deep GPU time to that command; polynomial
evaluation follows at roughly 26%. Without encoder counters, line-cascade
medians are approximately 0.865 ms wide and 0.518 ms deep. The cascade has one
command buffer and wait but still contains 32 physical grids at production
sizes: one initial coordinate/leaf grid, eighteen bottom/tail Merkle grids, and
thirteen fold/coordinate/leaf grids.

A separate log-18 macOS stack sample localizes a different recurring cost on
the host. After the quotient-domain cache removed its iterator, FRI inverse
preparation still accounts for about 60 `CosetPointIterator.next` samples and
11 `batchInverseInPlace` samples, compared with roughly 50 samples waiting for
the line cascade. The circle-to-line fold builds inverse y coordinates; the
line cascade builds concatenated inverse x coordinates for every layer. Both
domains and all values are invariant across proofs of a fixed shape.

## Residual dependency graph

```text
every proof today

circle half-coset walk -> bit-reversed y[] -> batch inverse -> host buffer upload
                                                               |
resident FRI column --------------------------------------------+-> circle fold
                                                                    |
                                                                    v
line coset walk #0 -> bit-reversed x[] -> batch inverse -----------+
line coset walk #1 -> bit-reversed x[] -> batch inverse -----------+-> concatenate
...                                                                |      |
line coset walk #L -> bit-reversed x[] -> batch inverse -----------+      v
                                                               host buffer upload
                                                                      |
resident line evaluation --------------------------------------------+-> 32-grid cascade

selected steady state

fixed circle-domain key ---> [resident inverse-y buffer] ------------> circle fold
fixed line-domain key -----> [resident concatenated inverse-x buffer] -> cascade
                                  ^
                                  |
                         one warmup-only JIT Metal fill
```

The prior researchers already tested the tempting dispatch-reduction branch:
folding Merkle microtrees into the FRI producer reduced topology from 68 grids
to 46, but increased device time from about 2.9 ms to 3.36 ms because the
register-heavy producer lost occupancy. That measured rejection rules out
repeating producer fusion here. Later isolated parent tails and transcript-tail
fusion preserved occupancy and established the current 32-grid schedule.

## Selected architecture

Extend the already authenticated
`stwo_zig_quotient_domain_points_resident` pipeline with a mode binding:

- mode 0 retains its exact full-circle x/y quotient-domain ABI;
- mode 1 emits bit-reversed inverse x values for one coset;
- mode 2 emits bit-reversed inverse y values for one coset.

For inverse modes, output row `r` maps to
`natural = bit_reverse_logN(r)`. The point exponent is
`initial_index + step_size * natural (mod 2^31)`, after which the shader writes
`m31_inv(point.x)` or `m31_inv(point.y)`. This is the GPU equivalent of the
current linear host walk, bit-reversed scatter, and batch inverse. Differential
tests over shifted cosets must prove that equivalence; fixed proof bytes are the
end-to-end oracle.

The Objective-C runtime owns two independent one-entry caches so the circle
and line phases cannot evict each other:

```text
circle key = (destination_count, initial_index, step_size)
circle value = inverse_y[destination_count]

line key = (source_count, layer_count, initial_index, step_size)
line value = inverse_x[N/2] || inverse_x[N/4] || ... || inverse_x[last+1]
```

On a miss, a private candidate buffer is filled by one inverse-domain dispatch
for the circle or one per line layer. The existing fold command consumes that
same candidate, waits, checks command success, and only then publishes it under
`@synchronized(runtime)`. On a hit there is no fill grid, host domain walk,
batch inversion, scratch vector, buffer allocation, or upload. A local strong
reference protects an in-flight hit from replacement. Concurrent misses may
compute equivalent private candidates but can never observe partial contents.

Large production domains use the cache; small domains retain the established
host route because their schedule is too short to amortize cache machinery.
Generic FRI code initializes inverse workspaces lazily only for a backend that
declares this capability, while Metal fallback paths continue to call
`ensureCapacity`. The cache is bounded to about 128 KiB for the fixed scored
shape and replaces on a shape change.

The embedded MSL remains compiled through macOS
`newLibraryWithSource:options:error:`. Adding one binding to an existing export
requires a core shader ABI bump and authenticated-AOT manifest validation, but
does not require Xcode's offline `metal` tool. Source compilation remains in
runtime initialization and outside the ten post-warmup samples.

## Prediction and falsifiers

Prediction: cache-hit samples remove the FRI coset iterators and batch inverse
from host stacks; measured proof topology remains 22/24 because fills occur in
excluded warmup; FRI and end-to-end medians improve on wide and deep while the
small class and scalar control remain neutral. The expected fixed-shape gain is
roughly 0.15--0.40 ms, potentially larger when allocator and upload work are
included.

Falsifiers are any shifted-coset differential mismatch, proof digest change,
Metal validation error, cache-key collision across mixed shapes, publication
before command success, measured cache-fill grids after warmup, residual host
inverse stacks, material small-shape regression, or paired confidence intervals
that fail to separate from the exact predecessor. Any such result triggers a
fix or complete revert rather than a submission.

## Implementation and direct parity

The production patch widens the existing domain-point pipeline rather than
adding an export. Core shader ABI 4 advances to 5, and every existing quotient
caller binds mode 0 explicitly. Modes 1 and 2 use the same circle exponent,
safe M31 multiplication, inversion, and bit reversal compiled by the macOS
runtime. The authenticated-AOT manifest and probe therefore reject ABI-4
bundles before use while preserving the exact Native export inventory.

`StwoZigMetalRuntime` owns separate strong circle and line cache buffers and
their complete keys. Both caches use private storage. A circle miss encodes one
inverse-y grid in the fold command before its ordinary fold encoder. A line
miss encodes one inverse-x grid per doubled domain at disjoint offsets in the
existing cascade encoder, then inserts a buffer memory barrier before the
32-grid proof dependency chain. Publication happens only after command success
and transcript validation. Hits bind the retained buffer directly.

The generic FRI prover observes one Metal-only compile-time capability and
starts inverse workspaces at capacity zero. Metal's small and standalone paths
still call `ensureCapacity`; large cached paths never allocate those four host
scratch arrays. CPU backends retain their prior capacities and generated code.

A new device differential uses two shifted, non-canonical cosets. For each it
compares a host batch-inverted y domain with shader generation on both a cache
miss and subsequent hit, then compares every output word of the real circle
fold. The test passes. Complete wide and Plonk proofs independently retain
their fixed hashes, providing line inverse-x and end-to-end arithmetic parity.

## Mechanism evidence

A strict encoder-counter capture covered ten warmups and three measured wide
proofs: 104 command buffers, 470 encoders, zero errors, zero untimed encoders,
zero counter overflows, and only 0.322 ms unattributed GPU time. Exactly one
line-cascade encoder contained 45 dispatches—the established 32 plus thirteen
inverse-domain fills. The other twelve line cascades contained exactly 32
dispatches. The one circle inverse fill and one quotient-domain fill likewise
occurred in the first untimed warmup. Thus all measured cache hits preserve the
22/24 high-level proof topology and add no physical work.

The same report still places the line cascade first at 36.6% of GPU command
time and polynomial evaluation second at 26.2%, so the optimization did not
hide a device regression behind host savings. A fresh three-second log-18 stack
sample contains no `CosetPointIterator` or `batchInverseInPlace` under either
FRI path. Circle and line calls are overwhelmingly in `waitUntilCompleted`, as
predicted.

Matched stage screens tie the movement to FRI:

| class | predecessor FRI | candidate FRI | reduction |
| --- | ---: | ---: | ---: |
| wide | 2.096 ms | 1.858 ms | 11.4% |
| deep | 1.908 ms | 1.617 ms | 15.3% |

## Frozen exact-final result

During the required final sync, frontier commit `ef33f70` enabled the real
`core_metal` board. The production tree had not changed, and the source patch
rebased without conflict. Source was therefore re-frozen as `7a28519b5968`
against exact current frontier `91d18f7bdd44`, then rebuilt and measured again.
Fifteen clean process pairs per class alternated A-B/B-A order. Every process
used its own detached clean checkout, the ReleaseFast Native Metal product,
source-JIT admission, ten excluded verified warmups, and seven timed verified
proofs. Repository Hodges--Lehmann statistics with a deterministic 100,000-
resample percentile bootstrap give:

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small | 2.608750 ms | 2.572584 ms | 0.98593 [0.96763, 1.00156] | 10/15 |
| wide | 9.798583 ms | 9.465792 ms | 0.97348 [0.96103, 0.98404] | 14/15 |
| deep | 5.301875 ms | 5.006417 ms | 0.94698 [0.94064, 0.95376] | 15/15 |

The suite geometric ratio is `0.96866`: 3.13% less end-to-end proof latency.
Small is neutral and is not overclaimed. All 630 timed proofs independently
verified, were byte-identical within process and across arms, used zero CPU
fallback, and retained the three fixed proof digests.

The newly enabled official Metal S3 harness independently confirms both moved
classes with fifteen paired rounds each: wide `0.960611 [0.951332, 0.970111]`
and deep `0.9437 [0.9319, 0.9534]`. Both clear the 1% promotion threshold and
pass G1--G5, the pinned Rust oracle, request/RSS budgets, and all twelve
impact-mapped guards. A source-identical pre-rebase CPU control was also neutral
at `1.0033 [0.9914, 1.0146]`.

ReleaseFast aggregate tests, Native Metal product/lifecycle tests, Metal
compile/link, formatting, source conformance, and deterministic core-AOT tool
and probe tests pass on the rebased candidate.
