# Decomposition plan for baselined legacy findings

Repository-local plan required by the source-conformance ratchet: every
baseline exception names this file, and an exception may only shrink. The
full historical narrative lives in the `stwo-zig-og-docs` archive; this file
is the operative ledger.

## Rules

- A new finding fails CI immediately; the baseline never grows.
- Removing debt removes its baseline entry in the same commit.
- `--update-baseline` runs are reviewed: the diff must only shrink.

## Remaining owners and next extractions

| Owner | Next extraction |
| --- | --- |
| `src/metal_arena_plan_cli.zig` | move remaining orchestration into `src/tools/metal_arena_plan/` until the root file is a thin argument parser |
| `src/backends/metal/runtime.zig` | continue the runtime decomposition into `src/backends/metal/runtime/` owners |
| `src/backends/metal/runtime.m` | split the Objective-C bridge by admission, resources, encoding, and lifecycle |
| `src/integrations/cairo_metal/arena_binding.zig` | phase facade split per the archived arena-binding plan (Cairo work resumes with stwo-cairo) |
| Cairo-deferred trees (`src/frontends/cairo/`, `src/tests/cairo/`, tooling) | untouched until the stwo-cairo effort restarts; entries stay frozen |
| Rust support crates over the size ceiling | reduce when the pinned oracle next changes; never edited casually |
