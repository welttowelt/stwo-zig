# Fuse wide Metal trace, transforms, and coefficient commitment

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf` 0.1.0, Zig 0.15.2,
ReleaseFast on the same arm64 macOS M5 Max host. The claimed board is Native
Metal `xlarge/time` and `huge/time` at S3. The behavior-neutral producer API
foundation merged in PR #88 at `7c9e2e227ffe`; scored candidate
`05e9193d4067` is restricted to `src/backends/metal/**`. The harness identity
is `f05c84e1750f`. Same-host paired measurements used the harness's ABBA
policy. Every timed proof verified, cross-arm proof bytes matched, and the
pinned Rust Stwo oracle accepted both scored workloads.

## Hypothesis

Wide Fibonacci was paying several boundaries that should not exist on a GPU:
the host materialized a quadratic recurrence, Metal copied it, inverse FFT
normalization traversed it again, composition evaluation and interpolation
used separate command buffers, and coefficient-form composition was copied
back through the generic LDE path. A structural producer carried through the
proof transaction lets one Metal epoch generate, interpolate, extend, and
commit columns while device data is resident. The same mechanism generalizes
to any structurally described column producer and coefficient-form PCS input;
it does not match workload names, sizes, or input digests.

## Changes

`ColumnSource` makes producer ownership explicit instead of discovering
runtime state by host address. The wide trace advertises its recurrence recipe
only when the backend structurally admits the shape. Metal then generates the
recurrence directly into the commitment arena, performs a tile-12 specialized
wide inverse transform with fused normalization, expands with pre-scaling,
performs the forward transform, and builds the resident Merkle tree in one
command-buffer epoch.

Secure composition now carries an explicit evaluations/coefficients state.
The large recurrence shader consumes cached trace residency, evaluates the
composition, performs its inverse transform in the same command, and returns
borrowed coefficient halves. A coefficient-form PCS hook uses GPU blits to
reorder the eight split coordinate polynomials, evaluates their LDE, and
commits the tree without a host round trip. Power-of-two Mersenne rotations
replace general multiplication where the FFT schedule permits it. The core
shader ABI is bumped fail-closed from 8 to 9 and anchors all 82 exports.

PR #89's first static run found three files just over the repository's
850-line ceiling. The final candidate extracts column-source materialization,
the recurrence-composition entry point, and wide transform kernels into
focused units. Direct diffs against the pre-extraction source confirm that
the Objective-C function and both MSL kernels are byte-for-byte unchanged;
dispatch order, buffer ownership, and shader ABI are unchanged.

## Results

Both claimed verdicts pass G1-G5 and all 13 impact-mapped regression guards.

| Class | Prove ratio (95% CI) | A / B median | Request ratio | Energy ratio | RSS ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `xlarge` / `2^18 × 100` | **0.9441 [0.9179, 0.9583]** | 31.467 / 29.379 ms | 0.8481 | 0.8423 | 1.0056 |
| `huge` / `2^20 × 100` | **0.9297 [0.9183, 0.9415]** | 119.684 / 110.789 ms | 0.8241 | 0.8439 | 1.0188 |

Xlarge used nine paired rounds and huge used five. Proof-byte ratios are exactly 1.0: 74,328
bytes at xlarge and 86,383 bytes at huge. Resource upper confidence bounds
remain inside policy. The verified-request boundary improves about 15% at
log18 and about 17.6% at log20 because it includes the eliminated host trace construction that
the prove-time ledger objective excludes.

Two earlier final-identity xlarge screens were retained as uncertainty
evidence: both had significant objective CIs, but the high-dispersion
`wf_10x8` guard's upper CI was above 1.05. The third identical screen passed
all 13 guards, with that guard at 0.9291 [0.9139, 0.9499]. No sample or failed
receipt was discarded from the external evidence bundle.

The same candidate produced two significant wide objectives, 0.9358
[0.9151, 0.9438] and confirmation 0.9351 [0.9161, 0.9423], but both are
retained as unclaimed diagnostics because the sub-millisecond `wf_10×8`
guard's upper CI remained inconclusive (1.149 and 1.058 versus budget 1.05).
Deep was favorable at 0.9777 [0.9644, 0.9871] but below its declared
significance threshold. Neither verdict is packaged as passing.

## Wider diagnostic results

Canonical proofs and zero-fallback classification were unchanged at every
size. Against current-main diagnostic medians:

| Shape | Main request | Candidate request | Improvement |
| --- | ---: | ---: | ---: |
| `2^16 × 100` | 22.826 ms | 22.859 ms | neutral (-0.14%) |
| `2^18 × 100` | 38.080 ms | 29.328 ms | 22.98% |
| `2^20 × 100` | 133.633 ms | 109.656 ms | 17.94% |
| `2^22 × 100` | 531.578 ms | 431.382 ms | 18.85% |

An independently rebuilt scorer split measured 112.133 ms at log20, still
16.09% faster than main, with 29 Metal dispatches, zero CPU fallbacks, and the
same 86,383-byte `e6609d...c7e86` proof. CPU log20 remained neutral at 275.335
ms versus 275.781 ms main. The earlier comparable resource screen reduced
energy about 20% and instructions about 19%; peak RSS rose about 3.1%, within
the 5% guard budget.

## Validation

The 379-source closure, Native Metal lifecycle, source-JIT
compile, independent verification, Metal compile, AOT manifest/probe, and
static source-conformance gates pass. The exact local static lane ran all 584
checks after the extraction, and the final log20 device check measured
109.443 ms prove / 109.962 ms verified request with the unchanged
`e6609d...c7e86` proof, 29 dispatches, and zero CPU fallbacks. An exploration-tree coefficient-form
differential test passed and increased the Metal suite from main's 87/90 to
88/91 while preserving its one inherited resident-FRI failure and two skips.
The scorer diff excludes that locked test path; it is retained for a regular
post-promotion test PR. The test compares every generic/combined evaluation
and Merkle root under a nontrivial split-coordinate permutation.

## Caveats

Source-JIT initialization is outside warmed request samples but remains part of
cold-process evidence. An AOT bundle must be rebuilt for ABI 9 on a host with a
full Metal toolchain. Log22 diagnostic RSS remains operationally important for
concurrent sessions even though this candidate's measured log20 RSS is within
the autoresearch budget. The two significant wide receipts remain visible but
unclaimed because their small-shape guard was statistically inconclusive.

The separate all-cell PR6 contract still lacks the complete exact workload
matrix, every cold-process comparison, and an authenticated locked-host
verdict. **PR6 Supremacy: not achieved.**
