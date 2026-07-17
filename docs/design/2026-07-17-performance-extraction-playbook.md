# Performance Extraction Playbook and Autoresearch Harness

Status: reference methodology. Execution of the optimization loop itself — the Part B roadmap and
Parts C-E applied as tuning, and promotion runs under F.1-F.7 — is blocked by the
[pre-optimization conformance goal](2026-07-17-pre-optimization-conformance-goal.md) until its
unlock checklist is green; F.8 harness construction proceeds under that goal's allowed-before-unlock
list (benchmark-harness correctness, provenance, and immutable-evidence work; section 2.3 at the
goal's current revision). The
[backend performance program](2026-07-17-backend-performance-program.md) remains the operational
optimization plan; this document supplies the audit snapshot, the hardware and language cost
models, and the automated optimization-harness contract that the program executes against.

Nothing in this document overrides a correctness, evidence, or repository-structure rule. Where
this document and a normative contract disagree, the contract wins.

## 1. Scope

This document answers four questions:

1. Which CPU optimizations from the peer campaign
   [ClementWalter/stwo PR #6](https://github.com/ClementWalter/stwo/pull/6) exist in stwo-zig
   today, and which are deliberately absent (Part A).
2. Where the next 2-5x lives for CPU MHz, Metal MHz, and RSS (Part B).
3. What "every ounce of the hardware" means concretely for high-frequency Zig and Metal code on
   Apple silicon: the strict mechanism-level rules (Parts C, D, E).
4. How any scope of code — one loop, one kernel, one stage subtree, a whole proof, a process, or a
   sustained queue — is profiled and iterated automatically under an objective, verifiable reward
   function whose hard constraint is oracle output parity, governed end to end by one CLI that
   owns workspaces, scoring, standardized submissions with agent transcripts, promotion, and the
   Pareto-frontier ledger (Part F).

## Part A. PR #6 CPU port audit (evidence snapshot, 2026-07-17)

The peer branch is pinned at `07ea1cc` and reviewed in
[the Metal backend peer review](2026-07-17-metal-backend-peer-review.md). Its CPU campaign is the
correct comparison target for the Zig CPU backend. Audit of the working tree at `e39ada35`,
reverified at `5deb2d2a` after the Metal runtime decomposition (every cited path and mechanism
still holds):

| Peer CPU optimization | stwo-zig status | Evidence |
| --- | --- | --- |
| SIMD FFT butterflies (ifft/rfft) | Ported, full | `src/prover/poly/circle/fft_kernels.zig` packed 4-way `@Vector` pipelines with scalar tails |
| Four-lane Blake2s with word transposition | Ported, full | `src/core/crypto/blake2s_backend.zig` `compressParallel4`, `transpose4x4`; commit `98e395a` |
| Chunk-batched field inversions | Ported, full | quotient denominators (`09ed7ef`), FRI x-inverses, twiddle inverses via `batchInverse*`; scalar `powPMinus2` only inside `M31.inv` |
| Cached twiddle trees across proofs | Ported, session-scoped by design | `src/prover/session.zig`, `src/prover/poly/twiddle_tower.zig`; suffix views borrowed by PCS/composition/FRI |
| Shared FFT-basis out-of-domain evaluation | Ported, full | `fillEvalFactorsForPoint*` plus hashed `CoefficientEvalPlan` shared across same-shape columns in `src/prover/pcs/sampled_values.zig` |
| Row-parallel quotients and Merkle | Ported and extended | one persistent pool (`src/prover/work_pool.zig`); quotient-to-leaf fusion `7301925`; bounded quotient inputs `9a56af9` |
| Batched lane-parallel constraint evaluation | Not ported | composition evaluation is a scalar per-row loop; parallelism is per-component only |
| Parallel FFT layers and twiddle generation | Not ported | layers inside one transform are serial (parallelism is per-column); `slowPrecomputeM31Twiddles` is serial |
| Row-parallel FRI folds, parallel trace generation | Not ported | serial today |

The absences are recorded, not accidental: generated packed SIMD constraint evaluators are open
item 5 of the peer review's delivery order, and all new SIMD or fusion work sits on the
conformance goal's deferred-until-unlock list (section 2.4 at the goal's current revision).
stwo-zig also intentionally rejects parts of the peer design (`TypeId` backend dispatch,
host-visible FRI tree layers, manual per-AIR MSL strings, process-global caches); the peer
review's "What Not To Copy" list is the adopted design guidance (the peer review is design input,
not correctness authority).

## Part B. Where the next 2-5x lives

Baseline: the v4 native matrix (`docs/native-proof-backend-benchmark-2026-07-17.md`, Apple M5 Max,
240/240 proofs Rust-accepted). CPU runs at roughly 0.2-2.1 workload-native MHz (1.0-2.1 on the
narrow lookup-free rows; Poseidon and Blake sit at 0.2-0.9); the hybrid Metal lane is slower than
CPU on 9 of 12 rows and wins three rows at 1.15-1.17x, two of them diagnostic-only under the
timing-drift gate.

### B.1 CPU

The same-geometry peer reproduction bounds the headroom: at `2^18 x 100` the peer optimized Rust
CPU core proves in 59.6 ms against stwo-zig's 186.3 ms, roughly 3x. Ranked by measured profile:

1. Packed-lane constraint evaluation — the one unported peer item. Generate packed SIMD and Metal
   evaluators from the same authenticated AIR IR.
2. Quotient plus Merkle is still about 73 percent of prove time (56.5 percent quotient, 16.4
   percent main Merkle after session reuse). Continue the tile pipeline; sampled-value evaluation
   is the top self stack and three widening experiments were rejected — the win must come from
   coefficient and point reuse, not wider multiplies.
3. Serial residue: intra-transform FFT layers, twiddle generation, FRI folds, trace generation.
   Small individually; they bound the wide rows (Wide Fibonacci log16 is the slowest CPU row).

### B.2 Metal

The bottleneck is measured, not hypothesized: GPU execution is 13-14 percent of request latency;
a typical native proof performs 16 host Merkle fallback commits per proof in the v4 matrix
telemetry (`cpu_small_merkle_commits`, Wide Fibonacci log14; the earlier counter-enabled bounded
profile recorded 13); command waits (4.2-4.4 ms) dwarf GPU time (0.9-1.1 ms). In the repository's
ranked order:

