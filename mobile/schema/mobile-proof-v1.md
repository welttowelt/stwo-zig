# mobile-proof-v1 report schema

One wrapper object around the untouched native prover report — the prover
report stays byte-compatible with `native_proof_v7`, so every existing
parity/validation tool keeps working on the inner object.

```json
{
  "schema": "mobile-proof-v1",
  "device_identity": {
    "model": "iPhone",
    "machine": "iPhone16,1",
    "system": "iOS 19.x",
    "at_start": { "thermal_state": "nominal", "low_power_mode": false, "battery_level": 0.87, "battery_state": 2, "uptime_seconds": 12345.6 },
    "at_end":   { "thermal_state": "fair",    "low_power_mode": false, "battery_level": 0.86, "battery_state": 2, "uptime_seconds": 12420.1 },
    "battery_delta": 0.01
  },
  "prover_report": { "…full native_proof_v7 report, unmodified…" }
}
```

Validity rules (v1):

- `low_power_mode` must be false in BOTH snapshots.
- `at_start.thermal_state` must be `nominal` or `fair`; both snapshots are
  mandatory (the shell captures start and end).
- **Sampling contract (one regime for the whole board):** a scored row
  reports the median of `samples` verified prove-only measurements after
  `warmups` untimed verified warmups, with the timed region covering
  proving only (encode/verify excluded) — native_proof_v7 semantics.
  **Declared relaxation vs v7 headline rules:** this board fixes
  warmups=2, samples=5 (thermal/battery budget on phones makes v7's
  headline sample counts hostile); rows are board-eligible at w2/s5 and
  the relaxation is explicit, not inherited. Both flavors implement this
  today; any deviation disqualifies the row.
- **Toolchain/flag pinning (per epoch):** rows record the exact build
  flags; epoch 1 pins zig `-OReleaseFast -mcpu baseline` and rust
  `--release` at the repo's pinned toolchains. Changing flags = new epoch.
- `prover_report.proof.samples[*].sha256` must match the reference digests
  for the workload — the same oracle-parity gate as every other board.
- Rows carry the device class from BOARD_SPEC.md; the class is claimed by
  the submitter and checkable from `machine`.

Open for v2: MetricKit-calibrated energy per proof (scored), start+end
thermal capture, Android device-identity fields (`ro.product.*`, thermal
via `thermal_service`).
