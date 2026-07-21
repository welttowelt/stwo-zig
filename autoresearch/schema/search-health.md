# Search-health evidence schema (v1)

Search health measures whether the optimization loop can still resolve useful
effects and how much credited progress it obtains per complete measurement
hour. It is diagnostic: no search-health value can pass, fail, weaken, or
replace correctness, resource, guard, holdout, or oracle gates.

## Pure metrics

For a measured ratio `R` with interval `[L, H]`, let `p = ln(R)`. Directional
log uncertainty is the confidence radius toward neutral:

```text
u = ln(H) - p       when p < 0
u = p - ln(L)       when p > 0
u = (ln(H)-ln(L))/2 when p = 0
```

Let `c` be the signed log effect actually credited by the Metrics-v2 ledger
engine after gates, evidence kind, correction/audit replacement, and shrinkage
rules are applied. Then:

```text
gradient_snr = abs(c) / u
credited_ln_improvement = -c
credited_ln_improvement_per_measurement_hour = -c / (wall_seconds / 3600)
```

A regression therefore has a negative credited improvement rate. Zero credit
has zero gradient SNR even when the raw point estimate is nonzero. Inputs must
be finite, ratios and CI bounds positive, `L <= R <= H`, and `u > 0`.

## Manifest policy and decision

`gates_policy.search_health` contains exactly:

| field | meaning |
| --- | --- |
| `trailing_window` | number of prior available class observations in the median/cost window |
| `gradient_snr_threshold` | boost threshold; the committed policy is `2.0` |
| `auto_boost_rounds` | maximum rounds added to the ordinary per-workload `max_rounds` in one decision |
| `maximum_rounds` | absolute per-workload target ceiling |

Before measurement, the runner reads evidence-bound history for the selected
manifest board/class and writes `search-health-decision.json`. A trailing median
below the threshold chooses at most
`min(configured + auto_boost_rounds, maximum_rounds)`. The median historical
complete-wall seconds per measured workload round bounds that target again by
the remaining fixed class deadline. Insufficient history and medians at or
above threshold do not boost. The decision records its reason, target, deadline,
cost estimate, workload count, and canonical digest before the measurement clock
starts. Runtime command timeouts enforce the same absolute monotonic deadline.

## Verdict and ledger binding

The verdict block is documented in `verdict.md`. Its total wall interval begins
after the decision is persisted and ends after objective arms, warmups,
verification, guards, judged holdout, and correctness oracle work. It may include
additional runner bookkeeping, making the rate conservative. The v3 ledger
copies this value into `measurement_seconds` and the objective round sum into
`measurement_rounds`; publication requires exact round equality and wall-second
equality to the ledger's six-decimal representation. The ledger
`evidence_sha256` selects the exact verdict, so submissions with several verdict
files cannot be confused by board/class naming.

## Feed projection

`search_health.boards.<board>.classes.<class>` publishes:

- availability and available/unavailable counts;
- trailing median gradient SNR, wall hours, credited log improvement, and rate;
- the latest configured and actual rounds plus boost reason and target;
- an immutable point time series, including honest unavailable legacy points;
- a decay series whose value at each point is the aggregate credited log
  improvement divided by aggregate wall hours over the configured trailing
  window.

Board/class keys are the union of manifest-owned classes and historical rows;
the feed does not hardcode a class vocabulary. v1/v2 ledger rows predate complete
wall and decision evidence and publish as `available=false` with reason
`legacy_row_has_no_search_health_evidence`. Missing or invalid v3 claimed
evidence also remains visible and unavailable. Missing or invalid v3 judged
evidence fails feed publication closed.
