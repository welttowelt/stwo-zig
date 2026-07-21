# RISC-V proof benchmark report v2

`riscv_proof_v2` is the fail-closed benchmark report consumed by the RISC-V
`stwo-perf` workload group. It replaces `riscv_proof_v1`; consumers must not
interpret a v1 report as v2.

The canonical proof remains the lowercase `proof_bytes_hex` value in the
retained `stwo_riscv_proof` schema-v3 artifact. The v2 report does not change
the artifact wire format, statement binding, transcript binding, independent
verification receipt, pinned Stark-V oracle, or release-admission state.

## Resource usage

The report adds one exact `resources` object:

```json
{
  "availability": "available",
  "source": "darwin.proc_pid_rusage.RUSAGE_INFO_V6",
  "scope": "self_process_lifetime",
  "unavailable_reason": null,
  "before_warmups": {
    "lifetime_max_phys_footprint_bytes": 1,
    "energy_nj": 1,
    "instructions": 1,
    "cycles": 1
  },
  "after_verified_samples": {
    "lifetime_max_phys_footprint_bytes": 2,
    "energy_nj": 2,
    "instructions": 2,
    "cycles": 2
  },
  "interval_delta": {
    "energy_nj": 1,
    "instructions": 1,
    "cycles": 1
  }
}
```

The producer samples its own process immediately before the warmup loop and
immediately after every requested sample has proved and verified. Footprint is
Darwin's lifetime maximum physical footprint. Energy, instruction, and cycle
deltas cover that complete interval, including requested warmups.

Non-Darwin builds and failed V6 calls emit `availability: "unavailable"`, an
enumerated `unavailable_reason`, and null snapshots/delta. Cross-platform CLI
smoke tests and diagnostic `stwo-perf` runs preserve this explicit state.
Available vectors require monotonic snapshots, positive interval counters, and
exact arithmetic deltas. Judged RISC-V evaluation fails G5 unless every arm has
a complete available vector; malformed or asymmetric availability always
fails.
