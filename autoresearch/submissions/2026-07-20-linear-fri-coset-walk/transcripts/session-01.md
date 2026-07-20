# Session 01 — frontier baseline and architecture search

Date: 2026-07-20
Model: GPT-5 Codex

## Objective supplied by the researcher

Drive the largest CPU or Metal optimization allowed by the autoresearch
contract, starting with a local benchmark, learning from prior notes and
transcripts, profiling hot paths, using architectural visualization and
critical analysis, and submitting as soon as a significant verified solution
exists.

## Contract and initial decisions

- Updated the repo-resident `stwo-perf` CLI/frontier before benchmarking. The
  clean base advanced seven commits and now includes the promoted packed
  sampled-value evaluation.
- Read every unique in-repo skill guide. The scored task is specifically the
  `core_cpu` end-to-end prover suite; Metal remains worth measuring for
  applicability, but a Metal-only change cannot move the CPU board unless the
  production CPU benchmark actually invokes it.
- Kept updated `main` untouched as the paired predecessor and created this
  worktree from it. Existing researcher worktrees and their untracked notes
  were not modified.
- The initial frontier reports approximately 2.379 ms small, 11.524 ms wide,
  and 8.131 ms deep. These are ledger values, not trusted as this host's local
  baseline; a fresh local full-suite run comes first.

## Search policy

The first design choice will be driven by end-to-end stage attribution and
live-code counter/sample evidence. Existing submission notes, transcripts, and
diffs will then be treated as prior experiments: reusable mechanisms will be
combined only when their invariants compose, and rejected ideas will not be
repeated without new evidence. Any algorithm replacement gets a formal
problem-match brief before source edits. Constant-factor changes remain under
the Zig/Metal profiling loop.

## Fresh local suite baseline

Ran the production `ReleaseFast` CPU proof binary on all three fixed workloads
with ten warmups and three timed, verified samples per workload. Median prove
times were:

| class | workload | median prove time | proof digest stable |
| --- | --- | ---: | --- |
| small | wide Fibonacci 2^10 x 8 | 1.929 ms | yes |
| wide | wide Fibonacci 2^14 x 32 | 11.582 ms | yes |
| deep | Plonk 2^14 | 8.050 ms | yes |

The worktree is intentionally dirty only because transcript capture began
before timing, so the reports correctly label these as diagnostic rather than
headline-eligible. The byte-identical proofs and local medians are still valid
grounding evidence. Wide exposes the largest absolute time budget; deep is
close enough that a shared prover-stage optimization would earn much more suite
score than another workload-specific shortcut.

## Prior-work synthesis and fresh attribution

Read all four promoted notes and attached transcripts, then inspected their
source diffs. The combined frontier already packs direct quotient rows, reuses
the resident Merkle pool deeper into trees, extends four-way BLAKE2s leaf
hashing down the FRI cascade, and evaluates batches of sampled polynomials in
native lanes. Those mechanisms are the baseline rather than candidates to
repeat.

Seven-sample current-frontier stage profiles gave this residual map:

```text
stage median (ms)               small   wide   deep
FRI quotient build + commit     0.807   3.870  3.804
main trace commit               0.241   1.913  1.164
composition evaluation          0.037   2.729  0.393
sampled-value evaluation        0.080   0.712  0.369
proof of work                   0.251   0.250  0.264
```

Wide composition evaluation is large but its workload recurrence is outside
the editable surface. FRI is the largest editable common stage. A live stack
sample also retained BLAKE2s, quotient execution, folding transforms, and
worker waits as residuals; no single prior mechanism had disappeared, so the
next target must remove work shared by the circle and line folds.

## Metal applicability/design brief

The Metal skill classified the alternative as compute-only. Device capability
capture reported Apple M5 Max, 32 KiB maximum threadgroup memory, 1,024 maximum
threads per threadgroup, and a roughly 55.7 GB recommended working set. The
generic device runner measured a 1,048,576-element add at 0.0393 ms and about
321 GB/s with a 256-thread group; a sweep peaked at 1,024 threads, 0.0378 ms
and about 333 GB/s. This is a bandwidth-ceiling calibration, not prover
evidence. Its sub-0.05 ms dispatch time also means submission economics matter
for small kernels.

