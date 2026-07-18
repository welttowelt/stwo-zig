# Upstream divergence ledger

This is the operative ledger for intentional differences between the Zig
implementation and its pinned Rust correctness oracles. A difference remains a
release blocker unless its row explicitly says otherwise. Removing a difference
must remove the row in the same commit.

## Active divergences

| Lane | Boundary | Current Zig behavior | Pinned-oracle behavior | Release status |
| --- | --- | --- | --- | --- |
| RISC-V | PCS geometry | Uses the repository's lifted PCS and folded query points. | Stark-V uses its upstream commitment/evaluation geometry. | Allowed only with the committed composition self-check and proof mutation coverage; not a semantic waiver. |
| RISC-V | Program relation | Proof-integrated bus binds `(pc, raw instruction word)`; decoded five-field tuple support is standalone. | Stark-V binds `(pc, opcode, value_1, value_2, value_3)` to a decoded program table and Merkle root. | Blocks adapter release. |
| RISC-V | Relation challenges | Proof-integrated buses share the legacy relation-ID challenge object; exact per-relation `(z, alpha)` draws are standalone. | Stark-V draws 12 independent pairs in schema order and combines by alpha powers. | Blocks adapter release. |
| RISC-V | Public statement | Public data is transcript-bound; exact public LogUp compensation is standalone. | Stark-V closes register, memory, root, input, output, and CPU-state buses with public fractions. | Blocks adapter release. |
| RISC-V | Interaction transcript | Interaction claims/root follow the current generic Zig proof sequence and omit Stark-V's interaction PoW stage. | Stark-V mixes public data, commitments, claims, PoW, relation draws, interaction claim, then interaction commitment in its pinned order. | Blocks Stark-V proof-wire parity and adapter release. |
| RISC-V | Opcode and infrastructure AIR | State and raw-program cross-shard constraints are integrated; base ALU semantics and public boundary modules are not yet component-integrated, and other infrastructure remains silent. | Stark-V constrains every enabled family plus memory, range, bitwise, Merkle, and Poseidon relations. | Blocks adapter release and autoresearch enablement. |

## Closure requirements

Every release-blocking row requires prover/verifier integration, an adversarial
proof-level rejection test, and evidence against the exact pinned Rust oracle.
Internal Zig prove/verify consistency is necessary but cannot close a row by
itself.
