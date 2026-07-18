# RISC-V public-field constraint coverage audit

CP-07 closure evidence for `conformance/2026-07-18-riscv-release-goal.md`.
For every field of `PublicData`, this table names the mechanism that binds it
beyond transcript mixing (every field is Fiat-Shamir-mixed by
`PublicData.mixInto` in the pinned oracle's order — mixing alone proves
nothing about the trace and is not accepted as coverage below).

| Field | Bus / constraint binding | Status |
| --- | --- | --- |
| `initial_pc` | registers-state boundary emit at clock 1; consumed by the first executed row's state-chain pair | BOUND |
| `final_pc` | registers-state boundary consume at clock+1; emitted by the last executed row | BOUND |
| `clock` | closes the state-chain telescope (boundary consume clock); statement consistency check ties it to `total_steps` | BOUND |
| `initial_regs[0..32]` | memory-access boundary emits every register's clock-0 word; first access-site consume must match | BOUND |
| `final_regs[0..32]` | memory-access boundary consumes every register at its final clock; last access-site emit must match | BOUND |
| `reg_last_clock[0..32]` | the boundary consume clock; a wrong clock breaks pairing with the last access-site emission | BOUND |
| `program_root` | Merkle relation emit exists, but the Merkle bus consume side is NOT active | RELEASE BLOCKER (per module header; CP-06) |
| `initial_rw_root` | same as `program_root` | RELEASE BLOCKER (CP-06) |
| `final_rw_root` | same as `program_root` | RELEASE BLOCKER (CP-06) |
| `io_entries.input_start`, `input_len` | address arithmetic of the public input emissions (wrapping add, saturating mul, oracle-exact) | BOUND through input_words emissions |
| `io_entries.input_words` | memory-access boundary emits each word at clock 0; the guest's first reads must consume them | BOUND |
| `io_entries.output_len_addr`, `output_data_addr`, `output_len` | classify the public-output words the private final table excludes | BOUND through output_words consumption |
| `io_entries.output_words` | memory-access boundary consumes each word at its recorded final clock; the guest's last writes must emit them | BOUND |

Known envelope limits (not defects, oracle-shared):

- Guests writing input-region words beyond the provided input are outside the
  pinned oracle's supported envelope (its `include_initial = !is_input` rule
  leaves such words publicly unowned). The Zig port matches the oracle
  exactly rather than diverging the transcript.
- Root fields remain transcript-bound only until the Merkle bus closes
  (CP-06); the registry flip is blocked on that among other checkpoints.

Verified by: per-domain independence test in `air/public_logup.zig`
("relation domains are independent..."), the e2e prove/verify roundtrip,
and the memory-bus global-cancellation check in `verifyRiscVWithEngine`.
