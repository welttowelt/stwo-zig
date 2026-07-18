---
name: zig-profiling
description: Isolate Zig code into a scratch harness and profile it with in-process hardware counters (instructions, cycles, IPC, energy), stack sampling, codegen summaries, and ABBA A/B comparison via the stwo-perf statistics. Use for any CPU performance question — finding inefficiency and redundancy, verifying vectorization claims, attributing cost to compute vs memory vs dependency chains vs overhead — before touching prover code.
---

# Zig profiling for autoresearch

The tool is `autoresearch/cli/stwo-prof` (`zig` lane). It exists so every CPU
performance claim is measured, attributed, and compared — never vibed. The
reward loop is data-driven design: counters decide, opinions don't.

## The loop

```bash
stwo-prof zig isolate <name> [--from file.zig]   # scratch dir outside the repo
# edit ~/.cache/stwo-prof/<name>/workload.zig     (contract in the header)
stwo-prof zig run <name> --iters N               # counters: ns/op, instr/op,
                                                 # cycles/op, IPC, energy, RSS
stwo-prof zig asm <name>                         # codegen: instrs, NEON share
stwo-prof zig sample <name>                      # stacks for larger workloads
stwo-prof zig compare <a> <b>                    # ABBA A/B with bootstrap CI
```

Counters come from `proc_pid_rusage` deltas taken in-process around the
measured loop — no profiler attach, no sudo, near-zero dispersion. That is
why instructions/op and cycles/op are the primary observables and wall time
is secondary (the harness scope-ladder rule for S0/S1).

## Reading the numbers (the four walls)

- **IPC high (>3) and ns/op flat as you widen** → compute-bound: only fewer
  instructions help; check `asm` for NEON share and instruction count.
- **IPC low (<1) with a serial algorithm** → dependency-chain-bound: widen
  into independent lanes (batch inversion, four-lane hashing); more SIMD
  will not help until the chain is broken.
- **IPC low with heavy `mem` counts in `asm`** → memory-bound: measure
  against the host STREAM ceiling; only fewer passes or better locality help.
- **ns/op >> cycles/op × cycle time** → overhead (page faults, allocator,
  fan-out): profile the harness setup, not the kernel.

## Traps this harness defends against — verify anyway

- **Constant folding**: a pure function of constants is evaluated at compile
  time; LLVM also closed-forms reducible loops (a sum-of-squares loop costs
  O(1)). The `run(seed)` contract threads a runtime value through every
  call. The tell is instructions/op near zero — check it every time.
- **Dead-code elimination**: return a u64 derived from the work; the harness
  accumulates it through `std.mem.doNotOptimizeAway`.
- **Call overhead**: keep one unit ≥ ~1µs or batch internally and set
  `ops_per_call` so per-op numbers stay honest.
- **Inlining in `asm` output**: the workload usually inlines into `_main`.
  Mark it `pub noinline fn run(...)` when you need a separate symbol to
  inspect; remove `noinline` before timing (inlining is part of the result).
- **Noise**: `compare` interleaves ABBA and reports a bootstrap CI on wall
  ratios; instruction ratios are near-deterministic — when wall moves but
  instructions don't, suspect the machine, not the code.

## Rules of engagement

- A vectorization claim requires `asm` evidence (NEON share on the hot
  symbol), not source-level belief — the CONTRIBUTING SIMD rule, mechanized.
- An A/B verdict requires the CI to exclude 1.0; a point estimate is not a
  result. Promotion-grade claims still go through `stwo-perf run` at S3 —
  this harness is the S1 inner loop that generates hypotheses cheaply.
- Findings worth keeping become `stwo-perf notes add` entries with the
  counter numbers inline; scratch dirs are disposable, evidence is not.
