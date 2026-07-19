# Upstream divergence ledger

This is the operative ledger for intentional differences between the Zig
implementation and its pinned Rust correctness oracles. A difference remains a
release blocker unless its row explicitly says otherwise. Removing a difference
must remove the row in the same commit.

## Active divergences

| Lane | Boundary | Current Zig behavior | Pinned-oracle behavior | Release status |
| --- | --- | --- | --- | --- |
| RISC-V | PCS geometry | Uses the repository's lifted PCS and folded query points. | Stark-V uses its upstream commitment/evaluation geometry. | Allowed only with the committed composition self-check and proof mutation coverage; not a semantic waiver. |
| RISC-V | Public statement | The production verifier adds the exact public CPU-state, register, memory-I/O, and Merkle-root compensation to the canonical interaction claim after drawing the twelve relation pairs. Retained production buffers also demonstrate independent per-domain cancellation. The statement still omits segment ordinal/first/last role, and the production malicious-proof matrix does not yet mutate every public scalar, vector element, root presence, I/O shape, and segment role. | Stark-V closes register, memory, root, input, output, and CPU-state buses with public fractions. | Blocks adapter release until segment role is proof-bound and the complete field-by-field production mutation matrix rejects with exact classes; transcript or artifact-digest rejection alone is not algebraic closure evidence. |
| RISC-V | Interaction transcript | The production claim phase mixes the canonical statement, roots, main claim, a domain-separated shard manifest, a schema-v3 fixed 10-bit PoW nonce, twelve independent relation pairs, and the canonical interaction claim/root. A compile-time channel substitution records the live prover and verifier byte events through downstream PCS with zero default-path overhead; exact root and relation-draw mutations are rejected and reverted. Separate CLI processes prove and verify a bound artifact, but that receipt neither records their channel-event streams nor identifies a separately built verifier executable. | Stark-V uses the same shared prefix and release PoW value but has no shard-manifest extension; its generated constant also drops PoW to 1 bit in debug builds. | The shard extension blocks byte-identical proof-wire parity; a candidate-bound receipt comparing production channel events across the artifact boundary and recording independently built prover/verifier identities still blocks adapter release. |
| RISC-V | Opcode and infrastructure AIR | State and raw-program cross-shard constraints are integrated; base ALU semantics and public boundary modules are not yet component-integrated, and other infrastructure remains silent. | Stark-V constrains every enabled family plus memory, range, bitwise, Merkle, and Poseidon relations. | Blocks adapter release and autoresearch enablement. |
| RISC-V | Signed `MULH` carry relation | Zig reproduces the pinned witness formula and keeps the `mulh` family trace-incompatible: `MULH(-1, -1)` yields canonical `carry_4 = 2,139,096,569`, which cannot enter the required `[0, 2^11)` lookup. The implementation site carries `FIX(stark-v-signed-mulh)` with the exact failure and unsound-witness mechanism. | Stark-V adds `sign * 128` to each top operand byte before the carry recurrence, while the sign witnesses are not constrained to the operand top bits. Its test named `test_prove_opcode_mulh` loads MULHU output, so no signed-high proof regression covers the defect. | Allowed only with exact d478f783 witness/export parity, the explicit `FIX(stark-v-signed-mulh)` marker, and fail-closed production handling of the affected family. This inherited pin limitation does not require an upstream fix for adapter release. |

## Closure requirements

Every release-blocking row requires prover/verifier integration, an adversarial
proof-level rejection test, and evidence against the exact pinned Rust oracle.
Internal Zig prove/verify consistency is necessary but cannot close a row by
itself.
