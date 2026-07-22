# zkVM Soundness & Correctness Roadmap

Tracking document for taking the RISC-V proving lanes — the stwo-zig
`riscv` adapter and the pinned Stark-V oracle
(`ClementWalter/stark-v @ d478f78`) — from "benchmarked and semantically
cross-checked" to "production-grade confidence that the proof attests real
RV32IM execution." Owned here so progress is reviewable; each layer lands
as PRs that reference this file.

## The two properties, kept separate

1. **Semantic correctness** — the VM executes RV32IM exactly per the ISA
   specification. Known failure territory: MULH-family sign handling (the
   adapter fails closed today: `UnsupportedProofFamily
   limitation=stark-v-signed-mulh`), DIV/REM by zero and signed overflow
   (spec: div-by-zero → −1, overflow → dividend), x0 hard-wiring, jump
   alignment, shard-boundary state passing.
2. **Soundness** — the constraint system *forces* that execution: no
   accepting proof exists for a false statement. Failure territory:
   under-constrained AIR cells (missing range checks, unconstrained
   carries, memory-argument holes). **Every test we run today uses an
   honest prover and therefore cannot detect this class at all.**

Current baseline (2026-07-22): committed ELF corpus + CP-11 semantic
oracle parity (public data / final PC / registers / steps); fail-closed
typed refusal of unsupported proof families; fuzz sampling showed exact
step/cycle agreement on all comparable vectors and byte-identical
stwo-zig proofs across independent runs (`riscv-fuzz` session evidence).
Assurance gap vs the native board: native holds **byte-identity** against
audited upstream stwo; the RISC-V lane holds **semantic parity only**, and
the pinned Stark-V CLI cannot serialize proofs (its `Measure` subcommand
documents this), so its "verified" is an in-process assertion.

## Layer 1 — ISA ground truth against the official spec

The CP-11 oracle is self-built and shares no lineage with the spec.

- [ ] Integrate **sail-riscv** (the formal executable ISA spec) and
      **Spike** as second and third executors behind the CP-11 interface.
- [ ] Run the official **riscv-arch-test** suite through all executors;
      commit results as conformance evidence.
- [ ] Trace-level differential fuzzing: constrained-random instruction
      streams (riscv-dv or in-repo generator), comparing every retired
      instruction's (pc, rd, value) across executors — not just final
      state. Millions of programs, seeds committed.
- [ ] Implement the MULH family correctly against the Sail model and
      retire the `stark-v-signed-mulh` refusal; its trigger programs
      become permanent corpus vectors.

**Acceptance:** arch-test suite green on all executors; N ≥ 10^6 fuzzed
programs with zero trace divergences; zero remaining
`UnsupportedProofFamily` refusals for RV32IM.

## Layer 2 — adversarial prover testing (kills the honest-prover blind spot)

- [ ] **Witness-mutation fuzzing:** take valid witnesses, flip one cell
      (register value, decode, memory read), attempt to prove. Any mutant
      that yields an accepting proof is an under-constraint hole. CI gate:
      all mutants rejected, thousands per instruction family.
- [ ] **Malicious-prover harness:** a forked prover that cheats
      deliberately (altered public outputs, skipped instruction, replayed
      stale memory value); verifier must reject every variant.
- [ ] **Exhaustive component checks:** for each instruction family's AIR
      component in isolation, enumerate all limb-width inputs and check
      constraint-satisfaction ⟺ Sail semantics. At 8/16-bit limbs,
      enumeration is feasible and beats sampling.
- [ ] **Proof-malformation fuzzing** (stwo-zig lane, which has
      `--proof-out`): bit-flip / truncate / splice serialized proofs;
      verifier must reject all.

**Acceptance:** mutation and malformation gates in CI, fail-closed; a
committed refuter corpus where every discovered hole becomes a permanent
negative vector.

## Layer 3 — close the structural gaps

- [ ] **Stark-V proof serialization** (upstream contribution or fork):
      an unserializable proof cannot be independently verified; this is a
      production prerequisite, not a nicety.
- [ ] **Independent cross-verifier:** verify stwo-zig RISC-V proofs with
      a second implementation (and Stark-V's once serialization exists).
- [ ] **Explain the verifier cost asymmetry** observed in fuzzing
      (stwo-zig ~97 ms flat vs Stark-V 1.5–3 ms) before production — a
      verifier accepting what it should reject is as fatal as a prover
      bug, and unexplained cost usually means unexamined structure.

## Layer 4 — protocol accounting

- [ ] Compute and publish the **actual security bits** from the deployed
      parameters (FRI queries × log-blowup + proof-of-work grinding;
      conjectured vs proven), per board, in conformance evidence.
- [ ] Audit that the **Fiat-Shamir transcript** binds every commitment
      and every public input (`transcript_state_blake2s` telemetry is the
      hook); document the transcript schedule.
- [ ] **Statement-binding tests:** prove program A, verify against
      program B's statement — must reject; mutate each public field
      (program hash, inputs, outputs, step count) — must reject.

## Layer 5 — formal + external (the production bar)

- [ ] Machine-checked proof (Lean is where the field is converging) that
      AIR-satisfaction implies a valid Sail-model execution — starting
      with the two highest-risk components: the **memory consistency
      argument** and the **instruction decoder**.
- [ ] Two independent external audits (AIR + protocol layers).
- [ ] Public bug bounty scoped to the malicious-prover surface.

## Sequencing

1 → 2 first (cheap, mechanical, and exactly the fail-closed evidence
machinery this repo already runs for performance, pointed at soundness);
then 3 (serialization + cross-verifier), 4 (accounting is documentation
plus tests), and 5 once layers 1–4 hold. The bar for "production ready"
is every checkbox above landed or explicitly rejected with reasoning
recorded in this file's history.