1. Resident FRI fold-tree chains to a one-epoch FRI graph. Single-fold epoch landed (`fb4a284`,
   2.1x on the isolated transaction). SN2 targets: 17 FriRecipe waits to 10 (Stage A); the
   roughly 34 total FRI-region completion boundaries fall to 1 only at Stage C.
2. Commitment transaction batching: IFFT, fused zero-extension, RFFT/LDE, packed leaves, parents
   in one epoch. The bounded compact-commitment callsite already measured 4.92x request latency
   and an 83 percent command/wait reduction (`c0fbb7f`).
3. Remove the per-proof host Merkle fallbacks via a resident small-tree crossover, then
   producer-to-resident-Merkle so LDE output never materializes on the host.
4. GPU constraint accumulation from the generated evaluator IR.
5. Geometry: the peer's own data shows Metal beats optimized CPU only from about `2^18`-`2^20`
   rows. The timed native matrix tops out near log16 under the `2^25` committed-cell guard, so the
   Metal lane will keep losing headline rows until Cairo and SN PIE geometries are timed.

### B.3 RSS and overheads

Native-matrix peak RSS is 22-237 MiB with Metal about 2x CPU on the same row; the Cairo-scale
problem is worse (Rust Stwo-Cairo fib-2M runs at 17-18 GB peak RSS; SN PIE adaptation alone about
4.3 GB). Levers:

1. Typed resident handles from LDE directly into Merkle commitment: removes host restaging, which
   is both the RSS multiplier and part of the wait count.
2. Extend the bounded-input discipline (89 percent retained-state reduction on quotients) to trace
   generation and interaction/logup columns; Blake log12 at 236.8 MiB CPU is the outlier row.
3. Instrument before claiming: RSS is currently measured externally by `/usr/bin/time -l`; the Zig
   harness emits no allocation or peak-live-bytes telemetry and no GPU memory numbers, despite the
   telemetry contract requiring them.
4. For streaming, fixed-capacity request slots and semantically keyed bounded caches keep RSS flat
   across a 100-block queue.

## Part C. The hardware-limit model

Every optimization claim must name which wall it moves toward. On one host there are exactly four
walls, and a stage is limited by one of them at a time:

1. **Compute throughput.** Peak useful integer operations per cycle across occupied units. On an
   M-series performance core this means saturating multiple 128-bit NEON pipes with independent
   32-bit lanes; on the Apple GPU it means high occupancy at 32-wide SIMD-groups without register
   spills.
2. **Memory bandwidth.** Bytes per second from the level that actually feeds the loop. The peer
   campaign reports its FFT pass kernel marginal at ~85 GB/s on M2 Max (peer PR description, not
   reproduced in-repo); when a kernel is at the bandwidth wall, only fewer passes, smaller
   elements, or better locality help — not more ALUs.
3. **Latency chains.** Serial dependency chains (per-row modular inverse chains, hash feedback,
   pointer chasing) leave the machine idle regardless of width. The fix is always the same:
   restructure into independent lanes (batch inversion, four-lane hashing, lane-parallel
   constraint evaluation) so out-of-order and SIMD resources have parallel work.
4. **Synchronization and submission overhead.** Fixed costs per boundary: thread pool fan-out and
   join, the Metal commit-plus-host-wait round trip (~0.35 ms class per waited submission — the
   peer PR's figure, not reproduced in-repo; this repo's 4.2-4.4 ms of waits against an inferred
   13-17 boundaries is consistent with it, and per-proof wait counts are exactly the telemetry
   E.5 says the native report still lacks; submissions that are not host-waited pipeline and do
   not each pay this), page faults on first touch, allocator churn. These dominate small
   workloads and explain the entire current Metal deficit at native-matrix sizes.

The measured stwo-zig position: CPU hot stages are mostly wall 3 then wall 1 (hash rounds,
inversions, evaluation chains); the hybrid Metal lane is almost purely wall 4. RSS problems are a
wall 2 tax paid later — every needless resident byte is a future bandwidth and page-fault cost.

A useful discipline for every hot loop: write down its byte traffic per element and its
independent-operation count per element, then compare achieved throughput against the wall the
numbers predict. If a loop is far from both walls, the problem is chains (wall 3) or overhead
(wall 4), and vectorizing it further is wasted work.

Wall numbers must be measured on the host, never quoted from a spec sheet or another machine: pin
the per-host bandwidth ceiling with a checked-in STREAM-triad-style microbench (F.8 item 1 is its
home), and take compute ceilings from counter-verified peak kernels. The peer's ~85 GB/s FFT
figure is peer hardware evidence, not a target for this host.

## Part D. High-performance Zig: strict rules

