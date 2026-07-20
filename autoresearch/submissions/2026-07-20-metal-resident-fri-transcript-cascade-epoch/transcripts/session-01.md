# Session 01 — second Metal-backend architecture campaign

Date: 2026-07-20
Model: GPT-5 Codex

## Objective and evidence order

The user requested another optimization campaign focused on the Metal backend,
with the repository CLI updated first, an untouched local suite baseline before
research, every repository skill exercised, prior notes/transcripts treated as
the research prior, profiler-driven architectural design and visualization,
and submission as soon as a significant exact solution exists.

The first attempted updater path was run from the outer workspace and did not
exist. No benchmark or source action had occurred. The canonical checkout was
located and its repo-resident updater then fast-forwarded `main` from
`5d2eb59b2f9d` to `1d757ffe407a` (thirteen commits) before benchmarking. That
frontier includes the previous UMA Merkle readback optimization and the latest
CPU work. The fixed manifest still exposes only the CPU board; the production
Native Metal binary remains the honest diagnostic and parity target for this
Metal-only campaign.

## Untouched frontier baseline

The three fixed workload shapes were run through the real ReleaseFast,
source-JIT Native Metal product with ten warmups, seven timed verified samples,
and the functional protocol. Medians were 8.583 ms small (highly dispersed),
14.906 ms wide, and 11.100 ms deep. All samples verified, were byte-identical,
matched the established proof hashes, reported `accelerated_without_fallbacks`,
and used zero CPU fallbacks. Dispatch/commit telemetry remained 28/12,
36/16, and 39/17 respectively. The fixed CPU controls measured 1.651, 10.834,
and 7.372 ms with the same hashes.

## Instructions, skills, and research prior

The complete task, harness README, manifest, all five repository skills, and
the compute-only Metal common-pattern reference were read. The exercised skills
are algorithm matching, Metal performance design, Metal profiling, Zig
profiling, and submission transcripts. Render guidance is not applicable to
this compute-only prover. A fresh detached worktree was created by `stwo-perf
clone`, setup passed, and a dedicated branch was created at the untouched
frontier.

Every merged submission note and attached transcript was then read in full.
The combined frontier already contains packed direct quotient rows, resident
and deeper CPU Merkle scheduling, four-way FRI leaf hashing, packed sampled
evaluation, a linear FRI coset walk, parallel CPU FFT/constant composition, and
the prior Metal shared-Merkle readback change. Rejected work includes packed
CPU FRI arithmetic whose end-to-end CI failed, neutral accumulator ownership,
generic batch-inversion replacement, and narrower shared-storage selection.
The important Metal-specific prior is that FRI GPU timestamps total roughly
3.2 ms inside a 6.6 ms wall stage, with one synchronous producer epoch per
transcript-dependent FRI root; Merkle decommit was already reduced by 93–96%.

## Fresh residual attribution

Current-frontier profiled samples confirm that decommit is no longer the
bottleneck. At steady state, wide is approximately: main commit 1.8 ms,
composition evaluation 2.6 ms, composition commit 1.3–1.4 ms, sampled-value
evaluation 1.4–1.5 ms, FRI quotient/folds/commits 6.2–6.6 ms, FRI decommit
0.14–0.16 ms, and trace decommit 0.02–0.03 ms. Deep ends near: main commit
0.69 ms, composition commit 0.80 ms, sampled values 1.75 ms, FRI 6.28 ms,
and both decommit stages below 0.19 ms combined. Small spends about 5.7 ms of
roughly 9 ms in FRI. Early deep samples ramp down monotonically despite five
warmups, so later verdict evidence must interleave arms and use more warmup;
single process medians are attribution only.

The leading architectural hypothesis is no longer hash readback. Each FRI root
must update the Fiat–Shamir channel and produce the alpha consumed by the next
fold, forcing 8–12 command-buffer completion boundaries. If the exact channel
state transition can execute on GPU between the already-resident fold and
Merkle kernels, the cascade can be encoded as a much larger epoch and expose
only one terminal wait. Before selecting it, the channel/root/alpha dependency,
resource ABI, failure propagation, and fallback must be mapped; sampled-value
evaluation is being measured as a lower-risk competing target.

## Algorithmic problem match

