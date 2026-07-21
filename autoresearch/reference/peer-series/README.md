# Peer-relative audit points

`measure_peer_series.py` writes one immutable JSON point per stwo-zig audit
commit under `runs/`. Each point covers the exact 100-column wide-Fibonacci
shape at log sizes 14, 16, 18, and 20 across peer CPU, peer Metal, stwo-zig
CPU, and stwo-zig Metal.

The primary metric is each implementation's verified request time. Exact stage
inclusions remain attached to every sample. Proof equality is required within
the peer CPU/Metal pair and within the stwo-zig CPU/Metal pair; the series does
not claim byte equality across different protocol implementations.

Run from a clean audit commit on a unified-memory macOS host:

```sh
python3 autoresearch/reference/measure_peer_series.py
```

Log 18 and 20 stwo-zig invocations use `--resource-profile large`. A checkout
without that admitted profile fails rather than silently omitting the losing
sizes.