Zig is not intrinsically faster than C or C++; identical machine code is identical. Zig earns its
wins from defaults and control: the whole program is one LLVM module (cross-module inlining without
LTO ceremony), `comptime` specializes code paths at zero runtime cost, illegal behavior in
`ReleaseFast` gives the optimizer the same facts C gets from UB but placed deliberately, and
allocators are explicit values. The ziggit thread
[Trouble understanding how Zig is faster than C and C++](https://ziggit.dev/t/trouble-understanding-how-zig-is-faster-than-c-and-c/6368)
reaches the same conclusion empirically: the observed 6x instruction-count gap came from
aggressive inlining of the mutex fast path, comptime format handling, and `catch unreachable`
optimizer facts — not from a magic backend.

### D.1 Build and codegen contract

- `ReleaseFast` for every measured artifact; the harness already rejects anything else.
- Target the real machine for locally consumed binaries; keep the released baseline explicit and
  separate. On aarch64, `-mcpu` baseline drift loses optional ISA extensions and the core's
  scheduling model (NEON itself is mandatory); on x86 targets it silently disables wide vectors.
- Keep hot paths free of opaque boundaries: no C ABI calls, no function pointers where a comptime
  parameter works, and no allocator calls inside loops — preallocate before the loop. Where an
  in-loop allocation is unavoidable, call the concrete arena or fixed-buffer type directly: the
  `std.mem.Allocator` interface dispatches through a vtable even when arena-backed.
- Verify codegen, never assume it: `zig build-obj -femit-asm`, `objdump -d`, and instruction/cycle
  counters. A vector claim without disassembly or counter evidence is not accepted (this repeats
  the CONTRIBUTING rule).
- Excluded avenues, so searches do not rediscover dead ends: Zig 0.15 exposes no integrated PGO;
  BOLT has no practical Mach-O support; Apple AMX is a private ISA reachable only through
  Accelerate and offers no path for M31 modular integer arithmetic; SME/streaming-SVE (M4-class)
  targets widening int8/int16 outer products that do not map to 32-bit modular multiplies and has
  no Zig support today. Revisit only when toolchains change.

### D.2 Optimizer facts

- `std.debug.assert(cond)` compiles to `if (!cond) unreachable` — in `ReleaseFast` every assert is
  an optimizer fact. Assert bounds, alignment, and nonzero lengths at loop entry so the compiler
  hoists checks and widens loops.
- `noalias` on every worker-shard pointer parameter that cannot alias. Zig does not get C's
  TBAA-derived facts, so aliasing freedom must be stated explicitly where it matters.
- `@branchHint(.likely/.unlikely/.cold)` on dispatch edges; keep the scalar-dispatch binary local —
  the rejected quotient-cursor experiment showed a 6.7 percent small-row regression purely from
  hot-path branch-body growth.
- `@setRuntimeSafety(false)` is already implied by `ReleaseFast`; do not sprinkle it, and keep
  Debug-mode safety intact for the same code.

### D.3 comptime specialization

- Monomorphize kernels on the axes that change codegen: pack width, fold count, protocol variant,
  column count class. `inline for` unrolls the ten Blake2s rounds today; the same technique
  applies to fixed constraint counts per component.
- Specialization is a budget, not a free lunch: each variant costs instruction cache. Specialize
  on few axes with measured wins; prefer one branch outside the loop over comptime-exploding the
  whole call tree.

### D.4 SIMD

- `@Vector(N, u32)` with explicit shuffles is the portable form; `PACK_WIDTH` today follows
  128-bit NEON (4 lanes). Apple performance cores execute several NEON pipes concurrently, so pair
  vector width with 2-4x independent interleaving (the FFT kernels already run four independent
  packed pipelines) to cover multiply latency.
- M31 arithmetic: keep the Mersenne reduction branch-free (`(x & P) + (x >> 31)` folded twice for
  products, plus the final compare-select into canonical `[0, p-1]` that `reduce64`/`reducePacked`
  perform — a non-canonical representative breaks equality and serialization); no divisions, no
  modulo instructions anywhere in a hot loop.
- NEON has no gather: any indexed access pattern must be restructured (bit-reversal staging
  buffers, contiguous tiles) rather than "vectorized" in place.
- Always ship the scalar tail and test the boundary; every packed kernel in the tree follows this
  shape already.
- Alignment: 16 bytes is what NEON loads need; 128 bytes (the M-series cache line) is what
  worker-shard boundaries and false-sharing-sensitive arrays need. Assert the required alignment
  at kernel entry rather than trusting the allocator.

### D.5 Memory and allocation

- SoA or bounded AoSoA layouts for field data with one scalar tail (existing rule). Do not let a
  "convenient" AoS struct enter a hot loop.
- Arena and fixed-buffer allocators per worker with byte budgets (the quotient path's 8 MiB
  scratch cap is the pattern); zero allocator traffic inside sample loops.
- First-touch page faults are real costs on 16 KiB pages: prefault or reuse large buffers across
  samples (the peer campaign overlaps CPU page prefault with GPU work).
- `@prefetch` only after a counter-verified miss profile, and re-measure; Apple cores prefetch
  streams well on their own.
- False sharing: shard worker outputs at 128-byte boundaries; never let two workers write the same
  cache line (the disjoint first-layer writers already obey this).

### D.6 Threads

- One persistent pool, coarse deterministic shards (repo rule; `work_pool.zig`). Fan-out/join is
  wall-4 overhead — batch enough work per shard that join cost is under 1 percent. Deterministic
  shards and the atomic cursor below reconcile as: chunk boundaries and reduction order are fixed
  ahead of time; only the worker-to-chunk assignment is dynamic. Size chunks so one cross-cluster
  fetch-add amortizes to noise (hundreds of microseconds of work per chunk, not tens).
- Heterogeneous clusters change the sharding math. M-series hosts run two performance levels
  (`sysctl hw.nperflevels`, `hw.perflevelN.logicalcpu` with names — older parts pair P with E
  cores; the current benchmark host reports 6 "Super" plus 12 "Performance" cores), and equal
  static shards are bounded by the slowest cluster's shard. Do not hardcode one perflevel as "the
  fast cluster": keep output indexing deterministic while distributing chunks through an atomic
  cursor so slower cores contribute without becoming stragglers, and keep reductions order-fixed
  by chunk index, not worker identity or completion order.
- macOS exposes no usable thread affinity on Apple silicon (the Mach affinity policy is a no-op on
  arm64); quality-of-service classes decide P-core vs E-core placement. Pin QoS at worker entry
  via `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)` (C import; Zig std exposes no
  QoS API), or process-wide with `taskpolicy(8)` for measurement runs — otherwise E-core
  scheduling becomes invisible noise in A/B medians.
- Determinism is part of the contract: reductions across workers must be order-fixed (the PoW
  grinder converges on the global minimum nonce for exactly this reason).

### D.7 Measurement pitfalls (CPU)

- Alternate lane order; warm up 10 times (the report contract classifies fewer as
  correctness-only); use medians with MAD dispersion; stop under thermal or memory pressure.
- Profilers lie about totals: sample-based hits rank stacks but exclude idle waits; a profiled
  median is never a headline number (evidence-class rule).
- On macOS use `xctrace`/Instruments counters; Linux tools (`perf`, `poop`) do not exist here.
  Wall-clock alone cannot distinguish wall 1 from wall 3 — capture instructions-per-cycle.
- `os_signpost` intervals (C import of `os/signpost.h`) let the existing stage tree annotate the
  Instruments timeline so counter captures attribute to named stages; `powermetrics` reports
  per-cluster frequency and residency, which is the practical thermal-throttle detector during
  A/B runs (and the energy source for the F.6 ledger and F.8 item 8).
- Cache and TLB topology beyond the line: each M-series cluster shares one L2, so tile working
  sets to the per-cluster L2 (measure the size; it varies by family), not just to cache lines.
  On 16 KiB pages with no user superpages, LDE-scale buffers exceed TLB reach — sustained
  page-walk pressure shows up in counters as backend stalls, and buffer reuse across samples is
  the mitigation, same as for first-touch faults.

## Part E. Metal on Apple silicon: strict rules

The current Metal deficit is synchronization, not kernels; the rules are ordered accordingly.

### E.1 Submission economics

- A command buffer commit plus host wait costs ~0.35 ms class overhead per waited submission
  (peer figure; see Part C for its provenance caveat); the native matrix spends 4.2-4.4 ms in
  waits against 0.9-1.1 ms of GPU work. Rule: one command buffer per transcript barrier; the only
  legitimate host waits are transcript observations.
- For repeated round structures (the FRI fold/tree/transcript chain), indirect command buffers
  let the round graph be encoded once and re-dispatched with updated arguments, cutting per-round
  CPU encode cost; evaluate them at Stage B/C when the round boundary stops being host-visible.
- Use the right dependency mechanism for each scope, never `waitUntilCompleted`: within one
  encoder, a serial dispatch type orders dispatches automatically while
  `MTLDispatchTypeConcurrent` requires explicit `memoryBarrierWithScope:` at dependency edges;
  across encoders in one command buffer, automatic hazard tracking covers tracked resources and
  `MTLFence` covers untracked/heap resources; across command buffers, queue commit order covers
  one queue and `MTLEvent` covers cross-queue GPU-GPU ordering.
- Prefer one concurrent-dispatch encoder per epoch phase with barriers only at true dependency
  edges (for example, between FFT layers): this overlaps independent dispatches with tracked
  resources today and removes per-dispatch encoder churn; untracked heaps plus fences extend the
  same overlap across encoders once arena plans own residency.
- Encode ahead: while the GPU executes epoch N, the CPU encodes N+1 (double-buffered epochs) —
  applicable to the streaming queue once single-request ownership is stable. Replace
  `waitUntilCompleted` with `addCompletedHandler:` wherever the host merely needs to know, not to
  block.
- `MTLSharedEvent` is specifically for host participation without a spin (listener notification
  or timed wait); use it for the transcript-mix boundary when Stage B (resident channel) lands.

### E.2 Residency and memory

- Unified memory: `storageModeShared` zero-copy is the default for host-visible data. Wrapping a
  host allocation with `newBufferWithBytesNoCopy:` requires a 16 KiB page-aligned pointer, a
  length that is a multiple of the page size, and an allocation that outlives the buffer;
  Metal-allocated shared buffers need no caller alignment. `storageModePrivate` for tree layers
  and intermediates the host never reads (the resident Merkle trees already do this).
- Suballocate from `MTLHeap`s per arena plan; heap resources default to untracked, so cross-encoder
  dependencies use `MTLFence`. Concurrent-dispatch encoders with tracked resources are step one;
  untracked heaps plus fences are step two. Heap placement also enables aliasing: transient epoch
  intermediates (packed-leaf scratch, fold temporaries) whose lifetimes are disjoint in the arena
  plan can share heap ranges — this is the direct Metal lever on the roughly 2x RSS gap in B.3.
  On macOS 15+, register arena heaps in an `MTLResidencySet` attached to the queue so residency
  is declared once, not per command buffer.
- Never read back full layers: 32-byte roots and requested openings only (existing contract).

### E.3 Pipelines and specialization

- AOT `metallib` plus binary archives; production rejects source JIT (conformance rule). PSO
  creation is startup cost, tracked by the preparation-phase telemetry.
- Function constants are the Metal analog of `comptime`: specialize kernels per protocol variant,
  fold count, and width class at pipeline build, not with runtime uniform branches.
- Set `maxTotalThreadsPerThreadgroup` on the descriptor so the compiler allocates registers for
  the real shape; `threadExecutionWidth` is 32 on Apple GPUs — make threadgroup widths multiples
  of 32 and let `dispatchThreads:` handle ragged grid edges.

### E.4 Kernel rules

- Threadgroup memory is capped at 32 KiB on current Apple families; the peer's FFT uses exactly
  one 32 KiB tile with 1,024 threads. Validate per device family instead of hardcoding.
- Occupancy is register-bound. If a kernel spills, first lower the declared
  `max_total_threads_per_threadgroup` so the compiler widens per-thread register allocation (the
  post-compile `pipeline.maxTotalThreadsPerThreadgroup` is the pressure signal available without a
  trace); split the kernel only if spills persist at acceptable occupancy. On M3-class dynamic
  caching families, re-measure — do not port folklore.
- Coalesce: consecutive threads read consecutive 4-byte words; the SoA plane layout is as
  mandatory on GPU as on CPU.
- Exploit the 32-lane SIMD-group: execute FFT butterfly strides 1-16 with `simd_shuffle_xor`
  (barrier-free, no threadgroup memory traffic) and reserve the threadgroup tile for strides of 32
  and above; the same primitive serves intra-SIMD-group transposition in packed Blake2s leaves.
  Use SIMD-group reductions for small tree levels; the accepted parent-tail shader (one
  threadgroup reduction replacing seven dependent dispatches, 0.201 to 0.120 ms) is the template.
- 16-bit types raise occupancy but do not apply to M31/QM31 arithmetic; they are for indices and
  flags only, and only with parity tests.

### E.5 Metal measurement

- Counter sample buffers give per-encoder GPU time; the command timeline gives buffers, encoders,
  and waits. Both are already in the telemetry contract; the gap is that the native matrix report
  does not yet carry command-buffer/wait counts — wire that first (allowed under the lock).
- For GPU-targeted hypotheses, G3's wall evidence comes from the GPU profiler's
  performance-limiter and occupancy counter sets (ALU limiter, memory limiter, occupancy), not
  from time alone; without them a GPU wall-1/wall-2 claim cannot satisfy mechanism binding.
- Rank by: host waits, then command buffers, then GPU duration, then per-kernel time. A kernel
  optimization is not accepted from encoder counters alone (repo rule: encoder-count reduction is
  insufficient).
- GPU time under 15 percent of request latency means kernel tuning cannot move the whole-request
  number (an Amdahl bound near 1.17x); rank it below submission work at that scope. This does not
  forbid kernel changes that remove dispatches or waits (the parent-tail shader is exactly that),
  it must be re-evaluated after every wait-reduction landing because wait removal raises the GPU
  share, and under pipelined streaming the binding ratio is GPU busy time over wall time, not over
  single-request latency.

## Part F. The autoresearch harness

Goal: any scope of code can be attached to an objective, machine-verifiable reward and improved by
an automated loop (a person, a script, or an agent proposing patches) without ever being able to
"win" by breaking correctness, measuring the wrong thing, or gaming the benchmark.

The delivery shape is a CLI-governed promotion workflow modeled on the
[ecdsafail-challenge](https://github.com/ecdsafail/ecdsafail-challenge) harness: one CLI owns
everything from the start of an optimization search to result submission; the harness — not the
searcher — is the source of truth for scores; promoted submissions become commits on the default
branch; and every submission carries a standardized note plus the redacted agent transcripts that
produced it, in the style of the
[openclaw agent-transcript skill](https://github.com/openclaw/openclaw/tree/main/.agents/skills/agent-transcript).
The harness is the primary value: it records what the searcher did, runs the suite, computes the
verified delta, and appends promoted deltas to an append-only ledger from which the Pareto
frontier is tracked.

### F.1 The reward function

For a candidate change `c` at scope `S` over workload set `W`:

```text
R(c) is defined only if ALL hard gates pass; otherwise the candidate is rejected, not scored.

Hard gates (constraint set, all machine-checked):
  G1 conformance: canonical proof bytes byte-identical to baseline where the protocol is
     deterministic; otherwise transcript-equivalent with cross-verification; pinned Rust oracle
     accepts the exact timed artifact for oracle-bound workloads.
  G2 identity: statement digest, protocol parameters, backend identity, and workload digests
     unchanged; no workload-name or size-special-case branching introduced.
  G3 mechanism binding: no new silent fallback, and the hypothesis's targeted wall must show its
     wall-appropriate evidence: wall 1/3 — instructions retired and IPC on the targeted stage;
     wall 2 — bytes moved or fault counts; wall 4 — wait/dispatch/allocation counts. The observed
     mechanism delta must be quantitatively consistent with the prediction (same sign, within a
     stated factor), not merely nonzero; a time delta whose magnitude the observed mechanism does
     not explain is rejected.
  G4 budgets: peak RSS, cache entries, handles, threads, and busy-wait/thread-count policy within
     declared bounds; per-cluster active residency recorded so wall-time wins bought with burned
     energy are visible.
  G5 environment: ReleaseFast, clean tree or recorded dirty state, designated judge host under
     the judge lock, pre-flight thermal/idle check passed. (The adaptive sample rule is a
     validity condition of the Score block itself, not a pre-gate.)

Score (only after gates, judged runs only):
  The judge rebuilds the named predecessor AND the candidate and interleaves them ABAB (or
  randomized) in one session, discarding the first pair. r_i is the paired per-sample ratio
  estimate (Hodges-Lehmann) for workload w_i; frozen baseline reports are provenance, never the
  denominator of a judged score.
  R(c) = geometric_mean(r_i)        (lower is better)
  Significance: sample until the bootstrap 95% CI half-width of r_i is below theta/2 or the
  per-workload wall-clock cap is hit (then the verdict states the achieved minimum detectable
  effect and promotion requires improvement beyond it). theta = max(1%, 2x the judge's measured
  run-to-run dispersion for that workload class).
  Declared objective: a (workload class, dimension) pair named in the hypothesis and note.md —
  the dimension is time, peak RSS, or (once mandatory) energy, and r_i is the paired ratio on
  that dimension's rung observable, so a time-neutral RSS reduction is promotable on the RSS
  dimension under the same significance rule.
  Promotion threshold: the CI of the declared-objective r_i must lie entirely below 1 - theta.
  theta's dispersion term is the A/A paired-ratio CI half-width measured per workload class per
  harness epoch and recorded in the ledger, so every judge computes the same bar.
  Results inside the neutral band are recorded as confirmed-neutral: no promotion, no re-freeze.
  Near-threshold winner's-curse control: a promotion whose CI upper bound sits within theta/2 of
  the bar requires one independent confirmation re-run in a fresh judge session before it lands.
  Guards: regression allowances are budgets against the frozen pre-optimization anchor (the
  conformance goal's baseline-freeze phase — Phase 4, section 10, at the goal's current
  revision), not the predecessor — after any promotion no (workload, dimension) cell may sit
  worse than anchor x 1.05 (targeted class: anchor x 1.02) without an explicit human-signed
  re-anchor row.
  Tie-breakers, in order: peak RSS ratio, energy, wait count, dispatch count, proof bytes
  unchanged.
  S0/S1 rungs use instruction/cycle counters as the primary observable (near-zero dispersion);
  wall time is secondary there.
  Rung protocol variants: ABAB interleaving in one session applies at S1-S3. S4 cold starts
  cannot interleave after warmup — use randomized run order across fresh sessions with the same
  paired-ratio estimator. S5 uses alternating long blocks with block-level pairing, and drift
  gates apply within each arm.
```

Gate failures reject rather than score — a shaped penalty on correctness would make the oracle
negotiable — but the verdict JSON reports per-gate margins (for example, RSS over budget by 12
percent) as non-reward diagnostics, so a searcher gets direction without the reward bending.

This extends and tightens the acceptance logic the performance program applies by hand today —
the program's per-change 2/5-percent gates become anchored cumulative budgets with a significance
requirement, and the program's gate text is updated to match when the harness is adopted. The
harness contract makes the whole judgment a single machine-readable verdict so an automated
searcher can iterate on it. A searcher's locally computed R is always a claimed score: promotion
re-runs the evaluation on the judge side and only the judged verdict counts (F.5).

### F.2 The scope ladder

Each rung has an observable, a parity oracle, and an existing repo primitive. A change is accepted
only at the rung where its user-visible claim lives; inner rungs are for iteration speed.

| Scope | Observable (reward numerator) | Parity oracle | Exists today |
| --- | --- | --- | --- |
| S0 instruction/loop | cycles, instructions, IPC from counters; disassembly | exact output vectors | manual (`-femit-asm`, Instruments); no checked-in microharness |
| S1 kernel/function | ns/op over pinned inputs, bytes/s | golden vectors incl. tails/boundaries | partial: `src/bench/kernels.zig`, microbenchmarks in design docs |
| S2 stage subtree | stage seconds from the stage tree | stage output equality vs CPU/Rust checkpoint (accumulators, roots, transcript state) | `src/prover/stage_profile.zig`; per-component oracle checkpoints |
| S3 proof transaction | prove/request seconds, native MHz | canonical proof bytes + Zig verify + pinned Rust receipt | v4 matrix controller (authoritative) |
| S4 process | process seconds, cold vs warm split, peak RSS | same as S3 plus lifecycle checks | controller + `/usr/bin/time -l` |
| S5 sustained queue | proofs/s, tail latency, retained bytes, drift | per-proof verification + ordered publication + reset gates | streaming harness (Cairo side); gates specified, not yet green |

Iteration runs bottom-up (S0/S1 loops are seconds, S3 is minutes), but acceptance always re-runs
the top rung the claim touches — and rung assignment is mechanical, not self-declared: the
editable-paths manifest maps each path to a minimum acceptance rung, and the judged rung is
max(declared rung, highest rung mapped to any touched path). Changes touching session, pool, or
cache-lifetime paths map to S5 once its gates are green, S4 until then. A kernel 2x at S1 that
moves S3 by nothing is recorded and closed, not merged — the rejected-experiment entries in the
performance program are the precedent.

### F.3 The CLI-governed loop

One CLI (working name `stwo-perf`; per repository rules a thin executable root over owned modules)
governs the search from workspace creation to submission. Command surface, mirroring the reference
workflow:

```text
stwo-perf benchmark            show the fixed suite, scopes, gates, and current frontier
stwo-perf clone <dir>          create a searcher workspace: worktree checkout, local config,
                               setup, and one baseline run
stwo-perf setup                verify toolchain, oracle binary pins, and build dependencies
stwo-perf run [--scope s1..s5] [--class small|wide|deep]
                               build the candidate, run the reward evaluation, print the
                               verdict JSON; inner rungs iterate fast, S3+ is acceptance
                               (S0 is manual-only: disassembly and counter capture outside
                               the CLI, per F.2)
stwo-perf submit --note-file note.md --model "<model>"
                               package the candidate (editable-path diff, note, transcripts,
                               verdict) and hand it to the promotion judge
stwo-perf submissions [--all]  list submissions with their judged verdicts
stwo-perf submission-note <id> print a submission's note
stwo-perf notes add|list|search
                               standalone working notes: approaches, failures, context
stwo-perf sync                 fast-forward the workspace to the current promoted frontier
stwo-perf reset <id>           restore editable paths from a named promoted submission
stwo-perf frontier             print the promotions ledger and the current Pareto frontier
```

`sync` and `reset` restore only manifest editable paths while keeping harness files at the
default-branch tip, and both refuse a dirty worktree without `--force`. Searchers are expected to
re-check the frontier periodically — a submission that no longer beats the promoted best is
rejected, and the correct response is `sync` then continue from the frontier, not iterate on a
stale baseline.

The iteration protocol inside a workspace is unchanged from the repository's manual discipline:

```text
1. FREEZE    baseline: immutable report + binary/artifact digests (benchmark_history + delta
             files). Frozen artifacts serve delta.json and provenance only — they are never the
             denominator of any score; local runs use the same paired two-arm protocol as the
             judge (F.1)
2. ATTRIBUTE profile at the highest scope showing the cost; descend until the mechanism is visible
3. HYPOTHESIZE  one sentence: mechanism, wall (compute/bandwidth/chain/overhead), predicted
                telemetry delta, predicted reward delta, and the declared objective
                (workload class, dimension)
4. CHANGE    one bounded change inside editable paths only
5. SCORE     `stwo-perf run` on an inner rung (fast reject), then the acceptance rung (S3 floor,
             raised by the touched-path rung map), full gates
6. RECORD    `stwo-perf notes add` for the approach and outcome — rejections are recorded with the
             same rigor as acceptances; they prune the search space for every later searcher
7. SUBMIT    `stwo-perf submit` when the acceptance rung clears the threshold; on promotion the
             named-predecessor pointer advances to the new HEAD — the Phase-4 drift anchor never
             moves; goto 2
```

The repository already runs this loop manually with high discipline (every entry in the
performance program names its commit, mechanism, A/B protocol, and oracle receipts). The
automation gap is packaging, not method.

### F.4 Workspace and editable paths

A checked-in manifest declares `editablePaths` — the kernel, prover, and backend sources a
searcher may modify, each mapped to its minimum acceptance rung (F.2) — plus the workload
registry that pins W: the benchmark suite composition and the `--class small|wide|deep` taxonomy
are manifest data, not CLI convention. Everything else is locked: the harness, controllers, oracle pins,
vectors, baselines, report schemas, the promotions ledger, and this contract. The build graph is
locked too: `build.zig`, `build.zig.zon`, target and CPU flags, and the harness-owned QoS and
thread-count policy — a build-graph change is a maintainer change that re-anchors baselines, not
a submission, because an edited flag is a global codegen change laundered as a kernel patch.
QoS or thread-policy calls added inside editable sources are the same laundering vector; the
source-conformance checker carries a pattern check for them, and judged runs record the QoS
class and thread count observed (G4). This
is the reference workflow's central mechanism (there, only `src/point_add/` is editable and the
simulator/scorer are immutable), and it is what makes the reward unforgeable rather than merely
reviewed. Enforcement is mechanical twice over: the source-conformance checker walks the tree, and
the judge diffs every submission against the manifest and rejects any locked-path touch.

The benchmark evolves through the normal git repository: a promotion lands on the default branch
through the repository's standing PR and review discipline — the judge opens the PR with the
submission note as its description and the verdict attached, and CONTRIBUTING's disclosure and
human-review requirements apply unchanged; the harness automates measurement and evidence, never
the review. A searcher reads recent promoted commits, submission notes, and the ledger to learn
what won, what was tried, and what failed — the performance program's accepted and rejected
experiment entries are exactly this record today, kept by hand.

### F.5 Submission and promotion

A submission is a directory with a standardized shape, validated by `submit` (its repository home
is decided at implementation alongside the manifest; the shape is the contract):

```text
submissions/<utc-date>-<slug>/
  note.md          standardized public note (schema below)
  verdict.json     the local acceptance-rung verdict from `stwo-perf run`
  delta.json       immutable delta against the named predecessor baseline
  transcripts/     redacted agent session transcripts for the work that produced the change
```

`note.md` requires these sections, in order, and `submit` rejects a note missing any of them:

1. **Model and harness** — the AI model(s) and any coding-agent or autoresearch harness used.
2. **Hypothesis** — mechanism, targeted wall, predicted telemetry delta.
3. **Changes** — files touched, what changed, why.
4. **Results** — judged-rung reward, per-workload ratios, telemetry deltas, peak RSS.
5. **Caveats** — failed variants along the way, known limits, anything the next searcher needs.

Notes are public to the team and capped small (the reference workflow uses 10 KiB); they exist so
a human reviewer or a later agent can reconstruct the reasoning without replaying the session.

Transcripts follow the agent-transcript discipline: preserve user prompts, assistant decisions,
tool summaries, and test outcomes; drop system prompts, raw tool output dumps, reasoning traces,
environment values, tokens and secrets, and broad local paths; fail closed when a secret pattern
is detected. A submission whose session logs cannot be captured says so explicitly in the note
rather than shipping an empty directory.

Promotion criteria — strict, all required:

1. The judge re-runs the acceptance rung itself with the paired protocol of F.1 (rebuild both
   arms; rung-appropriate interleaving). If the named predecessor is no longer the promoted HEAD,
   the judge pairs the candidate against the current HEAD and the stale predecessor is provenance
   only. The submitter's claimed score is advisory, and a claimed/judged divergence beyond the
   judged CI is itself a recorded finding.
2. All hard gates G1-G5 pass on the judge's run.
3. The declared objective clears the significance threshold of F.1 against the current promoted
   HEAD; confirmed-neutral and regressing results do not promote, including when another
   submission was promoted while this one was in flight.
4. No locked path is modified; the note schema is complete; transcripts are present or their
   absence is declared.
5. The judged result — never the claimed one — is appended to the ledger, and the promotion
   lands as a default-branch commit through the normal PR review discipline (F.4).

Judge environment: judged runs execute on a designated runner host recorded in the ledger row,
under a host-wide judge lock that `stwo-perf run` (searcher or judge) refuses to violate — no
searcher iterates on the host while a judgment executes. Pre-flight gates: thermal pressure
nominal, idle CPU above a stated floor, no other harness process; the verdict records the
pre-flight snapshot and per-cluster frequency residency for both arms, and the run is void if the
arms' residencies differ beyond a stated band. This closes the cold-submit and judge-warming
games in one rule.

A rejection is recorded with its reason and its note. Rejected approaches are search-space pruning
for every later searcher; `notes search` makes them discoverable.

### F.6 The promotions ledger and Pareto frontier

`vectors/reports/promotions.tsv` will be the append-only ledger (the reference workflow's
`results.tsv` analog; F.8 item 6 builds it). One row per judged submission: `schema_version`, `harness_commit`, UTC
timestamp, repository commit, scope, workload class, judged R with its CI, per-dimension medians
(prove ms per workload, workload-native MHz, peak RSS, wait count, dispatch count, energy joules —
captured mandatorily even while ungated), gate results, hold-out pass/fail, and the submission
reference. Only the judge appends — enforced, not assumed: the ledger path is locked to
searchers, branch protection requires ledger-touching commits to come through judge-opened PRs,
and a CI check verifies each appended row's digest matches a judge verdict artifact. CI itself
never writes the ledger; history is never rewritten — a correction is a new row that names the
row it supersedes.

Harness changes open epochs: any change to measurement, scoring, or gate code bumps the harness
version, requires the judge to re-run the anchor and the current HEAD under the new harness, and
starts a new epoch; ratios are never compared across epochs, and old rows are read per their own
`schema_version`, never defaulted.

The frontier is computed, not asserted. Per workload class, the comparison point is the current
promoted HEAD's judged vector, and promotion requires the candidate to clear the F.1 significance
threshold on its declared objective while remaining non-dominated after inflating each candidate
dimension by that dimension's judged noise margin. The tracked vector is (time, peak RSS) until
energy capture is mandatory everywhere; rows missing a tracked dimension are excluded from
dominance, never treated as zero. Cumulative drift is bounded by the anchor budgets of F.1:
`stwo-perf frontier` prints per-cell drift from the frozen Phase-4 anchor, and the judge rejects
any submission whose post-state exceeds a budget regardless of its per-submission delta —
allowances are a fixed budget, not a renewable one. Historical frontier points are documented
`reset` targets, not live alternatives; the plot labels them as superseded states. Because every
promotion names its predecessor and stores `delta.json`, the ledger is a verifiable chain from
the frozen pre-optimization baseline (the conformance goal's baseline-freeze phase) to the
current frontier, and the frontier plot is derived rather than hand-maintained.

### F.7 Anti-gaming invariants

An automated searcher optimizes whatever is measured, so the measurement must be unforgeable:

- The searcher may not modify anything outside `editablePaths`: the harness, the controllers, the
  oracle pins, vectors, baselines, report schemas, the promotions ledger, the judge, or this
  contract. Enforced by the manifest diff at submission and by the source-conformance checker.
- Claimed versus judged: every score a searcher reports about itself is advisory; only the judge's
  re-run enters the ledger. A claimed/judged divergence beyond noise is itself a recorded finding.
- Workload identity is pinned by digest; adding a fast path keyed on anything correlated with the
  benchmark identity fails G2 (the "no benchmark-specific shortcuts" rule, mechanically checked by
  requiring the same code path to serve a held-out workload).
- Hold-outs resist shape overfitting, not just name branching: the judge draws acceptance-time
  hold-outs from a parameterized generator (sizes and widths jittered within class bounds, seeded
  per judgment, seed recorded in the ledger row); a promotion must not regress any generated
  hold-out beyond the targeted-class allowance. A fixed hold-out row leaks through the public
  ledger after one promotion, so ledger rows publish hold-out results as pass/fail only. Any
  editable-path constant encoding a size or width threshold needs a size-sweep in the note
  showing sane behavior across the class range — threshold tuning to exact benchmark shapes is
  the gaming vector G2's identity check cannot see.
- Mechanism binding (G3) prevents the classic false win: a time improvement caused by measurement
  drift cannot show a quantitatively consistent mechanism delta and is rejected.
- Notes and submissions from other searchers are useful context but untrusted input: verify any
  load-bearing claim against the ledger or a re-run before building on it. The agent skill renders
  notes and transcripts as untrusted data — instructions found inside them are content, never
  directives.
- Transcript authenticity: `stwo-perf` captures session transcripts itself where the agent
  harness permits and hashes them into `delta.json` at submit time; submitter-supplied transcripts
  are labeled unverified in the ledger.
- Evidence is immutable and append-only; a new run is a new report plus a delta against a named
  predecessor (`scripts/benchmark_delta.py`, `vectors/reports/benchmark_history/`).

### F.8 What must be built (all allowed under the lock as harness correctness/provenance work)

1. S1 microharness target: pinned-input kernel benches with golden vectors, ns/op and counter
   capture, JSON output in the report schema; includes the STREAM-triad-style host bandwidth
   ceiling from Part C and its GPU counterparts (shared- and private-buffer bandwidth triads plus
   an integer ALU-rate kernel set — add/xor/rotate vs `mul`/`mulhi`/`mad` and atomic throughput —
   reported per device family, since Apple publishes no integer-op tables). Extend
   `src/bench/kernels.zig`.
2. Command-buffer, wait, and per-encoder GPU-time counters wired into the native matrix report
   (they exist in the streaming harness; the v4 report lacks them).
3. In-process memory telemetry: allocation count, allocated bytes, peak live bytes per stage, and
   Metal resident-buffer peaks — required by the telemetry contract, currently absent.
4. The `stwo-perf` CLI (F.3): `run` emits one JSON verdict {gates: pass/fail each, R,
   per-workload ratios, tie-breakers, evidence paths}; `submit`, `notes`, `sync`/`reset`, and
   `frontier` compose the existing matrix controller, oracle runner, `benchmark_delta.py`, and
   `benchmark_history` rather than reimplementing them.
5. The manifest (F.4): `editablePaths` with per-path minimum acceptance rungs, the pinned
   workload registry and class taxonomy, the judge-side locked-path diff check, and the held-out
   generator parameters (F.7).
6. The promotions ledger and frontier computation (F.6), seeded from the frozen pre-optimization
   baseline the conformance goal's baseline-freeze phase produces (Phase 4 at the goal's current
   revision).
7. Repo-local agent skills so any coding agent picks up the workflow: a `stwo-perf` CLI usage
   skill and an agent-transcript capture skill (redaction rules of F.5), installable via
   `stwo-perf install-skill`.
8. Energy capture per judged run via `powermetrics` sampling — capture is mandatory from the
   first ledger row (F.6) even while energy remains ungated and tie-breaking only; joules often
   expose overhead that wall time hides on a busy host, and retrofitting the column later would
   split the ledger into epochs for no reason.

## Part G. Sources and review provenance

Repository evidence: the documents and reports named inline, principally the backend performance
program, the PR #6 peer review, and the v4 native matrix report with its history index.

External sources consulted:

- [ClementWalter/stwo PR #6](https://github.com/ClementWalter/stwo/pull/6) — peer campaign,
  results tables, and submission-overhead/bandwidth notes.
- [ziggit: Trouble understanding how Zig is faster than C and C++](https://ziggit.dev/t/trouble-understanding-how-zig-is-faster-than-c-and-c/6368)
  — empirical mechanisms: whole-program inlining, comptime formatting, `catch unreachable`
  optimizer facts, instruction-count and branch-miss deltas, benchmarking pitfalls.
- Apple: [Learn performance best practices for Metal shaders](https://developer.apple.com/videos/play/tech-talks/111373/),
  [Optimize Metal Performance for Apple silicon Macs](https://developer.apple.com/videos/play/wwdc2020/10632/),
  [Metal Compute on MacBook Pro](https://developer.apple.com/videos/play/tech-talks/10580/) —
  threadgroup memory, occupancy/register guidance, 16-bit type occupancy effects, and
  family-specific (M3 dynamic caching) tradeoffs.
- [ecdsafail-challenge](https://github.com/ecdsafail/ecdsafail-challenge) — the reference
  CLI-governed benchmark workflow: locked harness with `editablePaths`, judge-side re-run,
  mandatory public submission notes, append-only `results.tsv`, promotion as default-branch
  commits, and frontier syncing.
- [openclaw agent-transcript skill](https://github.com/openclaw/openclaw/tree/main/.agents/skills/agent-transcript)
  — the redaction and consent discipline for attaching agent session transcripts to submissions.

Command validation: during review round four,
`zig build native-proof-bench-cpu -Doptimize=ReleaseFast` followed by a bounded
`wide_fibonacci --log-n-rows 10 --sequence-len 8 --warmups 2 --samples 3` run was executed on a
busy development host with a dirty tree. The harness behaved exactly as this document describes
its contract: it emitted a schema-4 report, classified the run `correctness_only`, refused every
headline MHz field (sampling contract and provenance unmet), and still verified three byte-identical
proofs. That run is command validation only — it is not a performance datapoint, and its numbers
appear nowhere in this document.

This document was drafted from the 2026-07-17 audit and revised through five independent review
rounds, each by a reviewer with no stake in the draft: Zig technical accuracy (verified against
the installed Zig 0.15.2 toolchain and this host); Metal/Apple-silicon accuracy (verified against
Apple documentation and the runtime source); harness and statistics rigor (which found and fixed
the noise-ratchet, unpaired-baseline, and compounding-allowance defects in the original reward
design); repository alignment (verified 25 of 28 quoted numbers exactly against their sources and
re-pinned the rest); and a final adversarial completeness pass. All accepted findings were
applied inline before installation.
