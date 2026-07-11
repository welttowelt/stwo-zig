# Cairo to Zig prover boundary

The `generic-backend` branch of `teddyjfpender/stwo-cairo` separates Cairo
execution from proving as follows:

1. `cairo-vm` executes the PIE.
2. `stwo-cairo-adapter` produces `ProverInput`.
3. Cairo witness generators turn that input into component columns.
4. A generic STWO backend interpolates, commits, evaluates constraints, runs
   LogUp, and opens FRI.

The Zig integration keeps that boundary but does not embed the Rust prover.
Rust may temporarily execute Cairo and export adapted input; all witness, AIR,
PCS, transcript, and FRI work after the import boundary belongs to Zig/Metal.

## Imported data

The adapted input contains:

- initial and final `(pc, ap, fp)` states;
- per-opcode state-transition arrays;
- memory configuration, address-to-ID table, large felt values, and small
  values;
- unique program-counter count and public memory addresses;
- builtin segment data; and
- the 11-bit public-segment presence context.

The production interchange format must be a versioned, little-endian binary
container. JSON remains a parity/debug format only: multi-million-step PIEs
make a DOM-style JSON import an unacceptable memory multiplier.

## Zig capability mapping

The Rust branch's backend contract is not one monolithic device trait. The Zig
transaction engine needs the same explicit capabilities:

| Cairo capability | Zig owner |
| --- | --- |
| opcode and builtin witness generation | Cairo frontend plus Metal trace arena |
| preprocessed trace generation | Cairo frontend, cached resident columns |
| M31 column conversion | resident buffer importer |
| circle interpolation/evaluation | Metal transform engine |
| LogUp finalization | Metal interaction engine |
| constraint evaluation | generated Zig AIR plus Metal kernels |
| commitment and channel | existing transaction engine |
| FRI folding and opening | resident Metal PCS |

Generated Cairo AIR files are treated as generated protocol artifacts. They
must be translated mechanically from the canonical layouts and differential
tested; they are not hand-rewritten or optimized by changing constraints.

## Acceptance gate

A Cairo performance number is reportable only when one SN PIE produces a proof
accepted by the reference verifier with identical public claim, component log
sizes, commitment roots, sampled values, and transcript challenges. The first
benchmark target is `SN_PIE_2.zip`, whose adapted execution contains 7,833,306
cycles. Adapter-only or synthetic traces do not count as Cairo proving.