The residual is a static, sequential task graph rather than a slow primitive.
For a resident line evaluation `E_i`, every FRI layer performs exactly:

```text
E_i -> Merkle(E_i) -> root_i -> H(channel_i || root_i) -> alpha_i
                                                         |
                                                         v
                                domain_i + E_i -------> fold -> E_(i+1)
```

The alpha dependency makes the *device work* sequential, but it does not make
host participation between layers fundamental. The verifier observes only the
ordered roots, the exact Blake2s channel transition and challenges, the layer
columns, and the final polynomial. All inputs other than `alpha_i` are known
before submission, and the repository already contains byte-exact Metal
implementations of the Merkle hash, Blake2s transcript mix/draw, and FRI fold.
This is therefore a communication-avoiding accelerator scheduling problem: run
the immutable DAG on one device timeline and cross the CPU/device boundary only
at the beginning and end.

Candidate architectures were compared before editing production code:

| Candidate | Host/device rounds | Exactness | Expected effect | Decision |
| --- | ---: | --- | --- | --- |
| Current CPU transcript feedback | O(layers) | Existing reference | Measured 12 waits on wide | Baseline |
| Shared-root polling or completion callbacks | O(layers) | Exact | Moves rather than removes synchronization | Reject |
| Multiple asynchronous command buffers/events | O(layers) encoding dependencies | Exact | Next alpha is unavailable when encoding | Reject |
| Change fold step or omit roots | Fewer layers | Protocol change | Invalidates proof/verifier contract | Reject |
| Return small layers to CPU | Fewer GPU waits | Potentially exact | Violates accelerated-without-fallback contract | Reject |
| One resident GPU transcript/fold/Merkle cascade | O(1) | Exact if state ABI matches | Removes repeated setup and waits | Select |

The selected idea matches Apple's primary guidance to submit the fewest
command buffers needed and avoid frequent CPU/GPU synchronization. The device
still executes every dependency in order; only redundant host orchestration is
removed. This is derived from the local protocol and profiling evidence, not a
claim that the cryptographic dependency itself has become parallel.

Prediction: on wide, reduce line-FRI producer epochs from twelve to one and FRI
wall time from roughly 6.6 ms toward 2.5 ms or below, yielding at least a 20%
end-to-end improvement while preserving proof bytes and all logical Merkle
commit counters. The hypothesis is falsified by any verifier/hash/channel-state
mismatch, CPU fallback, increased peak memory outside the fixed workload
budget, or a confidence interval that fails to improve the end-to-end proof.

## Metal architecture brief

Target is the local Apple M5 Max on macOS using the production source-JIT
runtime path; shader compilation and pipeline creation remain initialization
work outside post-warmup samples. The optimization unit is one proof's entire
line-FRI inner-layer cascade. Fresh instrumentation measured only about 0.58 ms
of fused line fold-plus-commit GPU work and about 0.15 ms of quotient/circle
work inside a 6.6 ms wide FRI stage. Twelve independent fold/commit calls each
allocate bindings, build encoders, commit one command buffer, block the host,
read the root, advance Blake2s, and repeat.

The proposed resource and lifetime map is:

| Resource | Storage/lifetime | Access |
| --- | --- | --- |
| Initial resident evaluation | Existing shared buffer, whole cascade | GPU read |
| Intermediate evaluations | Geometric-size private buffers, cascade lifetime | GPU write/read only |
| Terminal evaluation | Existing shared-buffer representation, returned to prover | GPU write; CPU reads final polynomial |
| SoA coordinate columns | Geometric-size shared buffers, returned to prover | GPU write/read |
| Merkle layers | Shared buffers per logical tree, returned as tree handles | GPU write; CPU later decommit |
| Inverse domain coordinates | One concatenated immutable upload | GPU read |
| Transcript/root arena | Tiny shared buffer initialized from CPU channel | GPU roots/state/challenges; CPU reads state and roots once |

At the fixed wide size the geometric evaluation and coordinate series are well
under 1 MiB and all Merkle layers are only a few MiB, negligible beside the
device working-set recommendation. Existing buffers remain shared because the
prover consumes columns and Merkle layers on CPU later; private storage would
add copies and break the zero-readback ownership model.

