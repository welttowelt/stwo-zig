# stwo mobile proving board — handover package (Zig AND Rust flavors)

Status: **80% built, needs a person with real devices for the last 20%.**

## Rust flavor (no Zig anywhere)

`mobile/rust-bench/` wraps the **reference Rust stwo prover** (same pinned
rev as the parity oracle) behind the identical C ABI, so the same Swift
shell works unchanged:

```sh
PATH="$HOME/.cargo/bin:$PATH" cargo +nightly-2025-07-14 build --release \
  --target aarch64-apple-ios   # from mobile/rust-bench/
# -> target/aarch64-apple-ios/release/libstwo_mobile_bench.a  (link this)
```

Proven: `cargo test` runs a real proof through the C ABI natively
(byte-identical samples asserted); the arm64-iOS static lib builds on a Mac
without Xcode (blake3 pinned to pure-Rust mode to avoid the iOS-SDK C
toolchain — revisit for speed later). Report schema: `mobile-proof-rust-v1`,
proof digests over the canonical wire JSON. **Cross-flavor parity is
measured, not assumed: see PARITY.md — rust and zig emit byte-identical
proofs (same sha256, same 24965 bytes) on the pinned statement.**

## What is proven (done on 2026-07-22, no upstream file changes)

1. The full stwo-zig prover + bench **compiles clean to arm64-iPhone** and
   packages as one static library: `sh mobile/build_ios_lib.sh` (works
   without Xcode — zig only).
2. The C ABI works end-to-end: `stwo_mobile_bench("--example plonk …")`
   runs a verified proof and returns the standard report JSON. Smoke-tested
   on macOS with the identical shim source (same code, native target):
   valid `schema_version: 7` report, proof digests intact.
3. Oracle parity carries over for free: the phone emits the same proof
   bytes and sha256 digests as every other board — bit-parity to upstream
   stays the soundness test.

Files:
- `src/prover/native/mobile_shim.zig` — the C-ABI shim (new file, additive)
- `mobile/build_ios_lib.sh` — one-command device lib build
- `mobile/ios/StwoBenchView.swift` — SwiftUI shell (picker, run, share)
- `mobile/BOARD_SPEC.md` — board proposal for the harness maintainer
- `mobile/schema/mobile-proof-v1.md` — report wrapper schema

## One rule when linking

Link exactly ONE of the two static libs — they export the same C symbols
(`stwo_mobile_bench`, `stwo_mobile_bench_free`), so linking both is a
duplicate-symbol error. Pick the flavor, keep the same Swift file.

## What the finisher does (est. an afternoon for the first numbers)

1. Xcode: new iOS App project, drop in `StwoBenchView.swift`, link
   `mobile/ios/lib/libstwo_mobile_bench.a`, set Library Search Path. Sign,
   run on a real iPhone. (~10 min if you've done iOS before.)
2. Run the three workloads on-device per the protocol in BOARD_SPEC.md
   (charger, airplane mode, thermal nominal) and share the JSON out.
3. Energy calibration: battery-level delta is 1%-coarse; wire MetricKit or
   sysdiagnose energy logs before energy becomes a scored metric.
4. Android (optional): the same shim builds with
   `-target aarch64-linux-android`; wrap via JNI, mirror the device
   identity fields.

## Honest caveats

- **Simulator numbers are not performance numbers.** The simulator proves
  the app runs; only real devices produce reportable rows.
- Metal/GPU on iPhone is out of scope for v1 (CPU backend only). The Metal
  shaders exist in-repo but their iOS story (memory limits, shader
  compilation) is untested.
- Heavy geometries (log18+) are excluded until someone watches a phone's
  thermal trajectory during a 30 s proof.