The scored `native-proof-bench-cpu` is compiled against `CpuBackend` and rejects
Metal options; neither the production Metal engine nor command queue is linked
into this board. Therefore a Metal-only edit cannot affect the score, while
adding an offload boundary would require locked build/product changes and a
new backend identity. Whole-command Metal System Trace was attempted but is
unavailable because the host has Command Line Tools rather than full Xcode.
The selected architecture remains CPU, with no resource-lifetime or CPU/GPU
ownership transition to prove.

## Architecture visualization

```text
                         current FRI fold setup

logical output i
      |
      +-- bit_reverse(i << 1)
      |          |
      |          +-- reconstruct circle point from index bits
      |                     O(log N) group additions per point
      v
coordinate workspace --> batch inverse --> butterfly fold --> next evaluation

                         selected traversal

coset initial --(+ fixed step)--> P0, P1, P2, ...       O(1) each
                                  |   |   |
                                  +---+---+-- scatter at bit_reverse(j)
                                               |
                                               v
coordinate workspace --> identical batch inverse --> identical butterfly fold
```

Only coordinate enumeration changes. Inversion order, field arithmetic,
butterfly order, alpha powers, evaluation storage, transcript roots, and proof
serialization remain unchanged.

## Problem-match brief — bit-reversed coset enumeration

Task and required semantics:
Generate the x (line fold) or y (circle fold) coordinate corresponding to each
bit-reversed even domain index. Output is the exact same M31 array in the exact
same order; no approximation, randomness, or protocol change is allowed.

Inputs, measured scale/provenance, encoding, and computational model:
Power-of-two circle/line domains from the fixed FRI suite, primarily log sizes
10–15, represented by an initial circle-group point and fixed step. Cost model
is arm64 word-RAM plus M31 group arithmetic. The current live implementation
calls `domain.at(bitReverseIndex(i << 1, log_size))` once per output.

Constraints, promises, invariants, and exploitable structure:
For `w = log_size - 1`, `bitrev_log_size(2*i) = bitrev_w(i)`. Bit reversal is
self-inverse. A coset is an arithmetic progression in the circle group, so its
natural sequence obeys `P[j+1] = P[j] + step`. The destination workspace is
already writable scratch and can accept permutation scatters.

Candidate matches, relationship, and evidence status:

| candidate | relationship | guarantee/complexity | measured fit | risk |
| --- | --- | --- | --- | --- |
| independent indexed reconstruction | current exact baseline | derived `Theta(N log N)` group work | 28.177 ns/coordinate | none, slow |
| natural coset walk + bit-reversal scatter | exact reformulation | sourced/derived `Theta(N)` group work | 3.823 ns/coordinate | cache scatter |
| direct bit-reversed Gray/delta walk | exact specialized generator | `Theta(N)` and sequential writes | unmeasured | harder delta proof |
| session-cached inverse/twiddle tables | preprocessing tradeoff | `Theta(N)` once, reuse later | potentially strong at S4 | lifecycle/RSS and min-rung expansion |

Chosen canonical problem and exact variant:
Linear-time generation of a power-of-two bit-reversal permutation while
evaluating a group arithmetic progression. Bit reversal is the canonical FFT
permutation; prior work establishes linear-time generation on a random-access
machine. This instance additionally exploits an existing O(1)-step coset
iterator.

Project -> canonical mapping and solution recovery:
Let `P(j) = initial + j*step`. The current output is
`out[i] = coord(P(bitrev_w(i)))`. Natural iteration produces `P(j)` for
`j=0..N-1`; writing it to `out[bitrev_w(j)]` recovers the current array because
`bitrev_w(bitrev_w(i)) = i`.

