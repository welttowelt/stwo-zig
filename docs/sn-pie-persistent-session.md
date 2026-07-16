# Persistent SN PIE Metal Session

This document describes the current JSONL service boundary. The full production,
resource, command-graph, dataflow, and queue architecture is
`docs/sn-pie-metal-production-architecture.md`.

## Protocol v4

`scripts/sn_pie_metal_session.py` and `src/metal_prover_session_protocol.zig`
implement strict `stwo-zig-metal-prover-session` protocol version 4. Exactly one
proof may be in flight. Sequences are monotonic, request IDs are unique, frames
are exact-key and exact-type checked, and every prior wire version fails closed.
The committed benchmark report remains schema version 3; wire version and report
schema are deliberately separate.

Every artifact is either an absolute admission path or an authenticated service
object:

```text
{"path": <absolute path>}
{"object_id": <lowercase SHA-256>, "bytes": <positive u64>,
 "diagnostic_path": <absolute path>}
```

The daemon admits path inputs into a private content-addressed store. A later
object reference is accepted only when its digest, byte count, stored identity,
and role agree. Transcript and quotient references are an optional pair and are
absent on the reference-free path.

Protocol v4 adds a mandatory canonical Rust verifier identity to `ready` and
mandatory digest-bound verifier evidence to every result and committed report.
Startup therefore requires exactly:

```text
metal-arena-session --jsonl
  --rust-verifier <release-stwo-cairo-verifier-adapter>
  --rust-verifier-lockfile <Cargo.lock>
```

The service requires adapter ABI `STWZCVE/1`, adapter version `0.1.0`, lockfile
SHA-256
`72ee6a80235ff78a6e2c1724a8c6d1c45798c2a11c1c1539bc675af066b0e31c`,
`stwo-cairo` revision `dcd5834565b7a26a27a614e353c9c60109ebc1d9`, and
Stwo revision `9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2`. The executable
and lockfile are measured, copied into the private store with read-only modes,
remeasured, and checked again around every invocation. These are measurement
pins; their manifest source chains remain `unattested` until deployment
authorization and generator provenance are added.

## Proof Transaction

One successful request performs this ordered transaction:

1. Validate the exact request and admit or resolve every artifact.
2. Prove and resident-verify through the reused in-process Metal Runtime.
3. Write the raw proof, Zig-owned compact statement, and runner report into a
   random per-request private `0700` scratch directory.
4. Derive the 112-byte compact protocol from the runner's exact proof layout.
5. Stream a strict four-section `STWZCVE/1` envelope whose provenance binds the
   adapted input, artifact manifest, runner, backend, protocol, statement, and
   proof digests.
6. Invoke the copied Rust verifier by direct argv with an empty environment. A
   30-second watchdog terminates its process group, waits two seconds, then
   kills and reaps it if necessary.
7. Parse at most 1 MiB of exact result JSON and require zero exit,
   `verified=true`, exact pins, and exact protocol/statement/proof/provenance
   digests.
8. Commit prepared-state ownership, stage the accepted proof, write the final
   report, and publish proof then report with exclusive no-replacement links.
9. Emit a verified result only after the client-visible outputs are committed.

Rust rejection, timeout, malformed output, identity drift, digest mismatch,
publication collision, or report-publication failure fails the transaction. No
requested report survives, and a proof published before a report failure is
removed. The prepared state is poisoned or discarded on a failed transaction.

The Python client independently rehashes the committed proof, checks the input,
recomputes MHz, validates the canonical manifest and artifact object map,
requires report/result Rust evidence equality, binds the Rust protocol digest to
`cli_report.proof_layout`, and compares per-proof verifier identity with the
identity announced at `ready`.

## Queue Contract

`PersistentSessionExecutor` sends blocks in strict sequence through one daemon.
The outer queue recomputes the published proof SHA-256 and independently
revalidates the exact 17-field Rust evidence. For a persistent result it also
requires the evidence returned by the validated session client to equal the
evidence reread from the report. Missing, false, extra-field, digest-drifted, or
replacement evidence fails that block, stops the queue, and withholds every
aggregate MHz field.

Queue throughput is accepted only after every block passes both resident and
canonical Rust verification and the daemon returns an exact clean `closed`
frame with the completed sequence count and zero exit status. Prove-only MHz,
session-service MHz, first-block latency, and sustained end-to-end MHz remain
separate metrics.

The checked-in manifest uses the required command. Build it from the repository
root with:

```sh
cargo build --release --locked \
  --manifest-path tools/stwo-cairo-verifier-rs/Cargo.toml \
  --bin stwo-cairo-verifier-adapter
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-arena-session metal-arena-plan -Doptimize=ReleaseFast
```

The next live gate is deliberately bounded to one SN2 proof using
`scripts/sn_pie_metal_queue.example.json`. A randomized 10-block queue follows
only after that proof passes. A 100-block queue follows after the machine cools
and the 10-block memory/reset evidence is accepted.

## Offline Verification

The 2026-07-16 protocol-v4 wrap-up passed without running Metal:

```text
compact Zig interchange                         6/6
protocol-v4 Zig parser                          7/7
focused Zig session surface                    19/19
Python repository suite                       195/195
Rust adapter library and CLI                    33+4
ReleaseFast metal-arena-plan/session builds     passed
```

The release adapter also reconstructed and canonically verified the existing
8,410,304-byte SN2 proof, with proof SHA-256
`5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052`.
The smoke result used protocol digest
`539751a53034c0b279bd023a04a54b203cda5a9a4acdbba83159a9790dc1cfa4`,
statement digest
`36c41bd4fd5bb256dcef94d15084e46dc1c30c1b99f82de1036162dfb9fb2623`,
and reported 34,612,959 ns in the Rust adapter.

This establishes the verifier and offline service contract, not live protocol-v4
Metal proving speed. The latest Metal MHz figures in the architecture document
were measured through protocol v3 and must not be relabeled as v4 results.
