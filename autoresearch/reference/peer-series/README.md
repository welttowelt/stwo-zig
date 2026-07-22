# Peer-relative audit points

`measure_peer_series.py` writes one immutable JSON point per stwo-zig audit
commit under `runs/`. Each v2 point covers the exact PR6 100-column
wide-Fibonacci shape at log sizes 14, 16, 18, 20, and 22 across peer CPU,
peer Metal, stwo-zig CPU, and stwo-zig Metal.

Verified-request and cold-process boundaries are independently gated. CPU and
Metal each run at least seven peer/candidate A-B-B-A rounds. Verified requests
start before input construction and include canonical proof encoding, hashing,
and independent verification after ten warmups. Cold samples use a fresh
process with zero warmups and include backend initialization and Metal
source-JIT. `prove_ms` is diagnostic only.

Proof equality is required within the peer CPU/Metal pair and within the
stwo-zig CPU/Metal pair; the series does not claim byte equality between Rust
and Zig codecs. Protocol and statement digests must match across all lanes.

Run from a clean audit commit on a unified-memory macOS host:

```sh
python3 autoresearch/reference/measure_peer_series.py
```

Log 18 and 20 stwo-zig invocations use `--resource-profile large`; log 22 uses
the explicit `extreme` profile for exactly 419,430,400 committed cells and
6,710,886,400 accounted bytes. A checkout without either admitted profile
fails rather than silently omitting a losing size.

This series is necessary but not sufficient for PR6 Supremacy. Its v2 status
remains diagnostic until the exact Blake, Plonk, fixed-wide-Fibonacci, and
state-machine matrix plus Metal synchronization telemetry and a locked-M5
judged verdict exist. Historical v1 points remain immutable and use
`peer-series-point.schema.json`; v2 uses `pr6-wide-series-point.schema.json`.
