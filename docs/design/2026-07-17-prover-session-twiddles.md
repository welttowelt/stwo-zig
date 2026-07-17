# Reusable Prover Twiddles

Status: accepted

## Performance Hypothesis

```text
Current bottleneck:
  Every proof owns a fresh PCS twiddle cache, while composition interpolation constructs another
  maximum-log tree outside that cache.
Evidence:
  Wide Fibonacci builds log N, log N+1, and a duplicate log N+1 tree per proof. CPU sampling also
  shows FFT/IFFT work, and source inspection proves the repeated construction and inversion path.
Proposed mechanism:
  Retain one immutable canonical maximum-log tower in a long-lived prover session and serve exact
  smaller-log suffix views through one TwiddleSource contract.
Expected affected stages:
  channel_and_scheme_init, main-trace interpolation/extension, composition_interpolate_and_split,
  complete prove_seconds, and sustained queue latency.
Expected unchanged stages:
  AIR semantics, transcript order, commitment roots, Merkle hashing, FRI security parameters,
  proof bytes, verification, and Metal kernel selection in the host-only increment.
Bytes/operations removed:
  Per-proof construction, allocation, and inversion of three trees for the native wide-Fibonacci
  path. At trace log 24 this replaces about 320 MiB of transient twiddle traffic with one retained
  128 MiB log-25 tower.
Memory cost:
  Exactly two M31 arrays of 2^(max_circle_log - 1) elements plus fixed metadata, rejected before
  allocation when the configured host byte budget is insufficient.
Correctness oracle:
  Exact-log tree equivalence, CPU/Metal canonical proof parity, Zig verification, and pinned Rust
  Stwo commit a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2.
Success threshold:
  Zero twiddle builds inside warm session proofs, a lower affected-class geometric-mean prove time,
  and no matrix row regression beyond the program gates.
Rollback condition:
  Any proof-byte difference, lifetime ambiguity, hidden fallback, unbounded retention, warm tree
  build, or measured geometric-mean regression.
```

## Scope

This design covers reusable host twiddles and the session boundary that owns them. It benefits both
`cpu_native` and `metal_hybrid`, because both currently generate host twiddles per proof. It does
not claim that Metal twiddles are device-resident: the generic Metal transform still uploads a
temporary twiddle buffer until the follow-on device-bank change.

FRI folding geometry, proof-request arenas, and pipeline ownership are deliberately outside this
increment. They may join the session later through separately bounded resources.

## Geometry Contract

`M31TwiddleTower` constructs one tree for
`CanonicCoset.new(max_circle_log).circleDomain().half_coset`. A request for `log` is valid when
`log <= max_circle_log`. Its view is:

```text
requested_length = 2^(log - 1)
maximum_length   = 2^(max_circle_log - 1)
suffix_start     = maximum_length - requested_length
requested_root   = CanonicCoset.new(log).circleDomain().half_coset
forward          = maximum_forward[suffix_start..]
inverse          = maximum_inverse[suffix_start..]
```

The view must equal an independently precomputed exact-log tree element for element, including the
root coset.
The exact canonical root is reconstructed instead of repeatedly doubling the maximum root: those
roots generate the same required suffix values but are not structurally identical under the Coset
metadata contract. The tower never grows or reallocates. A returned view is borrowed and valid only
while the tower is alive.

## Dataflow

```text
ProverSession
  |
  +-- owns PcsConfig and maximum supported circle log
  +-- owns immutable M31TwiddleTower
  +-- owns session telemetry
  |
  `-- Engine.initWithSession
        |
        `-- Scheme borrows TwiddleSource
              |
              +-- column interpolation and extension
              +-- composition interpolation and split
              `-- future backend resources

Compatibility Engine.init
  `-- Scheme owns TwiddleSource cache exactly as before
```

All proof code asks `TwiddleSource` for a const tree view. It does not know whether the source owns
an exact-log compatibility cache or borrows the session tower.

## Ownership And Lifetime

```text
session init ------------------------------------------------ session deinit
      |                                                            ^
      +-- tower allocation and inversion                            |
      |                                                             |
      +-- scheme A ---------------- consumed/deinitialized ----------+
      +-- scheme B ---------------- consumed/deinitialized ----------+
      `-- scheme N ---------------- consumed/deinitialized ----------+
```

- The caller owns the session and must keep it alive until every scheme and backend command that
  borrows it has completed.
- A scheme owns committed trees and request-local state. It either owns a compatibility cache or
  borrows the session tower; `deinit` distinguishes those cases.
- No proof, commitment tree, asynchronous callback, or Metal command may retain a host twiddle view
  after scheme/session teardown.
- Immutable tower reads require no lock. Telemetry counters, if mutable, use atomics and may not
  guard access to the arrays.
- Mutable scratch does not belong in the tower. Concurrent proving requires explicit request slots
  in a later change.

## Interfaces

The leaf contracts are intentionally small:

```zig
M31TwiddleTower.init(allocator, max_circle_log, host_byte_budget)
M31TwiddleTower.view(log)
M31TwiddleTower.retainedBytes()
M31TwiddleTower.deinit(allocator)

