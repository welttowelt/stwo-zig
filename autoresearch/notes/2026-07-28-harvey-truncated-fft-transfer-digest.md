---
title: Harvey truncated-FFT transfer digest for the 2x circle-LDE frontier
author: Oli and Codex
created_utc: 2026-07-28T19:03:32Z
discovery: Elicit paper search
frontier_commit: 78556fe7d3fa6b1dc673276391a730412e94f348
---

# Harvey truncated-FFT transfer digest for the 2x circle-LDE frontier

## Bottom line

Harvey's cache-friendly truncated FFT is useful corroboration for exploiting
known-zero transform structure, but it is not a drop-in STWO candidate. The
paper's strongest measured result comes from large Fourier coefficients in
polynomial multiplication, while STWO evaluates full power-of-two circle
domains over one-word M31 values. The paper's own small-coefficient discussion
warns that spatial locality and root-of-unity overhead become decisive and
explicitly says that modest zero-padding can be the better engineering choice.

The gate-legal implementation shadow is the mechanism already being screened on
the current frontier: retain the full, contiguous power-of-two transform and
consume the known-zero upper half directly in the first active packed radix
pass. This removes materialization work without changing output count, domain
order, transcript bytes, or proof format.

Do not implement a general TFT/ITFT until profiling identifies a live workload
that requests only a strict prefix of transform outputs or has a non-power-of-two
coefficient boundary large enough to repay the extra control flow. The current
2x LDE has neither property.

## Provenance and artifact status

- Discovery source: Elicit API paper search on 2026-07-28, query
  `zero padding FFT LDE polynomial expansion skip copy in-place cache efficient implementation`.
- Primary paper: David Harvey, "A cache-friendly truncated FFT",
  *Theoretical Computer Science* 410 (2009), 2649-2658,
  DOI `10.1016/j.tcs.2009.03.014`, arXiv `0810.3203`.
- Open primary text reviewed in full from the arXiv PDF. The algorithm,
  correctness arguments, empirical section, small-coefficient caveats, and
  references were inspected; pages 12-13 were also rendered to confirm the
  quantitative and regime statements.
- Related primary paper reviewed: David Harvey and Daniel S. Roche,
  "An in-place truncated Fourier transform and applications to polynomial
  multiplication", ISSAC 2010, DOI `10.1145/1837934.1837996`, arXiv
  `1001.5272`.
- The 2009 paper says its mechanisms were implemented in FLINT 1.0.13 and
  zn_poly 0.9. Those historical implementations are an artifact pointer, not a
  reproduction performed for this digest. No paper result is accepted as
  campaign benchmark evidence.

## Campaign frame

### Hard gates

- Exact proof bytes, statement, transcript order, and verifier behavior must
  remain unchanged.
- The public workload/domain contract and benchmark measurement path remain
  unchanged.
- No result counts without full proof verification and the repository's
  G1-G5 gates.
- The candidate must preserve the full ordered evaluation vector expected by
  the prover. A transform that computes only a prefix is illegal unless every
  downstream consumer and the oracle contract are changed, which this campaign
  does not permit.
- The research paper is a hypothesis source. Promotion still requires the
  attested same-host paired workflow.

### Significance floor

The current harness uses
`theta = max(0.01, 2 * per-class A/A dispersion)`. At epoch 2 the CPU thresholds
are class-specific: 3.7308% small, 2.9290% wide, 1.8278% deep, 3.1004% xlarge,
and 1.2526% huge. A local kernel reduction or S1 win below the relevant S3
threshold is bundle material, not a record.

### Evidence locations

- Frozen measurement contract:
  `autoresearch/MANIFEST.json`
- A/A dispersion:
  `autoresearch/ledger/epochs.json`
- Existing structural lever:
  `autoresearch/notes/20260723-023155-shared-prover-vectorization-and-batch-major-quotient-denomin.md`
- Live implementation screen:
  branch `agent/screen-cpu-lde-direct-expand` at frontier `78556fe7`

## Regime map

| Axis | Harvey 2009 | Current STWO lane | Transfer consequence |
| --- | --- | --- | --- |
| Transform purpose | TFT/ITFT for polynomial multiplication | full circle-domain LDE evaluation | Prefix-output savings do not transfer. |
| Input/output geometry | arbitrary `z` nonzero inputs and `n` requested outputs inside a power-of-two ambient transform | exact 2x extension: lower half coefficients, upper half known zero, all outputs required | Only the known-zero input boundary transfers. |
| Coefficients | main 15-35% result uses roughly 16,000-bit Fourier coefficients; second experiment uses word-sized residues inside a different multiplication pipeline | one-word M31 values and packed radix-8 kernels | Headline magnitudes are non-transferable. |
| Hardware | single core on a 2.6 GHz Opteron with 64 KiB L1 and 1 MiB L2 | Apple Silicon M5-class judge host and current packed Zig implementation | Cache topology, SIMD width, and compiler behavior differ. |
| Locality method | balanced row/column decomposition; transpose suggested for small coefficients | contiguous packed radix passes already used | A matrix-TFT rewrite risks strided loads or transpose overhead. |
| Correctness surface | ordinary weighted DFT/TFT over a ring | circle-domain transform with fixed twiddle/domain ordering | Algebra must be rederived; ordinary-FFT code cannot be copied. |

## Claims ledger

