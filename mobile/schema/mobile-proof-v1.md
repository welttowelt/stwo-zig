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
    "thermal_state": "nominal | fair | serious | critical",
    "low_power_mode": false,
    "battery_level": 0.87,
    "battery_state": 2
  },
  "prover_report": { "…full native_proof_v7 report, unmodified…" }
}
```

Validity rules (v1):

- `low_power_mode` must be false.
- `thermal_state` must be `nominal` or `fair` at run start; report both
  start and end once the shell captures both (v1 captures start only).
- `prover_report.proof.samples[*].sha256` must match the reference digests
  for the workload — the same oracle-parity gate as every other board.
- Rows carry the device class from BOARD_SPEC.md; the class is claimed by
  the submitter and checkable from `machine`.

Open for v2: MetricKit-calibrated energy per proof (scored), start+end
thermal capture, Android device-identity fields (`ro.product.*`, thermal
via `thermal_service`).
