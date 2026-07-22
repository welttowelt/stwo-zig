# Cross-flavor parity artifact

Date: 2026-07-22 · branch head at time of run: fd264e5
Host: Apple M4 Pro, macOS (native run — parity is host-independent by
construction; phone runs must reproduce these digests).

Statement: wide_fibonacci log_n_rows=10 sequence_len=8, protocol
functional (pow_bits 10, log_last_layer 0, log_blowup 1, n_queries 3).

| flavor | command | proof bytes | sha256 |
|---|---|---|---|
| zig  | `native-proof-bench-cpu --example wide_fibonacci --log-n-rows 10 --sequence-len 8 --protocol functional --warmups 0 --samples 1` | 24965 | 91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700 |
| rust | `cargo run --release --example print_report` (same params) | 24965 | 91741aec956846d52e50f7b8fef3ac93195dbcd76cdb89e25ed33a148bea5700 |

**Byte-identical across implementations.** The zig bench's proof encoding
is the canonical wire JSON — the same bytes the Rust↔Zig parity oracle
compares — so one leaderboard can host both flavors with digest equality
as the admission gate. A phone row is valid iff its digest matches this
table's value for the pinned statement (or the epoch's reference vector).
