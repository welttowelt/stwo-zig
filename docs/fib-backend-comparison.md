# Fibonacci Backend Comparison

> **Superseded diagnostic report.** Do not use the tables below as current backend performance or
> cross-VM correctness evidence. The RISC-V path registers no trace-dependent AIR constraints, so
> its acceptance is PCS/FRI diagnostic evidence only. The Cairo rows also use one cold proof per
> fresh process and conflate Metal initialization with proving throughput. Current corrected Cairo
> measurements are in [Cairo Fib: Resident Metal vs SIMD](cairo-fib-resident-metal-vs-simd.md).

All rows use identical requested Fib N. Native MHz is VM-local: RISC-V emits
`5*N-3` cycles and Cairo emits `7*N+16` cycles. Fib iterations per second is
the cross-VM workload rate.

The fresh-process wall clock is the authoritative total proving time: it wraps
one verified proof subprocess, including process launch, program execution or
adaptation, proving, and verification. RISC-V internal total is directly timed
by its CLI; Cairo internal total is a constructed VM +
adapt + prove + verify phase sum and is marked as such.

RISC-V uses blake2s, blowup 1, FRI fold 1, PoW 10, and 3 queries. Cairo uses 96-bit security, FRI fold 3, PoW 26, and 70 queries. Absolute cross-VM times are therefore descriptive, not apples-to-apples; interpret Metal speedups only within each VM
and protocol pair.

Each RISC-V cell is the median of 3 verified fresh processes; each Cairo cell contains 1 verified fresh process. Both Metal lanes are hybrid implementations. The Cairo Metal lane uses SIMD host bridges
for witness generation and barycentric weight construction while commitments,
composition, FRI, and grouped OODS evaluation use Metal.

## Prove Only

| Fib N | Lane | Native cycles | Prove | Native MHz | Fib Miter/s |
| ---: | :--- | ---: | ---: | ---: | ---: |
| 25,000 | Zig RISC-V CPU with auto-SIMD hot paths | 124,997 | 126.1 ms | 0.991 | 0.198 |
| 25,000 | Zig RISC-V hybrid MetalProverEngine | 124,997 | 160.5 ms | 0.779 | 0.156 |
| 25,000 | Rust Cairo SimdBackend | 175,016 | 1.350 s | 0.130 | 0.019 |
| 25,000 | Rust Cairo hybrid Metal backend | 175,016 | 1.967 s | 0.089 | 0.013 |
| 50,000 | Zig RISC-V CPU with auto-SIMD hot paths | 249,997 | 167.9 ms | 1.489 | 0.298 |
| 50,000 | Zig RISC-V hybrid MetalProverEngine | 249,997 | 125.0 ms | 2.000 | 0.400 |
| 50,000 | Rust Cairo SimdBackend | 350,016 | 1.474 s | 0.237 | 0.034 |
| 50,000 | Rust Cairo hybrid Metal backend | 350,016 | 8.719 s | 0.040 | 0.006 |
| 100,000 | Zig RISC-V CPU with auto-SIMD hot paths | 499,997 | 276.0 ms | 1.812 | 0.362 |
| 100,000 | Zig RISC-V hybrid MetalProverEngine | 499,997 | 132.3 ms | 3.779 | 0.756 |
| 100,000 | Rust Cairo SimdBackend | 700,016 | 1.506 s | 0.465 | 0.066 |
| 100,000 | Rust Cairo hybrid Metal backend | 700,016 | 10.286 s | 0.068 | 0.010 |
| 250,000 | Zig RISC-V CPU with auto-SIMD hot paths | 1,249,997 | 577.4 ms | 2.165 | 0.433 |
| 250,000 | Zig RISC-V hybrid MetalProverEngine | 1,249,997 | 201.7 ms | 6.197 | 1.239 |
| 250,000 | Rust Cairo SimdBackend | 1,750,016 | 2.019 s | 0.867 | 0.124 |
| 250,000 | Rust Cairo hybrid Metal backend | 1,750,016 | 12.429 s | 0.141 | 0.020 |
| 500,000 | Zig RISC-V CPU with auto-SIMD hot paths | 2,499,997 | 1.011 s | 2.473 | 0.495 |
| 500,000 | Zig RISC-V hybrid MetalProverEngine | 2,499,997 | 314.4 ms | 7.952 | 1.590 |
| 500,000 | Rust Cairo SimdBackend | 3,500,016 | 2.492 s | 1.405 | 0.201 |
| 500,000 | Rust Cairo hybrid Metal backend | 3,500,016 | 14.358 s | 0.244 | 0.035 |
| 1,000,000 | Zig RISC-V CPU with auto-SIMD hot paths | 4,999,997 | 1.894 s | 2.640 | 0.528 |
| 1,000,000 | Zig RISC-V hybrid MetalProverEngine | 4,999,997 | 500.0 ms | 10.000 | 2.000 |
| 1,000,000 | Rust Cairo SimdBackend | 7,000,016 | 3.925 s | 1.783 | 0.255 |
| 1,000,000 | Rust Cairo hybrid Metal backend | 7,000,016 | 17.339 s | 0.404 | 0.058 |
| 2,000,000 | Zig RISC-V CPU with auto-SIMD hot paths | 9,999,997 | 3.719 s | 2.689 | 0.538 |
| 2,000,000 | Zig RISC-V hybrid MetalProverEngine | 9,999,997 | 910.7 ms | 10.981 | 2.196 |
| 2,000,000 | Rust Cairo SimdBackend | 14,000,016 | 6.563 s | 2.133 | 0.305 |
| 2,000,000 | Rust Cairo hybrid Metal backend | 14,000,016 | 21.937 s | 0.638 | 0.091 |

