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

## Implemented binary boundary

The Zig frontend now imports the complete canonical adapted input through the
versioned `STWZCPI` little-endian format. Version 1 contains, in order:

- initial and final `(pc, ap, fp)` states and unique-PC count;
- the 11-bit public segment mask;
- all 20 opcode state vectors in canonical adapter order;
- memory configuration, address-to-ID, ID-to-big, and ID-to-small tables;
- public memory addresses; and
- the nine builtin segment ranges represented by current stwo-cairo.

The reader uses a 1 MiB streaming buffer, validates every count before
allocation, rejects trailing data, and allocates only the final typed Zig
tables. On `SN_PIE_2` the 152 MiB adapted artifact loads in 0.32 seconds with
about 162 MiB peak RSS. It reproduces 7,833,306 cycles, 8,871,004 address IDs,
146,246 big values, 1,604,405 small values, and 4,166 public memory addresses.

This is an ingestion result, not a proof result. The remaining correctness gate
is a mechanical export of the canonical witness generators and generated AIR.
The symbolic exporter must preserve polynomial constraints and every LogUp
`RelationEntry`; omitting relation multiplicities or values is not acceptable.

The advanced resident branch's strict SN2 preflight establishes the current
mechanical-coverage frontier: all 57 present components are capture-safe, 33
witness lanes have recorded bytecode, and there are no multiplicity coverage
gaps or feed blockers. Its existing detached arena plan is not viable on this
M4 Max: it peaks at 65,025,727,008 bytes (60.56 GiB) during interaction, before
twiddles and runtime overhead. The Zig/Metal port therefore consumes the same
witness ISA but must use its own liveness plan with epoch-local reuse and
spill/recompute; copying the detached arena allocation would fail locally.

`src/frontends/cairo/witness/program.zig` implements the canonical 28-op,
16-byte witness instruction ABI, semantic hash, strict SSA/shape validation,
and the reference interpreter for core arithmetic, table reads, trace writes,
multiplicity feeds, lookup words, and subcomponent words. Computed deduces use
the same explicit fail-closed boundary as the canonical generator.

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
