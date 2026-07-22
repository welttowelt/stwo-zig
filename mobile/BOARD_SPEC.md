# Mobile proving board — spec proposal (v1)

Half a page, per the house style. Everything here reuses existing harness
machinery; the only genuinely new surface is device identity and energy.

## Board

- **Board name:** `mobile` — scored like core_cpu (same ratio construction,
  same promotion path), one leaderboard per device class.
- **Device classes (lanes):** `iphone_pro` (A17+/M-class), `iphone_base`,
  `android_flagship`, `android_mid`. A row names its class; cross-class
  comparison is display-only, never scored (same rule as CPU vs Metal).
- **Workloads:** start with the existing native matrix (small/wide/deep —
  wide_fibonacci 2^10×8, 2^14×32, plonk 2^14) — they already run on phones
  via the shim. Heavy geometries excluded until thermals are understood.

## Metrics

- **Headline: wall time** (prove_seconds median), same as every other
  board, under ONE sampling contract for all flavors: prove-only timed
  region, `warmups` untimed + `samples` timed verified runs, median
  reported (native_proof_v7 semantics — see schema).
- **Mandatory context columns:** thermal state at start/end, low-power-mode
  flag (any row with it ON is invalid), battery delta per run batch, device
  identity (machine id, OS). Rendered beside every score, like hybrid's
  fallback columns.
- **Energy (v2):** battery-level delta is too coarse (1% steps); calibrate
  with MetricKit / sysdiagnose energy logs on real hardware before making it
  a scored dimension. Until then it is context, not score.

## Correctness (unchanged — this is the point)

The phone produces the SAME proof bytes as the reference: the report carries
proof sha256 digests, so oracle parity against Rust stwo works exactly as on
every other board. No new soundness story needed — bit-parity to upstream is
the soundness test.

## Protocol notes

- Cooled protocol like heavy: fixed pre-run idle, screen awake, charger
  connected, airplane mode; three-sample bounded batches; report thermal
  state so throttled runs are visible and rejectable (G5 environment gate).
- Epochs per the maintainer's advice: metric OR build-flag/toolchain
  changes start a new epoch, never rewrite old rows (epoch 1 pins zig
  `-mcpu baseline`, rust `--release`, repo toolchains).

## What exists already vs what's open

Done: arm64-ios static lib of the full prover + bench (no upstream changes,
one build command), C ABI (`stwo_mobile_bench(args) -> report JSON`), iOS
shell with device-identity wrapping, this spec, report schema.
Open (needs a person with devices): Xcode project + signing, real-device
numbers, energy calibration, Android (same shim via JNI — the .a builds for
aarch64-linux-android with one target-triple change).