## Fresh-Process Total Proving Time

| Fib N | Lane | Internal total | Kind | Total wall | Native MHz | Fib Miter/s |
| ---: | :--- | ---: | :--- | ---: | ---: | ---: |
| 25,000 | Zig RISC-V CPU with auto-SIMD hot paths | 134.2 ms | direct | 144.1 ms | 0.868 | 0.174 |
| 25,000 | Zig RISC-V hybrid MetalProverEngine | 166.9 ms | direct | 207.4 ms | 0.603 | 0.121 |
| 25,000 | Rust Cairo SimdBackend | 1.373 s | constructed | 1.403 s | 0.125 | 0.018 |
| 25,000 | Rust Cairo hybrid Metal backend | 2.002 s | constructed | 2.058 s | 0.085 | 0.012 |
| 50,000 | Zig RISC-V CPU with auto-SIMD hot paths | 184.6 ms | direct | 195.9 ms | 1.276 | 0.255 |
| 50,000 | Zig RISC-V hybrid MetalProverEngine | 137.8 ms | direct | 179.7 ms | 1.391 | 0.278 |
| 50,000 | Rust Cairo SimdBackend | 1.529 s | constructed | 1.575 s | 0.222 | 0.032 |
| 50,000 | Rust Cairo hybrid Metal backend | 8.780 s | constructed | 8.819 s | 0.040 | 0.006 |
| 100,000 | Zig RISC-V CPU with auto-SIMD hot paths | 307.0 ms | direct | 317.2 ms | 1.576 | 0.315 |
| 100,000 | Zig RISC-V hybrid MetalProverEngine | 158.0 ms | direct | 199.6 ms | 2.505 | 0.501 |
| 100,000 | Rust Cairo SimdBackend | 1.601 s | constructed | 1.641 s | 0.427 | 0.061 |
| 100,000 | Rust Cairo hybrid Metal backend | 10.376 s | constructed | 10.436 s | 0.067 | 0.010 |
| 250,000 | Zig RISC-V CPU with auto-SIMD hot paths | 640.2 ms | direct | 650.6 ms | 1.921 | 0.384 |
| 250,000 | Zig RISC-V hybrid MetalProverEngine | 258.7 ms | direct | 300.6 ms | 4.158 | 0.832 |
| 250,000 | Rust Cairo SimdBackend | 2.229 s | constructed | 2.279 s | 0.768 | 0.110 |
| 250,000 | Rust Cairo hybrid Metal backend | 12.637 s | constructed | 12.705 s | 0.138 | 0.020 |
| 500,000 | Zig RISC-V CPU with auto-SIMD hot paths | 1.134 s | direct | 1.148 s | 2.178 | 0.436 |
| 500,000 | Zig RISC-V hybrid MetalProverEngine | 427.1 ms | direct | 472.3 ms | 5.293 | 1.059 |
| 500,000 | Rust Cairo SimdBackend | 2.951 s | constructed | 3.014 s | 1.161 | 0.166 |
| 500,000 | Rust Cairo hybrid Metal backend | 14.752 s | constructed | 14.813 s | 0.236 | 0.034 |
| 1,000,000 | Zig RISC-V CPU with auto-SIMD hot paths | 2.102 s | direct | 2.118 s | 2.361 | 0.472 |
| 1,000,000 | Zig RISC-V hybrid MetalProverEngine | 698.7 ms | direct | 747.4 ms | 6.690 | 1.338 |
| 1,000,000 | Rust Cairo SimdBackend | 4.782 s | constructed | 4.839 s | 1.447 | 0.207 |
| 1,000,000 | Rust Cairo hybrid Metal backend | 18.099 s | constructed | 18.173 s | 0.385 | 0.055 |
| 2,000,000 | Zig RISC-V CPU with auto-SIMD hot paths | 4.146 s | direct | 4.166 s | 2.400 | 0.480 |
| 2,000,000 | Zig RISC-V hybrid MetalProverEngine | 1.321 s | direct | 1.368 s | 7.308 | 1.462 |
| 2,000,000 | Rust Cairo SimdBackend | 8.071 s | constructed | 8.147 s | 1.718 | 0.245 |
| 2,000,000 | Rust Cairo hybrid Metal backend | 23.447 s | constructed | 23.511 s | 0.595 | 0.085 |

## Within-VM Metal Speedup

A value above `1.0x` means Metal is faster than that VM's CPU/SIMD lane.

| Fib N | RISC-V prove | RISC-V total | Cairo prove | Cairo total |
| ---: | ---: | ---: | ---: | ---: |
| 25,000 | 0.786x | 0.694x | 0.686x | 0.682x |
| 50,000 | 1.343x | 1.090x | 0.169x | 0.179x |
| 100,000 | 2.086x | 1.589x | 0.146x | 0.157x |
| 250,000 | 2.863x | 2.164x | 0.162x | 0.179x |
| 500,000 | 3.215x | 2.430x | 0.174x | 0.203x |
| 1,000,000 | 3.787x | 2.834x | 0.226x | 0.266x |
| 2,000,000 | 4.083x | 3.045x | 0.299x | 0.347x |
