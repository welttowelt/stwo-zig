# Promotions ledger schema (v1 rows + v2 rows)

`autoresearch/ledger/promotions.tsv` is append-only. CI rejects any PR that
edits or reorders existing rows, and a correction is a new row whose
`supersedes` names the corrected one. Because the file is append-only, the
header is frozen at the v1 column list forever; later schema versions extend
**rows** (extra trailing cells), never the header — every row is read per its
own `schema_version`.

Two writers append: the promote workflow (the judge identity) writes
`verdict_kind=judged` rows from HMAC-verified judged verdicts, and the
maintainer's local `stwo-perf promote-claimed` writes `verdict_kind=claimed`
rows — optimistic adjudication of a merged submission's claimed verdict,
recorded during the pre-judge era. A claimed row is never silently upgraded:
when the judge host activates, the judged re-run appends a new row whose
`supersedes` names the claimed one, and consumers must always display the
kind they were given (site-feed contract: never upgrade claimed to judged).

Columns (tab-separated; v1 columns first, one submission per row):

| column | meaning |
| --- | --- |
| schema_version | integer; rows are read per their own version |
| harness_commit | autoresearch/ tree hash the judge ran |
| epoch | measurement epoch (ledger/epochs.json); ratios never compare across epochs |
| judged_at_utc | ISO-8601 UTC of the judged run |
| commit | promoted repository commit |
| scope | acceptance rung (s3..s5) |
| board | scoring board (schema/scoring.md): core_cpu / core_hybrid / core_metal / heavy_native / heavy_cairo / stream / riscv |
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
| verdict_kind | **v2 only** (24th cell): `judged` (signed judge verdict) or `claimed` (maintainer-adjudicated optimistic row). v1 rows are read as `judged` — only the judge ever wrote them |

The Pareto frontier and anchor-drift budgets are computed from this file by
`stwo-perf frontier`; nothing else is authoritative.
