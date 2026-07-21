# Evidence-Governed Open Optimization

## A holistic structural coverage matrix for cumulative prover improvement

**Date:** 2026-07-21

**Status:** Research and design paper; informative until its mechanisms are
adopted by a versioned benchmark epoch

**Implementation issue:**
[`teddyjfpender/stwo-zig#36`](https://github.com/teddyjfpender/stwo-zig/issues/36)

## Abstract

Open innovation explains why an organization should permit useful knowledge to
cross its boundary. It does not, by itself, specify how a software system should
decide whether an inbound optimization is correct, general, reproducible, and
valuable. High-performance cryptographic software makes this distinction
especially important: a locally faster implementation may change proof
semantics, exploit a benchmark artifact, regress another workload, consume an
unacceptable amount of memory, or disappear under measurement noise.

This paper proposes **evidence-governed open optimization**: an institutional and
technical architecture in which a codebase is deliberately permeable to external
optimization ideas, while admission to the advancing performance frontier is
controlled by correctness oracles, a holistic structural workload matrix,
paired statistical measurement, regression constraints, provenance, and an
append-only evidence ledger. The benchmark suite is treated not as a leaderboard
of unrelated programs but as a sampled response surface over prover structure.
Each candidate change produces a vector of effects across trace geometry,
constraint character, commitment work, memory regime, lifecycle, and backend.

The resulting search resembles multi-dimensional gradient descent, but the
precise mathematical analogue is constrained, noisy, multi-objective,
derivative-free optimization. Source changes are discrete interventions;
performance is observed through expensive black-box experiments; correctness and
resource limits form the feasible region; and the coverage matrix supplies
directional evidence. A change advances the system only when its measured effect
is sufficiently positive, its uncertainty is bounded, every non-negotiable
constraint holds, and its evidence can be independently reconstructed.

The proposal is instantiated for `stwo-zig`, where external and autonomous
contributors optimize a STARK prover across Zig SIMD CPU and Metal GPU backends.
The architecture is intended to make the repository more receptive to diverse
ideas while making its definition of progress substantially stricter.

**Keywords:** open innovation, absorptive capacity, benchmarking, derivative-free
optimization, multi-objective optimization, workload characterization,
reproducibility, STARK provers, autoresearch, software governance

---

## 1. Introduction

Chesbrough defines open innovation in terms of purposive flows of knowledge
across organizational boundaries [1]. The Cambridge Institute for Manufacturing
(IfM) subsequently emphasized that implementing open innovation requires more
than declaring the boundary open: organizations need a common language,
appropriate structures, enabling practices, and a culture capable of acting on
external knowledge [2, 3]. Cohen and Levinthal describe the related concept of
**absorptive capacity** as the ability to recognize the value of external
knowledge, assimilate it, and apply it [4].

This paper applies those ideas to an open high-performance codebase. The mapping
is analogical, not a claim that a repository is literally a firm:

| Innovation-system concept | Software-system realization |
|---|---|
| Organizational boundary | Contribution, package, build, and release boundaries |
| Knowledge inflow | External patch, algorithm, kernel, trace layout, or measurement method |
| Common language | APIs, workload descriptors, benchmark schemas, and proof protocols |
| Absorptive capacity | Ability to understand, validate, integrate, and reuse an optimization |
| Innovation portfolio | Diverse candidate changes and workload families |
| Evaluation capability | Correctness oracles, profilers, statistical tests, and reviewers |
| Value realization | Reproducible end-to-end improvement in an admitted proof system |
| Organizational memory | Immutable reports, deltas, decisions, and rejected hypotheses |

The central proposition is:

> A codebase is meaningfully permeable to optimization only when it can explain
> what changed, measure how much changed across the relevant system, decide
> whether the change is admissible, and retain that decision as reusable
> knowledge.

Without permeability, potentially valuable external ideas cannot enter. Without
measurement and admission, permeability merely increases unverified change.
Without preserved evidence, each contributor repeats the same discovery process
and the system does not learn.

`stwo-zig` already contains much of the necessary machinery: a pinned Rust Stwo
correctness oracle, backend-specific benchmark products, paired ABBA execution,
Hodges-Lehmann ratio estimates, bootstrap confidence intervals, A/A dispersion,
regression guards, immutable submissions, and an append-only promotion ledger.
The next step is to make the workload model as rigorous as the evidence protocol.

---

## 2. The problem: openness without legibility

An optimization patch is not intrinsically an improvement. It is a hypothesis:

> Under stated semantics, workloads, protocols, machines, and lifecycle
> conditions, candidate implementation `x_1` has a more desirable response than
> predecessor `x_0`.

That hypothesis contains at least four separate questions:

1. **Identity:** What source, executable, runtime artifact, and inputs changed?
2. **Validity:** Does the candidate compute the same admitted proof semantics?
3. **Effect:** How large is the performance change, and how uncertain is it?
4. **Generality:** Does the change improve the relevant workload domain rather
   than a single exposed benchmark point?

A conventional pull request answers identity approximately through a diff and
validity partially through tests. A single benchmark answers effect weakly and
generality hardly at all. An evidence-governed repository must answer all four.

### 2.1 Permeability is selective, not frictionless

In open innovation, a permeable boundary allows external knowledge to enter and
internal knowledge to leave. In safety- and performance-critical software, the
boundary must also be selective. The correct design is therefore not minimal
friction in all circumstances. It is:

- low friction for expressing and testing a new idea;
- high precision at the correctness and promotion boundary;
- proportional cost, with cheap failures occurring before expensive evidence;
- explicit ownership of every exception;
- preserved learning from accepted, neutral, and rejected experiments.

This distinction separates **idea permeability** from **frontier permeability**.
Anyone may propose a search direction. Only evidence-complete candidates may
advance the trusted frontier.

### 2.2 A benchmark can become an optimization target instead of a sample

Fixed workloads initially improve comparability. Over time they also create an
opportunity for specialization. Contributors learn exact row counts, column
widths, cache transitions, dispatch geometry, and scoring weights. A candidate
can then improve the published points while leaving neighboring points neutral or
worse.

This is not misconduct; it is a predictable response to the reward function.
Laursen and Salter found that external search breadth and depth have distinct
relationships to innovation performance [5]. The analogous engineering lesson is
that a repository needs both deep optimization of known bottlenecks and broad
search across workload structure. Either dimension alone is insufficient.

---

## 3. Formal system model

Define an open optimization system as the tuple

```text
S = (X, W, Y, O, M, G, L)
```

where:

- `X` is the set of candidate implementation states, normally Git commits;
- `W` is the workload domain;
- `Y` is the multidimensional observation space;
- `O` is the correctness oracle and semantic equivalence relation;
- `M` is the controlled measurement protocol;
- `G` is the set of admission constraints; and
- `L` is the append-only evidence and decision ledger.

For implementation `x`, workload `w`, backend `b`, host `h`, and protocol `p`, a
benchmark observation is:

```text
y(x, w, b, h, p) =
  [T_prove, T_request, RSS_peak, device_bytes, energy,
   proof_bytes, dispatches, synchronizations, fallback_count, ...]
```

The observation is random because machine state, scheduling, compilation,
thermal conditions, allocation, and other factors introduce variation. Kalibera
and Jones show why uncertainty in performance ratios must be modeled rather than
discarded [6]. A benchmark result is therefore a distributional estimate, not a
timing scalar.

### 3.1 Candidate effect vector

For a predecessor `x_0` and candidate `x_1`, define the prove-time ratio for
workload `w_i`:

```text
r_i = median(T_prove(x_1, w_i)) / median(T_prove(x_0, w_i))
```

and the log effect:

```text
d_i = log(r_i)
```

Then:

- `d_i < 0` indicates improvement;
- `d_i = 0` indicates no movement; and
- `d_i > 0` indicates regression.

The candidate does not produce one effect. It produces the vector

```text
d(x_0 -> x_1) = [d_1, d_2, ..., d_n]
```

over the selected workload matrix. This vector is the primary representation of
change. Any scalar score is a declared projection of it.

### 3.2 Aggregate index

For positive weights `a_i` summing to one, a board may define:

```text
D = sum_i(a_i * d_i)
R = exp(D) = product_i(r_i ^ a_i)
speedup = 1 / R
```

This is the weighted geometric mean of normalized time ratios. It is
dimensionless and does not average incompatible units such as trace-row MHz,
Plonk-gate MHz, and hash-instance MHz. SPEC likewise constructs suite metrics
from ratios to reference performance rather than averaging unlike raw execution
units [7].

Aggregation is informative but not sovereign. A large gain in one coordinate
must not purchase an unacceptable regression in another.

### 3.3 Feasible region and admission

Let `C(x)` be correctness, provenance, build, protocol, and backend-integrity
constraints. Let `U_i` be the upper confidence bound for `r_i`, and `B_i` the
maximum admitted regression ratio for guard `i`. Let `theta` be the promotion
threshold derived from the floor and measured A/A dispersion.

A simplified promotion rule is:

```text
admit(x_1) iff
    O(x_1) = pass
and C(x_1) = pass
and upper_CI(R_objective) < 1 - theta
and for every guard i: U_i <= B_i
and all resource ceilings hold
```

Correctness is an **unrelaxable constraint**, not an objective that performance
can trade against. This resembles constrained black-box optimization, where the
objective and constraints are available only through costly evaluations and some
constraints invalidate the observation entirely [8].

### 3.4 Pareto interpretation

Two candidates may be incomparable. One may reduce latency but increase peak
memory; another may improve Metal throughput while leaving CPU unchanged. A
candidate Pareto-dominates its predecessor when it is no worse on every declared
objective and strictly better on at least one. Multi-objective optimization
research formalizes this non-dominated frontier rather than assuming every
system state has a natural total order [9].

`stwo-zig` should retain separate CPU, Metal, lifecycle, and heavy-workload
boards. The project may publish declared projections for decision-making, but it
must preserve the underlying vector and never imply that one scalar exhausts the
meaning of progress.

---

## 4. Multi-dimensional gradient descent, precisely stated

The gradient-descent analogy is useful because each accepted patch attempts to
move the system downhill in several performance dimensions. It becomes misleading
if interpreted literally.

Ordinary gradient descent assumes a differentiable objective `f(x)` and access to
`grad f(x)`. A codebase has neither:

- source changes are discrete and structured;
- compilation makes the response discontinuous;
- performance observations are noisy and expensive;
- the objective is a vector, not a scalar;
- the feasible region contains hard semantic constraints;
- workload coverage is incomplete; and
- interactions between optimizations are non-linear.

The closer model is **constrained, noisy, multi-objective, derivative-free
optimization**. Larson, Menickelly, and Wild describe derivative-free methods for
settings where objectives and constraints are observable only through black-box
evaluation [10].

For a candidate transformation `delta x`, the harness observes a finite response:

```text
Delta y = y(x + delta x, W) - y(x, W)
```

The coverage matrix gives `Delta y` enough structure to infer direction:

- improvement proportional to column count suggests commitment, LDE, or memory
  bandwidth leverage;
- improvement proportional to interaction density suggests accumulator or
  quotient leverage;
- improvement only below a working-set threshold suggests cache specialization;
- improvement only in warm sessions suggests amortization rather than proof-work
  reduction;
- improvement in a microkernel but not complete proofs suggests an Amdahl-limited
  direction;
- improvement at published points but not structural holdouts suggests benchmark
  specialization.

Stage profiles, hardware counters, and source attribution are therefore analogous
to a local model of the response surface. They guide the next proposal, but only
complete proof transactions determine admission.

The search loop is:

```text
observe -> hypothesize -> intervene -> verify -> measure
        -> estimate effect vector -> admit/reject -> retain knowledge -> repeat
```

This process may later use Bayesian optimization, evolutionary search, bandits,
or learned surrogates. The governance architecture must not depend on any one
search algorithm. Its job is to make reward verifiable.

---

## 5. The holistic structural coverage matrix

### 5.1 Workloads as points in structural space

Each workload is represented by a descriptor vector:

```text
z(w) = [
  log_rows,
  columns_by_tree,
  committed_cells,
  component_count,
  component_size_distribution,
  constraint_density,
  maximum_degree,
  extension_field_intensity,
  interaction_density,
  hash_intensity,
  FRI_geometry,
  working_set_bytes,
  lifecycle_class,
  security_class
]
```

The descriptor should characterize inherent proof work before it records
architecture-dependent observations. This follows workload-characterization
research that distinguishes program characteristics from the behavior of one
particular microarchitecture [11]. Backend measurements such as achieved memory
bandwidth, occupancy, dispatches, and synchronization count belong beside, not
inside, the architecture-independent descriptor.

### 5.2 Coverage dimensions

The initial matrix should span:

| Dimension | Representative regimes |
|---|---|
| Trace depth | latency-scale, throughput-scale, capacity-scale |
| Trace width | narrow, moderate, wide, extremely wide |
| Components | single, several equal, many heterogeneous |
| Constraints | sparse, mixed, arithmetic-dense |
| Interactions | none, light, moderate, lookup-heavy |
| Arithmetic | base field, extension field, bitwise, cryptographic permutation |
| Commitment | few large columns, many columns, multiple trees |
| Working set | cache-resident, bandwidth-bound, memory-capacity boundary |
| Lifecycle | cold, warm, retained-session |
| Protocol | smoke, functional, production-security |

The matrix is not the Cartesian product of every value. That would be expensive
and mostly redundant. It is a deliberately sampled design space.

### 5.3 Three workload layers

**Layer A: orthogonal diagnostic probes.** Synthetic AIRs vary one or two
structural properties while holding the rest stable. They reveal causality and
scaling behavior.

**Layer B: compositional native AIRs.** Wide Fibonacci, XOR, Plonk, state machine,
Blake, and Poseidon combine multiple prover stages in stable, reproducible forms.
They are the regression nucleus.

**Layer C: application acceptance workloads.** RISC-V programs, Cairo programs,
SN PIEs, SNIP-36, and future application traces test whether improvements survive
real component mixtures, public inputs, interactions, and statement semantics.
They become scored only after their own soundness and oracle-release gates pass.

No layer substitutes for another. Microbenchmarks explain; native AIRs compare;
real programs validate external relevance.

### 5.4 Public nucleus, adaptive shell, and hidden holdouts

The workload portfolio should contain four sets:

1. **Stable public nucleus:** fixed workloads with immutable longitudinal anchors.
2. **Parameterized public ladders:** sparse scaling points used nightly.
3. **Adaptive shell:** new points added when profiling or regressions reveal a
   missing structural regime.
4. **Judge holdouts:** deterministically generated but undisclosed challenges
   sampled from declared structural bounds.

This balances reproducibility with resistance to overfitting. Full secrecy is not
required and would damage openness. The workload-generating rules and admission
policy should be public; only the next challenge seed and exact sampled point need
remain unknown during candidate construction.

### 5.5 Representative subset selection

Fast gates cannot execute the complete matrix. They should select a minimal
covering set based on:

- paths and packages touched by the candidate;
- structural distance between workloads;
- historical sensitivity of workloads to those paths;
- the candidate hypothesis and declared objective;
- recent regressions and uncertainty; and
- a small exploration probability for under-sampled regions.

Workload-characterization research demonstrates that representative subsets can
reduce evaluation cost when similarity is based on explicit behavioral features
rather than convenience [12]. Selection must fail closed when an edited path has
no reliable impact model.

---

## 6. Saturation and renewal

A benchmark is saturated as a **search instrument** when additional optimization
against it yields little new information. It may remain highly valuable as a
regression instrument.

Evidence of saturation includes:

- repeated accepted changes with effects inside the noise floor;
- stable stage composition with no newly exposed bottleneck;
- high correlation with another workload across many candidate changes;
- poor prediction of neighboring parameter points;
- increasing specialization to constants or launch geometry; or
- loss of relevance to production workload descriptors.

Saturation triggers rotation, not deletion:

1. Retain the point and anchor in the historical record.
2. Reduce or remove its search weight only in a new declared epoch.
3. Keep it as a regression guard when inexpensive.
4. Add a neighboring, cross-dimensional, or capacity point.
5. Recompute coverage and redundancy.
6. Explain the change in the benchmark ledger.

The suite thereby evolves without rewriting history. This is analogous to a firm
renewing its external search portfolio while retaining accumulated knowledge.

---

## 7. An absorptive pipeline for inbound optimization

The repository should implement open optimization as an explicit funnel:

```text
External or internal idea
        |
        v
Cheap qualification: allowed diff, build graph, focused tests
        |
        v
Semantic admission: local verifier + pinned Rust oracle
        |
        v
Measurement: paired predecessor/candidate execution
        |
        v
Interpretation: effect vector + uncertainty + stage attribution
        |
        v
Governance: objective threshold + guards + holdout + provenance
        |
        +---- reject/neutral ---> append evidence and reusable finding
        |
        v
Promote: advance board frontier and publish attributable delta
```

### 7.1 Recognize

Stable package boundaries, contribution rules, profiler skills, and machine-
readable workload descriptors make an external idea intelligible. A patch that
cannot state which prover stage and structural regimes it expects to affect is
not forbidden, but it begins with lower prior confidence and broader guards.

### 7.2 Assimilate

Assimilation translates an implementation-specific idea into repository-owned
concepts:

- a backend-independent semantic operation;
- an owned CPU or Metal implementation;
- a proof-level invariant;
- a benchmark hypothesis;
- profiler evidence; and
- tests against the pinned oracle.

This step prevents the codebase from accumulating opaque patches whose value
cannot be reproduced or extended.

### 7.3 Apply

Application is promotion to a named frontier after independent judgment. It
requires source identity, executable identity, runtime identity, machine-local
measurement, raw evidence, and explicit outcome. The repository applies the
knowledge only after it can distinguish the contribution from environmental
drift and benchmark noise.

### 7.4 Retain

Rejected and neutral results are part of absorptive capacity. They identify dead
ends, hidden constraints, workload sensitivities, and interactions. A codebase
that stores only winning code loses most of the information produced by search.
Submission notes, stage profiles, raw reports, deltas, and reasoned verdicts form
the institutional memory of the optimization program.

---

## 8. Measurement and governance principles

### 8.1 Correctness precedes reward

The pinned Rust Stwo implementation is the final correctness oracle for shared
semantics. Zig-to-Zig agreement is necessary but cannot independently establish
parity. A candidate that fails the oracle is outside the feasible region; its
speed has no promotion meaning.

### 8.2 Pair the intervention with its predecessor

Cross-run comparison confounds code change with machine drift. Candidate and
predecessor should be rebuilt, alternated in an ABBA order, and measured in one
controlled session. The effect estimator and confidence interval operate on
paired ratios. The system should stop early only under a predeclared precision
rule.

### 8.3 Treat the environment as evidence

Host, operating system, power state, compiler, optimization mode, thread count,
Metal runtime mode, SDK, metallib or source identity, fallback telemetry, and
binary digest affect interpretation. They are part of the result rather than
unstructured notes. SPEC similarly requires disclosure and reproducibility of
performance-relevant conditions [13].

### 8.4 Separate diagnostic and promotable evidence

Kernel counters, profiler traces, source-JIT runs, three-sample checks, and
unpaired history are valuable diagnostic evidence. They must not silently become
headline or promotion evidence. Evidence classes should state exactly which
claims they support.

### 8.5 Keep regression constraints local and visible

An aggregate index alone creates a route for regressions to hide. Every affected
structural region needs a guard with an upper confidence bound. Memory, proof
size, fallback count, cold-start cost, or energy may be hard constraints or
separate objectives depending on the board, but their role must be declared
before measurement.

### 8.6 Version the meaning of progress

Changing a workload, input distribution, protocol, anchor, score weight,
measurement method, or host class changes the experiment. It creates a new epoch.
Old observations remain accessible under their original meaning and are never
silently normalized into the new epoch.

---

## 9. Threat model

The architecture must address both adversarial behavior and ordinary operator
error.

| Threat | Control |
|---|---|
| Benchmark-specific specialization | Structural ladders, generated holdouts, real-program layer |
| Correctness laundering | Independent pinned Rust oracle and challenge-bound inputs |
| Precomputed proof substitution | Bind source commit, executable, workload, public input, and judge randomness |
| Backend masquerading | Device dispatch and zero-fallback telemetry; runtime artifact identity |
| Cross-machine comparison | Board-local host anchors and paired same-session measurement |
| Thermal or temporal drift | ABBA order, cooldown policy, environment capture, run limits |
| Artifact substitution | Source, compiler, executable, and runtime artifact digests |
| Selection bias | Declared impact map, fail-closed defaults, hidden exploration samples |
| Aggregate-score gaming | Per-workload regression ceilings and full vector publication |
| Multiple unreported attempts | Submission ledger and distinction between exploration and confirmation |
| Historical revision | Content-addressed raw evidence and append-only epoch records |
| Suite ossification | Saturation tests, adaptive shell, and periodic real-workload review |

The objective is not to eliminate trust. The objective is to make each trust
assumption explicit, narrow, testable, and visible in the resulting claim.

---

## 10. Execution tiers and economic efficiency

An open system fails if evidence is so expensive that only insiders can
participate. It also fails if cheap evidence is allowed to establish strong
claims. The solution is progressive disclosure of cost:

| Tier | Purpose | Typical evidence |
|---|---|---|
| Local exploration | Generate hypotheses quickly | Microbenchmarks, profiles, tiny proofs |
| Pull-request qualification | Reject invalid candidates cheaply | Focused build, tests, public proof challenge |
| Touched-surface gate | Protect affected structural regions | Minimal covering workload subset |
| Promotion judgment | Establish causal improvement | Paired ABBA, oracle, guards, holdout, provenance |
| Nightly matrix | Detect scaling and portfolio gaps | Parameter ladders, full stage and resource telemetry |
| Periodic capacity | Validate production relevance | Largest safe traces and production-security protocol |

This design keeps the contribution boundary permeable while reserving expensive
central resources for candidates with credible prior evidence. Fork-funded
qualification can shift cost, but the central judge remains the trust root for
promotion.

---

## 11. Research propositions

The architecture creates testable propositions rather than only a design
preference.

**P1: Structural descriptors improve generalization.** Candidates selected using
descriptor-based coverage will regress fewer unmeasured neighboring workloads
than candidates selected using workload names alone.

**P2: Generated holdouts reduce specialization.** Public objectives plus hidden
structural holdouts will produce a higher correlation between promotion results
and later real-program performance than public fixed workloads alone.

**P3: Stage attribution improves search efficiency.** Contributors given proof-
stage profiles and structural response vectors will require fewer candidate
evaluations per admitted improvement than contributors given total time alone.

**P4: Negative evidence increases absorptive capacity.** Search agents with access
to structured neutral and rejected experiments will repeat fewer failed
hypotheses and discover admitted changes with fewer measurements.

**P5: Hard regression ceilings improve portfolio health.** Constrained aggregate
scoring will yield a more balanced long-run frontier than unconstrained scalar
optimization, even if its best single-workload result is lower.

**P6: Tiered evidence increases external participation.** A sub-three-minute
touched-surface qualification gate combined with centralized promotion judgment
will admit more independently authored credible candidates than a mandatory full
matrix at contribution time.

Testing these propositions requires recording not only performance outcomes but
also search attempts, workload selection, measurement cost, and later out-of-
sample behavior.

---

## 12. Implementation implications for `stwo-zig`

The formal model implies the following concrete sequence:

1. Add a versioned workload descriptor schema.
2. Describe the existing twelve native CPU and Metal guard workloads without
   changing their score.
3. Capture stage, memory, transfer, dispatch, synchronization, and fallback
   telemetry under explicit evidence classes.
4. Construct sparse depth, width, interaction, and component-topology ladders.
5. Generalize holdout generation beyond Fibonacci and Plonk parameter jitter.
6. Select touched-surface gates from declared structural coverage and historical
   sensitivity.
7. Freeze separate CPU and Metal anchors and A/A dispersion for a new epoch.
8. Publish normalized effect vectors, a declared geometric projection, and the
   worst guarded coordinate together.
9. Add saturation and redundancy analysis to nightly reporting.
10. Onboard application lanes only after their semantic and oracle gates are
    independently complete.

Issue #36 owns the executable acceptance criteria. This paper supplies the
theoretical rationale and vocabulary; it does not itself activate a benchmark
epoch or alter promotion authority.

---

## 13. Limitations

No finite workload matrix proves universal performance improvement. Structural
descriptors may omit an important latent characteristic. Holdouts reduce but do
not eliminate specialization. Paired measurement controls temporal variation on
one host but does not establish portability across host families. A weighted
aggregate imports value judgments even when mathematically well formed. Real
application traces may change over time, and production constraints may conflict.

Moreover, software performance search is path-dependent. A locally inferior
change may enable a later architecture that dominates the current frontier.
Accordingly, promotion decisions should govern the production frontier without
preventing experimental branches from preserving strategically valuable
alternatives.

Open innovation also includes outbound knowledge flows. This paper concentrates
on inbound optimization and internal assimilation. Future work should examine how
benchmark schemas, rejected hypotheses, backend abstractions, and profiler methods
can be exported for reuse without weakening security or provenance.

---

## 14. Conclusion

An open codebase is not innovative merely because it accepts pull requests. Its
innovative capacity depends on whether it can convert diverse external ideas into
validated, cumulative system knowledge.

For a high-performance prover, that conversion requires two complementary forms
of permeability:

- **architectural permeability**, through modular packages, explicit interfaces,
  reproducible builds, and accessible contribution paths; and
- **epistemic permeability**, through descriptors, oracles, experiments,
  uncertainty estimates, effect vectors, and reviewable promotion rules.

The holistic structural coverage matrix joins these forms. It makes the object of
optimization visible, turns each patch into a measured intervention, and prevents
one benchmark coordinate from defining the whole system. Autoresearch then
becomes more than automated tuning: it becomes a governed, distributed process
for discovering, testing, assimilating, and retaining performance knowledge.

In this sense, the system performs a multi-dimensional descent through a noisy
and only partially observed landscape. The contribution boundary supplies search
directions. The workload matrix supplies local shape. The correctness oracle and
admission gates define the feasible region. The evidence ledger supplies memory.
Progress is not the presence of change; it is a reproducible, admissible movement
of the frontier.

---

## References

1. Chesbrough, H. W. (2003). *Open Innovation: The New Imperative for Creating
   and Profiting from Technology*. Harvard Business School Press. See also the
   [Garwood Center definition of open innovation](https://corporateinnovation.berkeley.edu/what-is-open-innovation/).
2. Mortara, L., Napp, J. J., Slacik, I., & Minshall, T. (2009).
   [*How to Implement Open Innovation: Lessons from Studying Large Multinational Companies*](https://www.ifm.eng.cam.ac.uk/uploads/Resources/Reports/OI_Report.pdf).
   University of Cambridge Institute for Manufacturing. ISBN 978-1-902546-75-9.
3. Mortara, L., & Minshall, T. (2011). How do large multinational companies
   implement open innovation? *Technovation, 31*(10-11), 586-597.
   [doi:10.1016/j.technovation.2011.05.002](https://doi.org/10.1016/j.technovation.2011.05.002).
4. Cohen, W. M., & Levinthal, D. A. (1990). Absorptive capacity: A new
   perspective on learning and innovation. *Administrative Science Quarterly,
   35*(1), 128-152. [doi:10.2307/2393553](https://doi.org/10.2307/2393553).
5. Laursen, K., & Salter, A. (2006). Open for innovation: The role of openness
   in explaining innovation performance among U.K. manufacturing firms.
   *Strategic Management Journal, 27*(2), 131-150.
   [doi:10.1002/smj.507](https://doi.org/10.1002/smj.507).
6. Kalibera, T., & Jones, R. (2020). Quantifying performance changes with effect
   size confidence intervals.
   [arXiv:2007.10899](https://arxiv.org/abs/2007.10899).
7. Standard Performance Evaluation Corporation. (2026).
   [SPEC CPU 2026 overview](https://www.spec.org/cpu2026/docs/overview.html).
8. Audet, C., Le Digabel, S., & Rochon Montplaisir, V. (2020). Binary,
   unrelaxable and hidden constraints in blackbox optimization. *Operations
   Research Letters, 48*(4), 467-471.
   [doi:10.1016/j.orl.2020.05.011](https://doi.org/10.1016/j.orl.2020.05.011).
9. Deb, K., Pratap, A., Agarwal, S., & Meyarivan, T. (2002). A fast and elitist
   multi-objective genetic algorithm: NSGA-II. *IEEE Transactions on
   Evolutionary Computation, 6*(2), 182-197.
   [doi:10.1109/4235.996017](https://doi.org/10.1109/4235.996017).
10. Larson, J., Menickelly, M., & Wild, S. M. (2019). Derivative-free
    optimization methods. *Acta Numerica, 28*, 287-404.
    [doi:10.1017/S0962492919000060](https://doi.org/10.1017/S0962492919000060).
11. Hoste, K., & Eeckhout, L. (2006). Comparing benchmarks using key
    microarchitecture-independent characteristics. *IEEE International
    Symposium on Workload Characterization*, 83-92.
    [doi:10.1109/IISWC.2006.302732](https://doi.org/10.1109/IISWC.2006.302732).
12. Eeckhout, L., Sampson, J., & Calder, B. (2005). Exploiting program
    microarchitecture-independent characteristics and phase behavior for reduced
    benchmark suite simulation. *IEEE International Symposium on Workload
    Characterization*.
    [Author publication page](https://cseweb.ucsd.edu/~calder/abstracts/IISWC-05-PhaseWorkload.html).
13. Standard Performance Evaluation Corporation. (2026).
    [SPEC CPU 2026 Run and Reporting Rules](https://www.spec.org/cpu2026/docs/runrules.html).
