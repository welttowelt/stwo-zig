# Verdict JSON schema (v1)

Emitted by `stwo-perf run`. `kind` is the trust boundary: the CLI can only ever
emit `claimed`; `judged` is set exclusively by the judge workflow on the locked
runner. A claimed verdict is advisory by definition.

```json
{
  "schema_version": 1,
  "kind": "claimed | judged",
  "harness_commit": "<hash of autoresearch/ tree state>",
  "repo_commit": "<candidate commit>",
  "predecessor_commit": "<paired A-arm commit>",
  "scope": "s1|s2|s3|s4|s5",
  "declared_objective": { "workload_class": "...", "dimension": "time|rss|energy" },
  "environment": {
    "host": "<hostname hash>", "os": "...", "zig_version": "...",
    "release_fast": true, "clean_tree": true, "judge_lock_held": false,
    "preflight": { "load_ok": true, "thermal_ok": true }
  },
  "gates": {
    "G1": { "pass": true, "detail": "proof bytes byte-identical across arms; oracle receipt <path|skipped:reason>" },
    "G2": { "pass": true, "detail": "workload digests unchanged; no locked path touched" },
    "G3": { "pass": true, "detail": "<wall>: predicted <delta> observed <delta>" },
    "G4": { "pass": true, "detail": "peak RSS within budget" },
    "G5": { "pass": true, "detail": "environment contract met" }
  },
  "score": {
    "per_workload": {
      "<workload id>": {
        "r": 0.97, "ci": [0.96, 0.985], "rounds": 9,
        "a_median_ms": 3.98, "b_median_ms": 3.86
      }
    },
    "R_geomean": 0.97,
    "theta": 0.012,
    "aa_dispersion": 0.0151,
    "significant": true,
    "neutral": false
  },
  "tiebreakers": { "rss_ratio": 0.99, "waits": null, "dispatches": null, "energy_j": null },
  "holdout": { "seed": 180734, "pass": true, "r": 1.004 },
  "evidence": { "reports": ["<paths>"], "pairing": "round-level ABBA (...)" }
}
```

Judge-added fields (present only on signed judged verdicts fetched from the
`judge-verdicts` branch, never in a submission's tree):

- `submission_id` — the submission directory this verdict judges;
- `claimed_divergence` — null, or `{claimed_r, judged_r, gap, judged_ci_half_width}`
  when the claim diverged beyond the judged CI (a recorded finding);
- `judge_signature` — HMAC-SHA256 over the canonical JSON payload; verified by
  the promotion bot before any ledger append.

Gate failures reject the candidate (no score is comparable); per-gate `detail`
carries the margin as a diagnostic, never as a negotiable penalty. `holdout`
is null on claimed runs — only judged runs draw the seeded hold-out.
