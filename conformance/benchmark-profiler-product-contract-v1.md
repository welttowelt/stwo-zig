# Benchmark and Profiler Product Contract

This document is the BG-12 authority for benchmark and profiler ownership. The
machine-readable companion is
`conformance/benchmark-profiler-product-contract-v1.json`.

## Promotion surfaces

`scripts/native_proof_matrix.py` is the promotion-quality Native benchmark. It
measures exactly two focused products:

| Lane | Logical product | Build step | Measured executable |
| --- | --- | --- | --- |
| CPU/SIMD | `stwo-native-cpu` | `benchmark-native-cpu` | `zig-out/bin/stwo-zig-native-cpu-bench` |
| Metal | `stwo-native-metal` | `native-proof-bench-metal` | `zig-out/bin/native-proof-bench-metal` |

The matrix uses schema/protocol
`native_proof_cross_backend_matrix_v6`. Every lane report must carry a valid
schema-v2 identity emitted by its focused benchmark product. The controller
independently recomputes the canonical digest defined by
`build_support/graph/identity.zig`, checks it against report provenance, hashes
the post-link executable before the run, and rejects a binary that changes
during the matrix.

Every measured proof is verified locally. CPU and Metal canonical proof bytes
must match. Formal rows also require acceptance by the pinned Rust Stwo oracle.
No failed, unverified, profiled, dirty, unstable, or under-sampled row may
publish headline performance.

`scripts/native_profile_capture.py` is the focused profiling surface. It uses
the same product identities and executable binding, locally verifies the
profiled proofs, and requires CPU/Metal canonical proof equality. Profile
receipts are always `profiled_diagnostic` and `promotion_eligible: false`;
instrumented time is never substituted for benchmark MHz.

## Receipts

Each run embeds separate CPU and Metal
`focused_product_measurement_receipt_v1` receipts. A receipt binds:

- the complete canonical product identity and exact post-link executable SHA;
- workload dimensions and descriptor;
- numerator unit and value;
- proof/security parameters;
- headline, request, setup, and profiler timing scope;
- cold initialization, excluded warmups, and measured post-warmup state;
- local verification, byte stability, cross-backend parity, and Rust-oracle
  status; and
- host, CPU, Metal device, SDK/runtime, source commit, tree, and dirty state.

Receipt mutations, product swaps, role changes, forged canonical digests,
binary swaps, and unverified measurements fail closed.
Archived matrix and profiler validators also bind the receipt's complete
host/device object to the enclosing run environment; a recomputed receipt
cannot substitute another host, Metal device, SDK, or runtime identity.

`promotion_eligible` is derived, not trusted. A benchmark receipt may claim it
only when its exact policy schema declares formal, unprofiled execution under
the functional protocol and every row independently records all of the
following:

- at least 10 excluded warmups and 10 measured proofs per lane;
- `verified_samples == measured_samples`, with every proof locally verified;
- byte-identical measured proofs and CPU/Metal canonical proof equality;
- a verified pinned Rust Stwo receipt;
- `verified_unprofiled` evidence with headline and stability gates satisfied;
  and
- a clean `ReleaseFast` canonical product identity.

The validator recomputes this conjunction and rejects a contradictory claim
even when an attacker recomputes the receipt's unkeyed content digest. Profile
receipts, non-finite JSON numbers, unknown policy/measurement fields, malformed
nested structures, and numerator or workload geometry drift are rejected.

The generic schema-v2 encoder and validator live in
`scripts/product_identity_lib`. They impose no frontend/backend policy and are
shared by benchmark, cache, host-admission, and product-gate tooling. Focused
CPU/Metal policy is layered above that module. The audit runs
`build_support/benchmark_product_authority.zig` so Python product/runtime
strings are checked mechanically against the live Zig descriptors and runtime
identity hooks.

## History continuity

Existing archive bytes and run IDs remain immutable. Schema v6 begins a new
epoch because v5 did not record canonical product identity. The delta tool
accepts only the forward `v5 -> v6` transition and records this explicit map:

| Historical v5 executable | Focused v6 product |
| --- | --- |
| `native-proof-bench-cpu` | `stwo-native-cpu` |
| `native-proof-bench-metal` | `stwo-native-metal` |

The map states an ownership migration, not evidence that old rows carried the
new identity. V6-to-v6 comparisons require the same frontend, backend, role,
protocol manifest, target, CPU/features, optimization, and runtime/AOT
semantics. Source commit/tree, canonical identity digest, and executable digest
remain revision evidence and may change.

## Legacy diagnostics

`benchmark_smoke.py`, `benchmark_full.py`, and `profile_smoke.py` retain their
historical aggregate interop purpose. Their reports explicitly identify the
`stwo-zig` aggregate scope, omit a canonical focused identity, and set
`promotion_eligible: false`. They preserve old dashboards and Rust/Zig
diagnostics but cannot satisfy BG-12 or authorize a performance promotion.

Specialized Cairo, RISC-V, SN-PIE, kernel, and streaming tools remain owned by
their lane-specific contracts. They cannot be promoted as Native CPU or Native
Metal evidence through this contract.
