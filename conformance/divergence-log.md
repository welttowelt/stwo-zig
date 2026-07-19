# Upstream divergence ledger

This is the operative ledger for intentional differences between the Zig
implementation and its pinned Rust correctness oracles. A difference remains a
release blocker unless its row explicitly says otherwise. Removing a difference
must remove the row in the same commit.

## Active divergences

| Lane | Boundary | Current Zig behavior | Pinned-oracle behavior | Release status |
| --- | --- | --- | --- | --- |
| RISC-V | PCS geometry | Uses the repository's lifted PCS and folded query points. | Stark-V uses its upstream commitment/evaluation geometry. | Allowed only with the committed composition self-check and proof mutation coverage; not a semantic waiver. |
| RISC-V | Interaction transcript | After the shared Stark-V prefix, Zig mixes a domain-separated shard manifest before the fixed schema-v3 10-bit PoW nonce, twelve relation pairs, interaction claim/root, and downstream PCS. The production prover and verifier expose caller-owned channels; their exact byte-event traces agree, and independent CLI processes bind the final channel digest plus draw counter, implementation commit/dirty state, and executable SHA-256 in strict receipts. | Stark-V has no shard-manifest extension and its generated constant drops PoW to 1 bit in debug builds. | Allowed only with the committed full-path event-symmetry test, shared-prefix Rust parity, fixed release security parameters, transcript-state draw-count regression, and a fresh separate-process receipt from the exact candidate executable. Byte-identical proof-wire parity is not claimed after the documented extension. |
| RISC-V | Signed `MULH` carry relation | Zig reproduces the pinned witness formula and keeps the `mulh` family trace-incompatible: `MULH(-1, -1)` yields canonical `carry_4 = 2,139,096,569`, which cannot enter the required `[0, 2^11)` lookup. The implementation site carries `FIX(stark-v-signed-mulh)` with the exact failure and unsound-witness mechanism. | Stark-V adds `sign * 128` to each top operand byte before the carry recurrence, while the sign witnesses are not constrained to the operand top bits. Its test named `test_prove_opcode_mulh` loads MULHU output, so no signed-high proof regression covers the defect. | Allowed only with exact d478f783 witness/export parity, the explicit `FIX(stark-v-signed-mulh)` marker, and fail-closed production handling of the affected family. This inherited pin limitation does not require an upstream fix for adapter release. |

## Closure requirements

Every release-blocking row requires prover/verifier integration, an adversarial
proof-level rejection test, and evidence against the exact pinned Rust oracle.
Internal Zig prove/verify consistency is necessary but cannot close a row by
itself.
