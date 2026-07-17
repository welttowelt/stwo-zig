# Cairo prover entrypoint

`src/frontends/cairo/prover.zig` is the public orchestration boundary for a
Cairo program proof. It replaces the former placeholder that returned
`ProvingFailed` after constructing only a partial legacy claim.

The boundary performs these operations in order:

1. Require an exact backend kind. A Metal request cannot silently use SIMD or
   scalar execution.
2. Authenticate the adapted `STWZCPI` input by SHA-256 and parse it with the Zig
   Cairo adapter.
3. Authenticate the semantic-pack manifest and every projected `STWZWIT`,
   `STWZFED`, `STWZREL`, `STWZFIX`, `STWZPPC`, and composition artifact.
4. Validate component order, counts, dependency closure, preprocessed identity
   order, projection identity, composition plan hash, and artifact digests.
5. Revalidate inode, size, modification time, and change time after parsing and
   immediately before dispatch, without repeating multi-gigabyte digest passes.
6. Derive the canonical compact public statement from the adapted input and
   composition schedule before backend dispatch.
7. Ask the selected backend to publish one exclusive `STWZCVE/1` envelope.
8. Hash the immutable envelope, invoke the canonical Rust verifier adapter, and
   accept only exact evidence for `verify_cairo` at the pinned Stwo-Cairo and
   Stwo revisions.
9. Rehash the envelope after verification and reject mutation or identity
   drift.

The backend interface is deliberately small. It receives a borrowed
`PreparedProgram`, which owns the parsed input, validated semantic artifacts,
and derived compact statement for the duration of one call. Backend-specific
device resources, caches, schedules, and command graphs remain behind the
backend implementation.

## Concrete development adapters

The public contract has two concrete process adapters:

- `integrations.cairo_metal.process_backend.MetalBackend` authenticates the
  arena runner, schedule, composition program, preprocessed evaluations, and
  tree-zero Merkle object once at initialization. Each proof rechecks their
  file identities, invokes `metal-arena-plan` with direct argv, validates the
  reference-free runner report, and publishes the raw resident proof as an
  `STWZCVE/1` envelope.
- `frontends.cairo.rust_oracle.RustOracle` authenticates the isolated Rust
  verifier executable and exact `Cargo.lock`, invokes it with direct argv and
  an empty environment, and accepts only its bounded, exact-schema result.

The Metal child inherits a scrubbed environment. Every `STWO_ZIG_*` variable
is removed before the backend installs its explicit proving configuration.
The backend API has no field for a target proof, transcript, quotient,
decommitment, component limit, or diagnostic reference. Runner evidence must
show self-derived statement construction, proof assembly, resident proof
verification, quotient/FRI/decommitment execution, valid final FRI degree, and
no parity fixture or legacy transcript bootstrap.

Runtime proof geometry is not fixed to SN2. The adapter derives the maximum
degree, FRI tree count, decommitment record count, and all four trace-tree
column counts from the authenticated program composition and fixed identities.
The runner proof decoder uses that same runtime FRI count, so a Fib-like
21-degree program carries seven FRI roots while the 24-degree SN2 layout carries
eight. The runner's emitted compact statement must exactly equal the statement
prepared by the frontend before its proof bytes can be enveloped.

The current adapter deliberately uses the one-shot arena process. The existing
long-lived session still owns an SN2-specific envelope boundary; routing a
runtime Cairo proof through it would mislabel non-SN2 geometry. Session reuse
can replace the one-shot boundary only after it returns or wraps proofs under
the same authenticated runtime protocol contract.

## Admission status

Semantic-pack version 2 is selected using a Rust reference proof. It is useful
for differential development and Rust-oracle parity, but it is
`proof_derived`. The public entrypoint therefore rejects it immediately in
`production` admission mode. The current engine can run it only under the
explicit `development_oracle_parity` mode, and the resulting receipt reports
`production_eligible=false` even when Rust verification succeeds.

The current development backend consumes artifact paths. Admission hashes each
artifact once, retains its authenticated file identity, and checks that identity
after parsing and immediately before dispatch. This avoids repeated 2 GiB
coefficient hashing, but it is not a production-grade immutable handoff: a
future production backend must consume retained read-only handles or
content-addressed immutable snapshots rather than reopen mutable paths.

A production-admissible successor must bind a complete source chain from the
raw PIE, Cairo VM execution, adapter, AIR registry, and deterministic semantic
artifact generators. It must generate its schedule from those authenticated
inputs. A target Rust proof, transcript, quotient, or decommitment fixture must
not be a proving input.

The Rust oracle is the final acceptance contract, not an optional diagnostic.
The pinned revisions are:

- Stwo-Cairo: `dcd5834565b7a26a27a614e353c9c60109ebc1d9`
- Stwo: `9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2`

Zig scalar, SIMD, Metal, or Zig-verifier agreement cannot override a rejection
from that exact Rust `verify_cairo` implementation.
