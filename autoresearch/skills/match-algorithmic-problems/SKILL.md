---
name: match-algorithmic-problems
description: Match algorithm-design tasks to canonical problems, computational models, known complexity and parameterized results, published algorithms, and maintained implementations before coding. Use before creating or replacing an algorithm for optimization, decision, search, counting, enumeration, scheduling, allocation, routing, packing, graph or constraint work, algebraic or numerical transforms, and data-structure or query problems; when considering a greedy method, dynamic program, heuristic, branch-and-bound search, solver formulation, or asymptotic performance change; or when inherited bespoke logic may duplicate a known method. Do not use for purely mechanical refactors or constant-factor tuning with no algorithmic choice.
---

# Match algorithmic problems before coding

Use problem matching as an inbound-innovation gate: recover the mathematical
task, search outside the codebase, and transfer the best applicable result back
into the implementation. Do not let current loops or names define the problem.

Apply the gate proportionally. Use a compact brief for an obvious or mandated
algorithm; use the full workflow whenever the algorithmic choice, correctness,
or performance is material. Leave pure mechanical and constant-factor tuning
to the profiling skills.

## Required output: problem-match brief

Produce this before editing algorithmic code:

```text
Task and required semantics:
Inputs, scale, encoding, and computational model:
Constraints, promises, and exploitable structure:
Candidate matches, relationship, and confidence:
Chosen canonical problem and exact variant:
Project -> canonical mapping and solution recovery:
Complexity/limits, parameters, and sources:
Prior algorithms, solvers, and implementations:
Selected transfer and rejected alternatives:
Predicted advantage, crossover, and falsifier:
Correctness and benchmark plan:
Open uncertainty:
```

For durable autoresearch findings, save the brief with
`stwo-perf notes add --title <title> --note-file <brief>`. Carry the essential
mapping, sources, and measured outcome into any submission note.

## 1. Recover the actual problem

Formalize independently of the current implementation:

- Specify whether the output is a decision, witness, optimum, count,
  enumeration, sample, approximation, or data structure supporting operations.
- Name the inputs, objective, feasibility conditions, observable semantics, and
  invariants that an implementation must preserve.
- Give production ranges for every parameter, not only one aggregate `n`.
  Record encoding size, sparsity, bounds, ordering, geometry, repetition,
  static/dynamic and online/offline behavior, and adversarial versus typical
  distributions.
- Choose the relevant cost model: bit or word-RAM complexity, comparisons,
  field/arithmetic operations, I/O or cache transfers, preprocessing/query
  tradeoffs, parallel work/span, numerical precision/stability, or wall time.
- State exactness, approximation, randomness, failure probability, latency,
  memory, preprocessing, and parallelism allowances.
- When invoking NP results for an optimization task, formulate its threshold
  decision version and state the input encoding, certificate, and verifier.

## 2. Generate and test canonical matches

Replace project vocabulary with mathematical structure and search those terms.
For example, turn “minimum conflict-free batches” into “minimum graph coloring,”
then add variant terms such as weighted, bounded-degree, online, exact, or
approximation. Search local code for prior attempts, but do not stop there.

Consider more than the first plausible family when the choice is material:
graphs and networks; scheduling, packing, covering, and matching; SAT/CSP and
integer or convex optimization; sequences, strings, geometry, and range-query
structures; streaming and sketches; polynomial, transform, and linear-algebra
algorithms; numerical methods; and parameterized or approximation algorithms.

Label each candidate relationship:

- **Exact/equivalent:** instance and solution mappings preserve feasibility,
  objectives, and observable semantics.
- **Special case:** project promises select a narrower known variant.
- **Algorithmic reduction:** transform a project instance to the canonical
  problem and recover a project solution with stated overhead.
- **Relaxation/bound:** useful for a bound or subroutine, not a complete
  solution.
- **Analogy only:** a hypothesis to test, not a classification.