```text
current:  CPU submit -> GPU tree -> WAIT -> CPU transcript -> submit fold/tree
                    repeated once per inner layer

new:      CPU allocate/upload/submit
             -> [GPU coords -> tree -> transcript -> fold]
             -> [GPU coords -> tree -> transcript -> fold] ...
             -> GPU final tree/transcript -> one WAIT -> CPU ownership handoff
```

One command buffer and one compute encoder contain the full ordered cascade.
Explicit buffer-scope barriers separate each producer/consumer edge; no
per-layer CPU wait or shared event is needed. Existing fold, coordinate, leaf,
parent, transcript-mix, and transcript-draw pipeline states retain their tuned
widths. Each tree's final parent dispatch writes its root directly into a
stage-specific slot in the shared transcript arena. The existing one-thread
mix kernel consumes that slot, and the existing secure-draw kernel writes the
next fold alpha into another arena slot. This avoids a blit, a new shader
export, and any source-JIT/AOT ABI revision.

Correctness is constructional: layer order, domain inverses, storage layout,
Merkle leaf/parent kernels, channel transition, and fold formula are unchanged.
The returned channel digest and draw count replace the host state only after a
successful command; every logical layer still yields the same evaluation and
tree object consumed by the unchanged decommit path. Runtime failure or an
unsupported channel/shape takes the existing generic path before mutation; a
device transcript rejection/error aborts instead of silently falling back.
Telemetry must show one physical cascade epoch, unchanged logical resident
Merkle commits, zero CPU fallbacks, verified proofs, and byte-identical hashes.

## First implementation and feedback

The implementation added a single-fold cascade hook to the generic FRI
scheduler, gated at compile time to the exact `Blake2sChannel` and at runtime to
resident, power-of-two, fold-step-one shapes. It preallocates every returned
coordinate column and terminal evaluation, submits a runtime transaction, then
moves the resulting resident trees into the unchanged prover layer objects.
Unsupported cases return `null` before changing the channel. The runtime builds
all intermediate evaluations and logical Merkle trees, encodes their dependency
graph into one command buffer, and returns the final transcript state only after
successful completion.

The first prototype used a new fused one-lane transcript-edge MSL kernel and
therefore advanced the shader ABI. The AOT export probe exposed the unnecessary
compatibility cost. The production version was redesigned around the already
authenticated transcript mix/draw exports: final Merkle roots alias disjoint
offsets of the transcript arena, while tree metadata teaches root readback and
later decommitment about those offsets. The custom kernel and ABI bump were
fully removed. `metal-check` and both core AOT tests pass unchanged. The full
Metal suite reaches 79/82 passed with the same pre-existing resident-FRI test
failure; the new five-layer test, which compares every CPU/GPU root, transcript
challenge/state, and final value, passes.

The Native Metal product lifecycle, source-JIT compilation, independent
verification, and fixed proof hashes all remain exact. The wide proof is still
`57a7d291...0f3374`; every sample verifies; telemetry changes from twelve
physical line-FRI producer epochs to one while retaining sixteen logical
resident commits and zero fallbacks. At log 14 the final cascade contains 169
ordered kernel dispatches but only one compute encoder, one command buffer, one
wait, and no blit.

The first unprofiled process was retained as a thermal dead end: despite ten
proof warmups it still measured about 19.8 ms because the new long command
ramped from roughly 3.7 ms to 0.7 ms of GPU time across eleven invocations.
Subsequent interleaved predecessor/candidate processes are therefore required;
isolated first-process numbers are not decision evidence on this host.

A warmed profiled comparison put wide FRI at 4.08–4.92 ms initially and
4.16–4.24 ms after consolidating the 156 dispatches into one compute encoder
with explicit buffer barriers. The untouched frontier measured 6.2–6.6 ms.
Steady cascade GPU time is 0.68–0.71 ms, confirming that device arithmetic is
essentially unchanged and the gain comes from communication/scheduling.
Host phase probes after clock stabilization attributed about 0.42 ms to inverse
coordinate preparation, 0.03 ms to returned-buffer allocation, 1.12 ms to the
runtime allocation/encoding/wait transaction (including 0.69 ms GPU), and
0.004 ms to tree ownership wrapping.