| Paper claim | Location | Baseline and status | Campaign interpretation |
| --- | --- | --- | --- |
| Balanced row/column decomposition improves locality relative to recursive half-splitting. | Sections 1, 3, 4 | Algorithmic claim with correctness proof. | Directional corroboration only; STWO already has packed/fused traversal, so source-level inspection and counters decide whether a locality gap remains. |
| Cache-friendly truncated transforms were 15-35% faster for the tested large-coefficient FLINT multiplication range. | Figure 11 and Section 5.1 | Measured against the authors' divide-and-conquer truncated transform, with roughly 2 KiB Fourier coefficients. | Do not transfer the number. Different coefficient size, operation mix, baseline, and host. |
| Word-sized-modulus polynomial multiplication improved by up to 15%. | Section 5.2 | Measured end-to-end inside the Schoenhage-Nussbaumer implementation across broad lengths and modulus sizes. | Still not STWO evidence. The paper reports dependence on how much total time is in FFTs. |
| Small coefficients require attention to cache-line utilization and may need matrix transposition for column transforms. | Section 6 | Author's engineering analysis; no small-coefficient implementation result. | Strong guard against a naive TFT port with strided column walks. |
| For small coefficients, padding to an integral row can cost at most 1% in the paper's worked example and simplify the inverse transform. | Section 6 | Worked bound for one double-precision geometry, not a benchmark. | Supports retaining STWO's regular power-of-two/full-output shape when it enables simpler packed kernels. |
| Root-of-unity computation/storage cost matters more for small coefficients. | Section 6 | Author's caveat. | Any generalized truncated path must include twiddle addressing and cache cost in its falsifier. |
| In-place TFT/ITFT uses O(1) auxiliary space but may pay a larger arithmetic constant. | Harvey-Roche 2010, Sections 3, 4, 6 | Proven asymptotics; authors explicitly leave constant-factor competitiveness open. | Memory reduction alone is not a CPU-time record candidate on this host. |

## Mechanism transfer verdicts

### Truncate unused output coordinates

**BLOCKED for the current lane.** STWO consumes the full ordered LDE evaluation
vector. Dropping output coordinates changes the prover contract and eventually
the proof/transcript. There is no legal residue beyond avoiding work whose
result is algebraically predetermined while still producing every required
value.

### Avoid butterflies whose input is known zero

**VEIN-CONFIRMED.** The paper formalizes the general value of a known-zero input
boundary. STWO's exact 2x case has a much simpler specialization: the skipped
first layer maps `(v, 0)` to duplicate values, after which the existing packed
radix cascade can proceed unchanged.

**Implementation shadow:** read immutable half-sized coefficients directly
into both logical groups of the first active packed radix-8 pass. The
destination may be uninitialized. This eliminates:

1. copying coefficients into the destination lower half;
2. zero-filling the destination upper half; and
3. the degenerate first butterfly layer.

The current screen implements precisely this shadow in
`fftThreeLayersForwardPackedM31FromHalfSource` and
`evaluateExtensionBuffersFromCoefficientSourcesWithTwiddles`.

### Balanced cache-friendly matrix decomposition

**PARKED.** The idea is real, but the paper supplies no evidence for the
one-word/full-output/Apple-Silicon regime. A new matrix decomposition would add
twiddle-control complexity and either strided accesses or transpose passes.

Cheapest discharging test: use current stage timers and hardware counters on
the huge CPU workload. Reopen only if the upper forward passes are
cache-miss/bandwidth dominated after the direct-source expansion lands. If
compute instructions remain the wall, a decomposition rewrite is the wrong
tool.

### General in-place TFT/ITFT

**DO-NOT-ADOPT for the current record attempt.** It solves auxiliary-space and
arbitrary-length problems the live lane does not have, adds irregular traversal
and extra arithmetic, and risks sacrificing packed contiguous kernels. This is
our transfer verdict, not a defect claimed by the paper.

### Transpose for spatial locality

**CORROBORATION / conditional candidate.** It is the correct residue if a future
matrix decomposition proves necessary, but only when a measured strided-access
wall exceeds the cost of two transpose passes. It is not part of the present
candidate.

## Lever-library delta

### VEIN-CONFIRMED: direct half-source first-radix expansion

- Owner: `stwo-autoresearch.cpu-lde-direct-expand`
- Expected value: remove two destination writes per coefficient plus the
  already degenerate layer. No paper-derived percentage is assigned.
- Cheapest correctness falsifier: randomized differential test against
  explicit copy + zero-fill + generic evaluation for all supported log sizes,
  followed by exact proof-byte and verifier parity.
- Cheapest performance falsifier: preregistered S1 paired screen on the
  class where LDE attribution is largest. Reject if median/cycles do not improve
  or if the confidence interval is inconsistent with a record-sized S3 effect.

### PARK: cache-oblivious/balanced transform scheduling

- Owner: unassigned until direct-source screen and re-attribution finish.
- Activation predicate: forward-transform stages remain materially
  cache-miss/bandwidth dominated, and the predicted end-to-end reduction can
  exceed the relevant class theta.
- Cheapest falsifier: stage counters plus a synthetic contiguous-vs-strided
  traversal harness importing the live kernels.

### DO-NOT-ADOPT: headline 15-35% as an EV prior

The number belongs to 2 KiB Fourier coefficients on a 2008 Opteron against the
authors' own divide-and-conquer TFT. It must never appear as an expected STWO
speedup.

## Immediate campaign action

Keep the live candidate narrow. Finish randomized differential tests, exact
proof verification, and the preregistered S1 screen for direct half-source
expansion. If it survives, re-attribute S3 before deciding whether it can clear
the class-specific theta alone or must be bundled. Do not add general TFT
control flow during this screen.
