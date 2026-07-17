# Documentation

This directory separates active contracts, current architecture, benchmark evidence, and historical
context. Root-level project entry points are limited to `README.md` and `CONTRIBUTING.md`.

## Normative Contracts

- [`design/2026-07-17-pre-optimization-conformance-goal.md`](design/2026-07-17-pre-optimization-conformance-goal.md):
  active shared Stwo, Native CPU/Metal, repository-structure, and optimization-readiness goal.
- [`conformance/contract.md`](conformance/contract.md): release and parity requirements.
- [`conformance/upstream.md`](conformance/upstream.md): exact Rust Stwo compatibility pin and upgrade
  policy. The pinned Rust implementation is the final correctness oracle.
- [`conformance/api-parity.md`](conformance/api-parity.md): machine-checked Zig-to-Rust API ledger.
- [`conformance/divergence-log.md`](conformance/divergence-log.md): active parity and divergence
  signoff consumed by roadmap tooling.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md): engineering, Zig, SIMD, Metal, testing, and review
  standards.

## Current Architecture

- [`design/2026-07-17-source-conformance.md`](design/2026-07-17-source-conformance.md): active,
  phased migration of source ownership, dependency direction, tests, and delivery automation.
- [`design/2026-07-17-native-backend-suite.md`](design/2026-07-17-native-backend-suite.md): complete
  six-example real-AIR Native CPU/Metal acceptance architecture and evidence contract.
- [`design/2026-07-17-metal-shader-library-decomposition.md`](design/2026-07-17-metal-shader-library-decomposition.md):
  Metal source-family, stable ABI, linked-metallib, and AOT/JIT migration contract.

## Deferred TODO Tracks

The following documents preserve planned Cairo, SN PIE, streaming, and RISC-V work. They are not
active optimization-readiness blockers.

- [`design/2026-07-17-cairo-program-matrix.md`](design/2026-07-17-cairo-program-matrix.md):
  human projection of the exact 27-cell
  [`cairo_program_matrix.json`](../vectors/cairo/cairo_program_matrix.json) authority and the general
  Zig proof critical path.
- [`cairo-zig-prover-entrypoint.md`](cairo-zig-prover-entrypoint.md): general Cairo orchestration,
  production-admission boundary, and final `verify_cairo` publication gate.
- [`design/2026-07-17-cairo-fib25k-input-checkpoint.md`](design/2026-07-17-cairo-fib25k-input-checkpoint.md):
  authenticated Fib25k bring-up input and base/diagnostic-interaction trace receipts.
- [`sn-pie-metal-production-architecture.md`](sn-pie-metal-production-architecture.md): normative
  production architecture and delivery plan for the Cairo SN PIE Metal prover.
- [`sn-pie-streaming.md`](sn-pie-streaming.md): streaming proof-service design and extraction notes.
- [`sn-pie-persistent-session.md`](sn-pie-persistent-session.md): persistent JSONL session MVP.
- [`cairo-zig-adapter.md`](cairo-zig-adapter.md): Cairo ingestion and Zig prover boundary.
- [`design/2026-07-17-cairo-metal-arena-binding-decomposition.md`](design/2026-07-17-cairo-metal-arena-binding-decomposition.md):
  Cairo-Metal phase ownership and arena-facade migration contract.
- [`design/2026-07-17-cairo-arena-schedule-decomposition.md`](design/2026-07-17-cairo-arena-schedule-decomposition.md):
  pure runtime schedule ownership and decomposition contract.

## Performance And Profiling

- [`design/2026-07-17-backend-performance-program.md`](design/2026-07-17-backend-performance-program.md):
  normative profiler-led Native optimization program; deferred frontend work remains documented
  for later, and aggressive execution is blocked by the pre-optimization conformance goal.
- [`metal-profiling.md`](metal-profiling.md): profiling controls and safe collection procedure.
- [`metal-backend-progress.md`](metal-backend-progress.md): implementation and measured-progress
  summary.
- [`cairo-fib-resident-metal-vs-simd.md`](cairo-fib-resident-metal-vs-simd.md): Rust Stwo-Cairo
  resident Fib reference comparison.
- [`raw-stwo-wide-fibonacci-metal-vs-simd.md`](raw-stwo-wide-fibonacci-metal-vs-simd.md): raw Stwo
  wide-Fibonacci comparison and scope limitations.
- [`riscv-fib-metal-vs-zig.md`](riscv-fib-metal-vs-zig.md): RISC-V Metal versus Zig CPU comparison.
- [`riscv-rust-parity.md`](riscv-rust-parity.md): RISC-V Rust/Zig parity evidence.
- [`fib-backend-comparison.md`](fib-backend-comparison.md): superseded diagnostic cross-VM report.

Machine-readable benchmark and parity evidence is stored under `vectors/reports/`.

## Historical Context

- [`metal-resident-prover-design.md`](metal-resident-prover-design.md): superseded original
  resident-prover architecture, retained for design provenance.
- [`gpu-backend-design.md`](gpu-backend-design.md): superseded generic GPU/RISC-V design, retained
  for design provenance.
- [`history/metal-handover-2026-07-15.md`](history/metal-handover-2026-07-15.md): chronological Metal
  implementation and evidence ledger.
- [`history/milestone-0.1-spec.md`](history/milestone-0.1-spec.md): superseded initial milestone.
- [`history/original-scope-of-work.md`](history/original-scope-of-work.md): original project scope and
  assumptions.

Historical documents are retained for provenance. They are not normative when they conflict with
the active contracts or current production architecture.