An initial A-B-B-A wide check, each process using ten warmups and seven verified
samples, measured predecessor medians 15.344 and 15.495 ms versus candidate
medians 12.729 and 13.794 ms. The pooled medians are approximately 15.42 versus
13.46 ms (ratio 0.873). One candidate sample at 18.21 ms shows why longer
interleaving and confidence intervals are still needed. The hashes were exact
in all 28 timed proofs; epoch telemetry was 12 for each predecessor proof and 1
for each candidate proof.

## ABI-neutral candidate validation

The final reuse-based architecture was rebuilt and tested independently from
the prototype, then measured in a fresh A-B-B-A sequence for every fixed shape.
Each arm used a separate process, ten warmups, seven timed verified proofs, the
functional protocol, and the real source-JIT Native Metal binary. Pooled
sample medians and deterministic 100,000-resample median-ratio intervals were:

| Shape | Predecessor median | Candidate median | B/A ratio (95% bootstrap CI) | Improvement |
| --- | ---: | ---: | ---: | ---: |
| small | 4.927 ms | 3.051 ms | 0.619 [0.556, 0.681] | 38.08% |
| wide | 14.718 ms | 12.700 ms | 0.863 [0.849, 0.885] | 13.71% |
| deep | 10.910 ms | 8.796 ms | 0.806 [0.800, 0.813] | 19.38% |

The small predecessor retained a visible process-order thermal shift (5.540
then 4.519 ms), but both counterbalanced candidate arms remained near 3.05 ms
and won independently. Wide predecessor/candidate process medians were
14.973/12.957 and 14.701/12.593 ms; deep were 10.921/8.809 and 10.899/8.735 ms.
Across the 84 timed A/B proofs, all proofs verified, all hashes matched the
untouched frontier, all classifications were
`accelerated_without_fallbacks`, and total CPU fallbacks were zero. Logical
resident-commit counts stayed 12/16/17 while line-FRI epochs collapsed from
8/12/12 to one and top-level Metal telemetry counts fell from 28/36/39 to
19/23/26.

## Final frontier sync and current-policy guards

The first packaging attempt correctly failed before creating a submission: the
note used descriptive variants of four schema-required heading names, and the
CLI warned that `origin/main` had advanced during the session. The canonical
CLI was updated again, fast-forwarding thirteen commits from `1d757ffe407a` to
`fd9bd94395ce`. Inspection showed no prover/backend source change; the delta is
locked harness, anchor, conformance, and benchmark-history material. The source
commit was rebased cleanly onto that tip as `9367f3cc316e`, preserving the
measured implementation exactly while adopting the current policy.

The new policy freezes the M5 CPU anchors and impact-maps the generic FRI hook
to all twelve native AIR regression guards. Final S3 runs were therefore
repeated against `fd9bd94395ce`. Each of small, wide, and deep passed G1–G5,
cross-arm byte identity, the pinned Rust oracle, request/RSS/anchor budgets,
and 12/12 paired guards. CPU ratios were confirmed-neutral, as expected for a
compile-time Metal-only branch: small 0.9970 `[0.9847, 1.0116]`, wide 0.9998
`[0.9799, 1.0083]`, and deep 1.0027 `[0.9934, 1.0126]`. These current-harness
verdicts replace the earlier advisory files for packaging.

## Hosted static feedback and ownership-boundary refactor

PR #25's package validator and prover gate passed immediately, but the focused
static lane reported that `src/prover/fri.zig` had reached 888 lines, above the
repository's 850-line manual-source ceiling. This was attributable to placing
Metal cascade ownership adaptation directly in the generic scheduler, not to a
functional failure.

The adaptation was moved into `MetalCommitBackend.commitFriLayers`: the backend
now invokes the raw cascade and moves its columns, trees, terminal evaluation,
and source ownership into the generic prover's supplied private layer/result
types. The generic scheduler retains only the optional call and immediate
return. Compact error declarations bring the owner to 849 lines while the
Metal backend remains 811 lines. `scripts/check_source_conformance.py` now
passes with no new violations.

After the refactor, `zig build test`, `metal-check`, both AOT probes, and the
Native Metal device-only lifecycle all pass again. A fresh wide source-JIT run
measures 12.823 ms, retains the exact `57a7d291...0f3374` hash, verifies all
samples, reports one line-FRI epoch / 23 high-level Metal dispatches, and uses
zero CPU fallbacks. The move changes code ownership only; the resident command
graph and measured mechanism are unchanged.