Test the mapping on small boundary cases and try to construct a counterexample.
Preserve special structure: a hard general problem may become polynomial,
pseudopolynomial, approximable, or fixed-parameter tractable under the actual
bounds.

## 3. Classify without category or reduction errors

Keep four claims separate:

- **Problem/formulation:** matching, CSP, SAT, ILP, convex program, and similar.
- **Complexity/limits:** an upper bound, lower bound, completeness or hardness
  result, parameterized class, query bound, or approximation barrier.
- **Algorithmic guarantee:** exact, pseudopolynomial, parameterized,
  approximation-bounded, randomized with an error bound, numerically stable
  with an accuracy bound, or heuristic.
- **Solver technology:** constraint programming (CP), CP-SAT, SAT/SMT, MIP,
  branch-and-bound, local search, or a specialized library.

Constraint programming is not a complexity class. A SAT/MIP encoding and poor
heuristic behavior do not prove hardness. Reduction direction matters:

- Reduce **project -> canonical** to justify using a canonical algorithm.
- Reduce **known-hard -> project decision variant** to establish project
  hardness; project -> known-hard does not establish it.

Apply every complexity claim only to the precise variant and computational
model supported by its source. Reserve “NP-complete” for decision problems with
both membership and hardness established. When transferring such a result,
describe the corresponding optimization form as NP-hard rather than
NP-complete; use #P terminology for counting only when supported. Distinguish
weak from strong NP-hardness and pseudopolynomial time from polynomial time in
the input bit length.

Do not force every task into P/NP terminology. For transforms, data structures,
streaming, parallel, or numerical problems, the useful result may instead be a
time/space/query tradeoff, arithmetic or bit complexity, communication or I/O
bound, approximation ratio, or stability guarantee. If classification remains
uncertain, record competing matches and the missing proof obligation.

## 4. Research the innovation supply

When external research is permitted and internet access is available, use it
rather than relying on recalled names. Use surveys and reference works to learn
the vocabulary, then verify material complexity and algorithm claims in
original papers or official documentation. Record direct links and distinguish
established results from inference. Search exact variants, synonyms, special
parameters, “survey,” “state of the art,” and implementation or library names.

For each serious candidate, compare:

- complexity in the actual parameters, memory, guarantees, and assumptions;
- behavior on the project's structured, repeated, incremental, or parallel
  regime, including expected crossover against the current baseline;
- transferable mechanism: full algorithm, reduction, decomposition, pruning
  rule, data structure, batching strategy, or implementation technique;
- maintained implementations, language boundary, API fit, license, provenance,
  and testing evidence.

Check specialized algorithms before defaulting to a generic solver. For a hard
problem, compare exact exponential or parameterized methods at the real bounds,
solver formulations, proven approximations, and heuristics with an explicit
quality baseline. Worst-case hardness does not make every project instance
hard; a polynomial label does not make an algorithm practical.

## 5. Select a transfer, then implement

Choose only after the brief supports a decision. State what external idea will
enter the codebase, which local invariants adapt it, and why alternatives lose
at the actual scale. Make a falsifiable prediction such as an operation-count
change, asymptotic crossover, memory reduction, approximation bound, or solver
quality/runtime target.

If no match survives scrutiny, record the search and implement the simplest
correct baseline that can serve as an oracle or benchmark; do not manufacture a
classification. Reuse a maintained implementation when its license and boundary
fit. Otherwise implement the selected published method with source terminology
and citations where they aid future maintenance.

Validate with:

- a brute-force, reference, or independent-solver oracle on small instances;
- property, boundary, adversarial, and mapping-counterexample tests;
- differential tests against an existing implementation when available;
- benchmarks across representative parameters, predicted crossover points, and
  structures likely to defeat the chosen method.

After selection, use the Zig or Metal profiling skill for implementation-level
optimization. If measurements falsify the brief, revise the model or selection
instead of accumulating patches around a failed premise.