Complexity/limits, named parameters, and citations:
Current `CirclePointIndex.toPoint` sums generator doubles for every set index
bit, yielding `Theta(N*w)` group additions in the measured loop. The selected
transfer uses `Theta(N)` group additions, `N` word bit reversals, and unchanged
`Theta(N)` storage traffic. The pinned upstream Rust implementation labels the
same indexed fold lookup inefficient and calls for stored domain twiddles:
<https://github.com/starkware-libs/stwo/blob/a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2/crates/stwo/src/prover/backend/cpu/fri.rs>.
Hinze describes bit reversal as an FFT permutation with a linear-time
random-access implementation: <https://doi.org/10.1017/S0956796800003701>.

Prior algorithms, solvers, and implementations:
The upstream pinned CPU fold is the same indexed baseline. Linear sequential,
inductive/XOR, cache-oblivious, and table-based bit reversal are established
families. The local code already supplies the natural-order coset iterator, so
no external implementation or license-bearing code is copied.

Selected transfer, integration boundary, and rejected alternatives:
Use the local coset iterator and existing `bitReverseIndex` to fill only the two
fold coordinate workspaces. Reject a direct Gray/delta bit-reversed iterator
for this checkpoint because it adds a more delicate signed group-step proof for
little measured upside over the already 7.3x candidate. Defer session caching
because it touches S4 lifecycle ownership and increases retained memory.

End-to-end prediction, crossover, and falsifier:
S1 ABBA measured candidate/baseline wall ratio 0.1370 (the tool displayed the
inverse baseline/candidate ratio 7.3005 with CI [7.1535, 7.4194]), instruction
ratio 0.1266, and cycle ratio 0.1362. Per-coordinate savings are about 24.35 ns;
a log-14 half-domain pass should save about 0.20 ms. Across the initial circle
fold and geometric line-fold cascade, predict 0.3–0.8 ms or roughly 3–8%
end-to-end on wide/deep. Falsifier: stage profiles fail to reduce FRI time or
paired S3 confidence spans the 0.99 threshold.

Correctness and benchmark plan:
Property-test the iterator/scatter helper against indexed reconstruction for
multiple log sizes, shifted cosets, and both x/y coordinates. Run the full
ReleaseFast closure, byte-identical three-workload diagnostics, then paired S3
for every class whose stage moves.

Open uncertainty:
Bit-reversal scatter locality may shrink the microbenchmark gain once batch
inversion and fold arithmetic dominate. The exact share of coordinate
enumeration inside the aggregate FRI stage remains to be measured after
integration.

## Implementation and outcome

Implemented one private helper in `src/core/fri/folding.zig` and routed all four
production coordinate-generation loops through it: allocating/in-place line
folds and secure-slice/coordinate-column circle folds. The helper changes only
how the exact coordinate array is generated. A property test compares x and y
arrays with independent indexed reconstruction over shifted cosets for every
supported test log size through 15.

The first focused build passed the ReleaseFast core closure across 70
transitive sources. Fresh candidate diagnostics kept the existing proof hashes
for all three workloads. The target FRI stage moved as predicted:

```text
class   predecessor FRI ms   candidate FRI ms   reduction
small          0.807                0.792          1.9%
wide           3.870                3.229         16.6%
deep           3.804                3.177         16.5%
```

The small stage share was much lower than wide/deep, but repository policy
requires paired evidence for every moved class. All three official S3 ABBA
runs cleared the 1% significance threshold over 15 rounds:

```text
class  ratio    95% CI              predecessor -> candidate median
small  0.9690   [0.9507, 0.9824]     1.590 -> 1.540 ms
wide   0.9408   [0.9284, 0.9539]    11.412 -> 10.752 ms
deep   0.9189   [0.9091, 0.9610]     8.108 -> 7.456 ms
```

Every timed proof verified and remained byte-identical. The compounded
three-class ratio is about 0.9427, or a 5.73% suite improvement. ReleaseFast
prover and native CPU product closures then passed across 152 and 190
transitive sources. Formatting and `git diff --check` also passed.

No further optimization was mixed into this checkpoint. A direct delta/Gray
bit-reversed iterator, retained session twiddles, AoS FRI layer ownership, and
eight-message BLAKE interleaving remain distinct future experiments. The user
requested submission as soon as a significant solution existed; with all
three class CIs clear and the correctness closures green, packaging begins now.