TwiddleSource.initOwned(allocator)
TwiddleSource.initBorrowed(&session.twiddle_tower)
TwiddleSource.get(allocator, log)
TwiddleSource.deinit(allocator)
```

The backend-neutral engine then exposes `Session`, `initSession`, and `initWithSession`, while the
current `init` remains the compatibility path. A session is bound to an exact `PcsConfig`, maximum
circle log, and host budget. Mismatched config or an out-of-range proof fails before input ownership
is transferred.

Composition interpolation gains a with-twiddles entrypoint and obtains its tree from the scheme's
source. This is required: reusing PCS transforms while leaving composition on the old constructor
would preserve a duplicate maximum-log build in every proof.

## Failure Contract

Initialization rejects before the large allocation when:

- the maximum log cannot be represented by `usize`;
- forward plus inverse byte size overflows;
- required bytes exceed the explicit host budget;
- the canonical coset log is invalid.

View requests reject logs above the configured maximum and arithmetic overflow. Owned-cache
allocation failures leave no partial tree. Scheme/proof error paths deinitialize owned trees and
compatibility caches but never deinitialize a borrowed tower. Session destruction with outstanding
schemes or commands is a caller contract violation and is asserted in debug telemetry where it can
be tracked without hot-path locking.

## Telemetry

The benchmark report records the stable construction contract:

- session initialization seconds;
- maximum circle log and host byte budget;
- retained host twiddle bytes;
- tower build count;
- exactly one tower build per session.

Borrowed-source tests require zero per-scheme tree builds. Session construction is included in
`backend_init_seconds`; `prove_seconds` begins after the session exists. Per-request view counts
remain local diagnostic telemetry until request-slot telemetry has an explicit aggregation owner.

## Staged Delivery

1. Add and test `M31TwiddleTower` and `TwiddleSource` without changing callers.
2. Route every PCS transform and composition interpolation through `TwiddleSource`; retain the
   owned compatibility path and prove byte identity.
3. Add `ProverSession`, engine/session entrypoints, and the session-aware native benchmark loop.
4. Run the clean three-row CPU/Metal matrix and verify all six exact artifacts with pinned Rust.
5. Profile construction counts, affected stage times, and complete proof time. Keep the change only
   if the acceptance threshold is met.
6. In a later design increment, give Metal an immutable device twiddle bank keyed to its device and
   remove temporary per-dispatch twiddle buffers and uploads.

## Test And Acceptance Matrix

- Every supported suffix equals an independently precomputed exact-log forward/inverse tree.
- Every twiddle times its inverse is one.
- Invalid log, byte-budget, overflow, and allocation-failure cases are covered.
- Owned and borrowed sources return identical views; repeated owned requests build once.
- Compatibility and session schemes produce exact identical proof bytes.
- At least two sequential proofs reuse one session without allocation leaks or new tree builds.
- Mixed-log requests within the maximum succeed; an out-of-range request fails before consuming
  trace ownership.
- Full Zig tests, source conformance, API parity, the formal CPU/Metal matrix, and six pinned-Rust
  artifact verifications pass.
- Unprofiled before/after measurement uses identical binaries, workloads, protocol parameters,
  warmup policy, lane ordering, and proof numerators.

## Acceptance Evidence

The accepted implementation is split across `3fb41ae`, `148081a`, `fd4c17f`, `d32e698`,
`ebac90b`, `7084612`, and `fc21ca9`. It supplies exact canonical suffix views, routes PCS and
composition transforms through the same source, gives the engine an explicit session boundary,
and makes the native benchmark reuse one bounded tower across every warm request.

A reversed-order ReleaseFast A/B used five warmups and 101 timed samples per process. The preserved
pre-session binary and session binary used the same functional protocol and exact workload
numerators. Values are medians; gains are `before / after - 1`.

| Backend | Workload | Before prove (ms) | Session prove (ms) | Session row MHz | Gain |
| --- | --- | ---: | ---: | ---: | ---: |
| CPU | `log10x8` | 2.236667 | 2.079250 | 0.492485 | 7.57% |
| CPU | `log12x16` | 6.350833 | 6.147333 | 0.666305 | 3.31% |
| CPU | `log14x32` | 15.483041 | 15.428041 | 1.061962 | 0.36% |
| Metal | `log10x8` | 4.640584 | 4.392000 | 0.233151 | 5.66% |
| Metal | `log12x16` | 8.369833 | 8.049834 | 0.508830 | 3.98% |
| Metal | `log14x32` | 17.093042 | 16.630833 | 0.985158 | 2.78% |

The geometric-mean prove-time gain is 3.70 percent for CPU and 4.13 percent for Metal. The retained
tower sizes are 8,192, 32,768, and 131,072 bytes respectively, all within the 256 MiB session
budget, and every report records one construction.

The clean three-row formal matrix was headline-eligible and exact across CPU and Metal. All six
emitted artifacts were accepted by pinned Rust Stwo commit
`a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`. This closes the host-twiddle increment. Device twiddle
residency, request arenas, and resident commitment epochs remain separate measured changes.
