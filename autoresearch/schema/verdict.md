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
    "portfolio": {
      "proof_bytes": 45200,
      "measurement_seconds": 31.25,
      "measurement_rounds": 9
    },
    "resource_portfolio": {
      "peak_rss_mib": { "ratio_geomean": 0.99, "upper_ci_geomean": 1.01, "candidate_geomean": 24.5 },
      "energy_j": { "ratio_geomean": 0.97, "upper_ci_geomean": 1.00, "candidate_geomean": 0.25 },
      "proof_bytes": { "ratio_geomean": 1.0, "upper_ci_geomean": 1.0, "candidate_geomean": 45200.0 }
    },
    "theta": 0.012,
    "aa_dispersion": 0.0151,
    "significant": true,
    "neutral": false
  },
  "tiebreakers": { "rss_ratio": 0.99, "waits": null, "dispatches": null, "energy_j": null },
  "holdout": { "seed": 180734, "pass": true, "r": 1.004 },
  "ledger_evidence": {
    "evidence_kind": "promotion | span_audit | direct_audit",
    "covers": [],
    "credit_replaces": [],
    "supersedes": ""
  },
  "guards": { "guard_blake_12x16": { "r": 1.004, "ci": [0.99, 1.02], "rounds": 3,
              "budget_upper": 1.05, "pass": true, "proof_digest": "<hex>" } },
  "rust_oracle": [ { "workload": "plonk_log14", "verified": true,
                     "artifact_sha256": "<hex>" } ],
  "skipped_groups": [ { "group": "riscv", "reason": "stark-v adapter pending release gate" } ],
  "search_health": {
    "schema_version": 1,
    "decision": {
      "board": "core_cpu", "workload_class": "deep",
      "trailing_window": 8, "trailing_median_gradient_snr": 1.7,
      "gradient_snr_threshold": 2.0,
      "configured_rounds": 15, "auto_boost_rounds": 5,
      "maximum_rounds": 25, "target_rounds": 20,
      "auto_boost_applied": true,
      "auto_boost_reason": "trailing_median_below_threshold",
      "class_wall_deadline_seconds": 600,
      "recorded_before_measurement": true
    },
    "decision_sha256": "sha256:<canonical decision digest>",
    "actual_rounds": 20,
    "actual_rounds_per_workload": { "plonk_log14": 20 },
    "objective_wall_seconds": 210.0,
    "measurement_wall_seconds": 247.0,
    "measurement_wall_hours": 0.068611,
    "gradient_snr": null,
    "credited_ln_improvement_per_measurement_hour": null,
    "credit_status": "pending_ledger_adjudication"
  },
  "evidence": {
    "pairing": "round-level ABBA (...)",
    "per_workload": { "plonk_log14": { "round_ratios": [0.91, 0.92],
                      "proof_digest": "<hex>", "request_ratio": 0.95,
                      "report_sha256s": ["<hex>"] } },
    "reports": ["<paths>"]
  }
}
```

`guards` (judge review, PR 20 era): paired ABBA regression guards over the
full native AIR portfolio, selected from the manifest's path→guard impact
map; pass = upper CI bound ≤ the guard budget, and any failing guard fails
G4. `rust_oracle` records one pinned-oracle verification per scored workload
(required by gates policy; missing or failed verification fails G1). The
`evidence.per_workload` block makes the verdict self-contained: compact
per-round ratios, the CROSS-ARM proof digest (predecessor and candidate
bytes are equal — enforced per round), the request-time ratio, and the
SHA-256 of every raw report, so vanished temp files never orphan a verdict.

`skipped_groups` (additive, registry v2) records every workload group the
manifest disables at run time, with its manifest `disabled_reason` — the same
skip the runner announces on stdout. Empty list when every group ran.

`ledger_evidence` is optional only for an ordinary promotion, for which the
writer supplies the empty defaults shown above. A span audit must explicitly
list the stable observation digests it covers, in ledger order. A direct audit
must explicitly list the exact active credit-event row digests it replaces and
has an empty `covers`; an initial anchor audit may replace an empty set. A
correction sets `supersedes` to the earlier physical row digest and otherwise
retains the same submission/board/class observation identity. The complete
canonical verdict, including this block and any judge signature, is bound into
the ledger's `evidence_sha256`.

`score.resource_portfolio` contains the class-level absolute candidate
geometric mean and ratio evidence for every completely measured resource
dimension. The ledger writer copies `peak_rss_mib` and `energy_j` from these
absolute candidate values; deterministic proof size comes from the integer
`score.portfolio.proof_bytes` summary. Missing resource entries remain
explicitly incomplete and cannot participate in complete-vector Pareto
dominance.

`search_health.decision` is canonicalized and persisted before the measurement
clock begins. Its digest is carried into the verdict. The decision may increase
the per-workload target only when the configured trailing median gradient SNR
is below the manifest threshold, and is bounded by both the configured boost
increment and `maximum_rounds`. Historical cost can lower the target to what
fits the remaining fixed class deadline; boosting never changes that deadline.
`measurement_wall_seconds` is the whole evaluation interval and includes both
arms, benchmark warmups and verification, guards, holdout work, and correctness
oracle time. `actual_rounds` is the sum of the per-workload objective rounds.
The search-health block is diagnostic and is not an input to G1-G5.
Gradient SNR and credited rate remain null in the raw verdict because credit is
not known until ledger adjudication (including freshness, audit replacement,
and shrinkage); the feed fills them from the evidence-bound row.

Judge-added fields (present only on signed judged verdicts fetched from the
`judge-verdicts` branch in the legacy PR flow, or written by the remote
promotion bot into its immutable v2 research record):

- `submission_id` — the submission directory this verdict judges;
- `claimed_divergence` — null, or `{claimed_r, judged_r, gap, judged_ci_half_width}`
  when the claim diverged beyond the judged CI (a recorded finding);
- `judge_signature` — HMAC-SHA256 over the canonical JSON payload; verified by
  the promotion bot before any ledger append.

Remote judged verdicts additionally bind the full `canonical_commit`, original
`source_commit`, and `qualification_receipt` digest. The HTTP API never exposes
the worker-only signed verdict before repository publication.

Gate failures reject the candidate (no score is comparable); per-gate `detail`
carries the margin as a diagnostic, never as a negotiable penalty. `holdout`
is null on claimed runs — only judged runs draw the seeded hold-out.
