# Defer the first RISC-V commitment tree while the pool would be idle

## Model and harness

Claude Fable 5, operating as lane MERSENNE-B, authored the mechanism, rebase,
and submission note, with CODEX ANVIL providing an independent correctness and
verdict review. The repo-resident `stwo-perf`
harness is `7efe3b1abd72`; the immutable candidate is
`fe8d8303034915e1689ec33c986be2cbe6ae1f4c` over clean current-main
predecessor `799efe87a9eccd6ae9a2e19c815e82bfbf1d4198`. The claimed result is
RISC-V `wide/time` at S3, measured ReleaseFast on a quiet Apple M4 Max Studio.
The same-host paired run admitted at load1 3.22. Every timed proof verified,
cross-arm proof digests matched, and the pinned Stark-V oracle accepted all
seven programs.

## Hypothesis

The previously promoted deferred-first-tree mechanism remained inert in the
RISC-V prover because its commitment scheme constructs an owned twiddle source,
while the deferral gate admitted only a borrowed immutable tower. That left the
worker pool idle while the locked RISC-V frontend generated the main witness.
Serializing the owned twiddle cache and resolving a pending tree before
channel-less root observation should safely overlap the first tree build with
that independent witness window without changing root-mix order or proof bytes.

## Changes

`TwiddleSource` now protects owned-cache lookup and insertion with a mutex. The
deferred first-tree gate consequently admits both borrowed and owned sources.
A pending commitment can be joined and appended before a `roots()` observer;
its root mix remains owed and is replayed at the next channel-bearing append,
before any later tree mix. Single-commit observer paths need no later channel
traffic.

The failure path is explicit. If the observer's tree append allocation fails,
the scheme clears the pending state, deinitializes the unappended tree, destroys
the joined worker slot, and returns the error. A failing-allocator test pins
that lifecycle. Spawn failure and all ineligible shapes retain the sequential
fallback.

## Results

The seven-workload portfolio ratio is **0.950958**, with deterministic 95% CI
**[0.948479, 0.952669]**, clearing theta 0.029602. All rows improve:

| workload | prove ratio | 95% CI | verified-request ratio |
| --- | ---: | ---: | ---: |
| memcpy loop | 0.960869 | [0.950025, 0.966655] | 0.971493 |
| sieve primes | 0.965140 | [0.961658, 0.969964] | 0.967985 |
| bubble sort | 0.949900 | [0.945258, 0.953044] | 0.956641 |
| Collatz | 0.945943 | [0.936243, 0.951578] | 0.950174 |
| Keccak-128 | 0.945647 | [0.944365, 0.949227] | 0.970579 |
| SHA2-128 | 0.944606 | [0.938288, 0.946958] | 0.974064 |
| SHA2-256 | 0.944829 | [0.942475, 0.947723] | 0.963381 |

G1-G5 pass. The run contains 21 measured rounds. Proof-byte ratio is exactly
1.0, peak-RSS ratio is 0.999414 with upper-CI geomean 1.002076, and energy
ratio is 0.994896. Mechanism telemetry was canonical and stable for 7/7
workloads. The 380-source test closure passed; Native CPU, Native Metal, and
RISC-V product boundaries and independent proof-identity checks were green.

## Caveats

An earlier wide attempt at the `0d7f457`-era frontier scored 0.9727 and did
not clear the then-current 0.9704 significance bar. This filing is new evidence
against a materially changed frontier after the resident quotient/FRI
promotion and subsequent commits; it is not a reroll of the old samples.

The RISC-V objective uses the established `--guards none` route because the
automatic Native guard mapping does not describe this board; the affected
product boundaries were therefore closed explicitly and sequentially. A first
Studio launcher accidentally used obsolete predecessor `2beae9d0` and candidate
`24d516b`; that result was rejected as diagnostic-only and is not included.
This package binds only the clean rerun against exact current main.

The result is a local claimed verdict, not a judged or promoted record. Only
the authenticated locked judge rerun can promote it. The separate PR6 all-cell
matrix, log22 oracle vector, both timing boundaries, and locked-M5 judged
verdict remain incomplete. **PR6 Supremacy: not achieved.**
