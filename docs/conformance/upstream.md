# Upstream Pin Ledger

This file is the single source-pin ledger for the repository's independent Rust correctness
oracles. A revision applies only to the compatibility lane that names it. Native Stwo acceptance
does not establish Cairo acceptance, and Cairo acceptance does not establish Native Stwo parity.

## Native Stwo Lane

This lane governs the backend-neutral Native Stwo API, protocol, proof, and verifier surface.
The field names below are retained for compatibility with the Native parity and upstream-surface
checkers.

- Upstream repository: `https://github.com/starkware-libs/stwo`
- Pinned commit: `a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2`
- Pin date: `2026-02-07`

## Cairo Lane

This lane governs Cairo AIR, statement, proof, and canonical `verify_cairo` acceptance. Its oracle
is a composition of two exact Git revisions, so every Cairo proof envelope, verifier receipt,
benchmark report, and generated semantic artifact must bind both revisions.

- Stwo-Cairo repository: `https://github.com/teddyjfpender/stwo-cairo`
- Pinned Stwo-Cairo commit: `dcd5834565b7a26a27a614e353c9c60109ebc1d9`
- Stwo repository: `https://github.com/teddyjfpender/stwo`
- Pinned Cairo Stwo commit: `9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2`

The Cairo lane is accepted only by the canonical Rust `verify_cairo` implementation built from
that exact revision pair. Zig scalar, SIMD, Metal, or Zig-verifier agreement cannot override its
rejection.

## Native Stwo Parity Slice

The current Native Stwo increment targets:

- `core/fields/*`
- `core/fri`
- `core/pcs/quotients`
- `core/pcs/verifier`
- `core/pcs/utils`
- `core/proof`
- `core/verifier`
- `core/vcs/verifier`
- `core/test_utils`
- `core/vcs/hash`
- `core/vcs/merkle_hasher`
- `core/vcs/utils`
- `core/vcs/test_utils`
- `core/vcs_lifted/merkle_hasher`
- `core/vcs_lifted/verifier`
- `core/vcs_lifted/test_utils`
- `prover/vcs/prover`
- `prover/vcs/ops`
- `prover/vcs_lifted/prover`
- `prover/vcs_lifted/ops`
- `prover/line`
- `prover/air` (accumulation + component-prover slices)
- `prover/prove` (prepared-samples + sampled-points + component-driven prove_ex slices)
- `prover/fri` (full fri prover commit/decommit flow + layer decommit slices)
- `prover/pcs` (quotient-ops + commitment tree/decommit + prove-values + prove-values-from-samples slices)
- `prover/channel` (logging channel slice)
- `prover/lookups` (utils + mle + sumcheck + gkr verifier + gkr prover prove-batch slice)
- `prover/poly` (module + twiddles + circle evaluation/poly/secure_poly/ops slices)
- `prover/secure_column`
- `tracing/mod`

## Upgrade Policy

1. Name the compatibility lane being upgraded; never reuse evidence from another lane.
2. Bump every exact revision that composes that lane's Rust oracle in this ledger.
3. Update manifests, lockfiles, constants, proof envelopes, receipts, and generated artifacts that
   carry those revisions.
4. Re-run vector generation for all committed fixtures in the affected lane.
5. Require the affected Zig parity, bidirectional interoperability, and exact Rust-oracle tests to
   pass before merging.
6. Document any intentional divergence in `docs/conformance/divergence-log.md`.
