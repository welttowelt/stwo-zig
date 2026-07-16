<div align="center">

# Stwo Zig

**A high-performance Zig implementation of the Stwo prover and verifier.**

Protocol parity with Rust. Portable CPU execution. Resident GPU proving on Metal.

[![Benchmark Pages](https://github.com/teddyjfpender/stwo-zig/actions/workflows/benchmark-pages.yml/badge.svg)](https://github.com/teddyjfpender/stwo-zig/actions/workflows/benchmark-pages.yml)
[![Zig 0.15.x](https://img.shields.io/badge/Zig-0.15.x-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
![Backends: CPU, Metal, CUDA](https://img.shields.io/badge/backends-CPU_%7C_Metal_%7C_CUDA-2563EB)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-0F766E)](LICENSE)

</div>

---

`stwo-zig` is a parity-first port of [StarkWare's Stwo](https://github.com/starkware-libs/stwo).
It brings Stwo's circle-STARK protocol to Zig while making memory, vectorization, and device
execution explicit. The result is one proving stack with native examples, Cairo and RISC-V
frontends, and backends designed for both portability and throughput.

> [!IMPORTANT]
> The [pinned Rust Stwo revision](docs/conformance/upstream.md) is the final correctness oracle.
> Gated proofs cross-verify in both directions: Rust to Zig and Zig to Rust.

## Backends

| Backend | Execution model | Focus |
| :--- | :--- | :--- |
| **Zig CPU / SIMD** | Portable scalar backend with hardware-native SIMD hot paths | Predictable execution and broad compatibility |
| **Metal** | Persistent, resident hybrid prover runtime for Apple GPUs | Wide traces, streaming proofs, and low transfer overhead |
| **CUDA** | Device-column backend through `libstwo_cuda` | NVIDIA GPU acceleration and backend parity |

## Frontends

| Surface | What it proves |
| :--- | :--- |
| **Native Stwo** | Blake, Poseidon, Plonk, state-machine, wide-Fibonacci, and XOR AIRs |
| **Cairo** | Cairo PIE ingestion, witness construction, proof planning, and resident Metal sessions |
| **RISC-V** | RV32IM execution, trace generation, and CPU or Metal-backed proving |

## Quick Start

Requires **Zig 0.15.x** and **Python 3**. Rust parity tooling uses
`nightly-2025-07-14`.

```sh
zig build test -Doptimize=ReleaseFast
zig build test-riscv-prover -Doptimize=ReleaseFast
zig build metal-test -Doptimize=ReleaseFast  # macOS with Metal
```

Run the complete release confidence path with:

```sh
zig build release-gate-strict -Doptimize=ReleaseFast
```

## Explore

| | |
| :--- | :--- |
| **[Documentation](docs/README.md)** | Architecture, performance reports, profiling, and project history |
| **[Conformance](docs/conformance/contract.md)** | Protocol parity, interoperability, and release requirements |
| **[Metal architecture](docs/sn-pie-metal-production-architecture.md)** | The end-to-end design for resident, streaming block proving |
| **[Benchmarks](docs/cairo-fib-resident-metal-vs-simd.md)** | Reproducible Metal and SIMD measurements with proof parity |
| **[Contributing](CONTRIBUTING.md)** | Zig, SIMD, Metal, correctness, and engineering standards |

The compatibility target is pinned to upstream commit
[`a8fcf4bd`](https://github.com/starkware-libs/stwo/commit/a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2).
Claims of equivalence apply to that revision and the committed conformance matrices.

## License

Licensed under [Apache 2.0](LICENSE), matching upstream Stwo.
