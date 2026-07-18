# Promotions ledger schema (v1)

`autoresearch/ledger/promotions.tsv` is append-only. Only the promote workflow
(the judge identity) appends; CI rejects any PR that edits or reorders existing
rows, and a correction is a new row whose `supersedes` names the corrected one.

Columns (tab-separated, one judged submission per row):

| column | meaning |
| --- | --- |
| schema_version | integer; rows are read per their own version |
| harness_commit | autoresearch/ tree hash the judge ran |
| epoch | measurement epoch (ledger/epochs.json); ratios never compare across epochs |
| judged_at_utc | ISO-8601 UTC of the judged run |
| commit | promoted repository commit |
| scope | acceptance rung (s3..s5) |
| workload_class | small / wide / deep |
| outcome | `promoted` / `neutral` / `rejected` — only promoted rows shape the frontier |
| judged_r | geometric-mean paired ratio (<1 improves) |
| ci_low / ci_high | 95% bootstrap CI of judged_r |
| prove_ms / native_mhz / peak_rss_mib | per-dimension medians on the declared class |
| waits / dispatches | Metal telemetry when applicable, else empty |
| energy_j | joules per proof when captured, else empty |
| gates | `G1..G5:pass` or the failing gate list (a failing row records a rejection) |
| holdout | `pass`/`fail` plus the generator seed, e.g. `pass;seed=180734` |
| submission_id | submissions/<dir> name |
| predecessor | the paired A-arm commit |
| supersedes | empty, or the judged_at_utc+commit of the row this corrects |

The Pareto frontier and anchor-drift budgets are computed from this file by
`stwo-perf frontier`; nothing else is authoritative.
