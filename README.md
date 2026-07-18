<div align="center">

# Stwo Zig

**A high-performance Zig implementation of the Stwo prover and verifier.**

Protocol parity with Rust. Portable CPU execution. Resident GPU proving on Metal.

[![CI](https://github.com/teddyjfpender/stwo-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/teddyjfpender/stwo-zig/actions/workflows/ci.yml)
[![Benchmark Pages](https://github.com/teddyjfpender/stwo-zig/actions/workflows/benchmark-pages.yml/badge.svg)](https://github.com/teddyjfpender/stwo-zig/actions/workflows/benchmark-pages.yml)
[![Zig 0.15.x](https://img.shields.io/badge/Zig-0.15.x-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
![Backends: CPU, Metal, CUDA](https://img.shields.io/badge/backends-CPU_%7C_Metal_%7C_CUDA-2563EB)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-0F766E)](LICENSE)

</div>

---

`stwo-zig` is a parity-first port of [StarkWare's Stwo](https://github.com/starkware-libs/stwo).
It brings Stwo's circle-STARK protocol to Zig while making memory, vectorization, and device
execution explicit. The result is one proving stack: pure Stwo with native examples today,
and the Cairo frontend (stwo-cairo in Zig) when that effort resumes.

> [!IMPORTANT]
> The [pinned Rust Stwo revision](conformance/upstream.md) is the final correctness oracle.
> Gated proofs cross-verify in both directions: Rust to Zig and Zig to Rust.

## Backends

| Backend | Execution model | Focus |
| :--- | :--- | :--- |
| **Zig CPU / SIMD** | Portable scalar backend with hardware-native SIMD hot paths | Predictable execution and broad compatibility |
| **Metal** | Persistent, resident hybrid prover runtime for Apple GPUs | Wide traces, streaming proofs, and low transfer overhead |
| **CUDA** | Device-column backend through `libstwo_cuda` | NVIDIA GPU acceleration and backend parity |

## Frontends

| Surface | Current status |
| :--- | :--- |
| **Native Stwo** | Blake, Poseidon, Plonk, state-machine, wide-Fibonacci, and XOR AIRs |
| **Cairo** | Versioned PIE ingestion and SN2-specialized resident proof machinery, parked until the stwo-cairo effort resumes; the general Cairo proof path is not release-gated |
| **RISC-V** | Staged Stark-V RV32IM ELF adapter with sharded AIR components and the CPU prove/verify CLI. It remains fail-closed behind `--experimental` until the [release contract](conformance/2026-07-18-riscv-release-goal.md) passes |

## Quick Start

Requires **Zig 0.15.x** and **Python 3**. Rust parity tooling uses
`nightly-2025-07-14`.

```sh
zig build test -Doptimize=ReleaseFast
zig build metal-test -Doptimize=ReleaseFast  # macOS with Metal
```

## Prove

Build the installed proof command, produce one verified Native proof, then run the local verifier
against its versioned Rust-compatible artifact:

```sh
zig build stwo-zig -Doptimize=ReleaseFast

zig-out/bin/stwo-zig prove \
  --air wide_fibonacci --backend cpu --protocol secure \
  --log-n-rows 12 --sequence-len 16 \
  --output proof.json --report-out prove-report.json

zig-out/bin/stwo-zig verify --artifact proof.json
```

`bench` uses the same proving transaction and verifies every warmup and timed sample. Select
`--backend metal-hybrid` explicitly on macOS; backend failure never falls back to CPU. Run
`stwo-zig applications` for the compiled AIR registry and adapter status.

## RISC-V frontend (experimental)

The staged adapter accepts an RV32IM ELF, executes it, builds the sharded witness, proves it through
the same PCS/FRI core, self-verifies before publication, and emits a bounded schema-v3 artifact.
A separate process must verify that artifact against a caller-supplied expected-statement digest.
The pinned Rust [Stark-V](https://github.com/ClementWalter/stark-v) implementation remains the final
oracle at shared boundaries. Staged artifacts say `not_release_gated` and cannot be relabelled.

```sh
zig build stwo-zig -Doptimize=ReleaseFast

zig-out/bin/stwo-zig prove \
  --elf vectors/riscv_elfs/branch_fib.elf \
  --backend cpu --protocol functional --experimental \
  --output riscv-proof.json --report-out riscv-report.json

STATEMENT_DIGEST=$(python3 -c \
  'import json; print(json.load(open("riscv-report.json"))["statement_sha256"])')
zig-out/bin/stwo-zig verify \
  --artifact riscv-proof.json --protocol functional \
  --expect-statement-digest "$STATEMENT_DIGEST"
```

`functional` is the fast development profile. Use `secure` when collecting release evidence.

```sh
zig build test-riscv -Doptimize=ReleaseFast         # runner + trace suites
zig build test-riscv-prover -Doptimize=ReleaseFast  # prove + verify roundtrips
zig build riscv-bench -Doptimize=ReleaseFast        # CPU benchmark CLI
zig build riscv-metal-bench -Doptimize=ReleaseFast  # Metal commitments CLI (macOS)
zig build riscv-trace-dump -Doptimize=ReleaseFast   # trace dumper for equivalence runs
```

Run the same standard gate used by hosted CI:

```sh
python3 scripts/ci.py
```

For release evidence, use `python3 scripts/ci.py --strict`. Enable the versioned fast pre-commit
and broader pre-push checks once per checkout with:

```sh
python3 scripts/install_hooks.py
```

## Explore

| | |
| :--- | :--- |
| **[Conformance](conformance/upstream.md)** | Pinned oracle revisions, API parity ledger, and the source-conformance baseline |
| **[RISC-V release goal](conformance/2026-07-18-riscv-release-goal.md)** | Executable checkpoints, evidence requirements, and the fail-closed promotion contract |
| **[Autoresearch](autoresearch/README.md)** | The stwo-perf harness: judged scoring, submissions, ledger, and site feed |
| **[Benchmark history](vectors/reports/benchmark_history/index.json)** | Immutable judged runs, deltas, and bundles under human-readable run ids |
| **Design archive** | Prose architecture and history live in the sibling `stwo-zig-og-docs` directory |
| **[Contributing](CONTRIBUTING.md)** | Zig, SIMD, Metal, correctness, and engineering standards |

The compatibility target is pinned to upstream commit
[`a8fcf4bd`](https://github.com/starkware-libs/stwo/commit/a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2).
Claims of equivalence apply to that revision and the committed conformance matrices.

## License

Licensed under [Apache 2.0](LICENSE), matching upstream Stwo.
