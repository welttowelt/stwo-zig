# RISC-V LogUp Placement Audit

Status: **operative CP-05 implementation specification; release blocker**

Oracle: Stark-V commit `d478f783055aa0d73a93768a433a3c6c31c91d1c`

This audit fixes the exact relation-entry order that the Zig implementation must
reproduce. Algebraically equivalent regrouping is insufficient: relation entries
are paired into committed cumulative columns in declaration order, so regrouping
changes the interaction commitment, component claimed sum transcript, OODS mask,
and the component-by-component oracle accumulator required by CP-05.

## Authoritative sources

- Relation order, arities, opcode entries, signs, and tuple order:
  `crates/air/src/schema.rs:3-1439` at the pinned Stark-V commit.
- Generated clock-gap component: `crates/stwo-macros/src/define_air.rs:20-47`
  and `:238-250`.
- Default pair batching and singleton override:
  `crates/stwo-macros/src/trace_tables.rs:101-150` and `:1089-1178`.
- Preprocessed multiplicity counter and balancing component:
  `crates/stwo-macros/src/relations.rs:442-505` and
  `crates/stwo-macros/src/components.rs:983-1055`.
- Poseidon2 narrow, wide, and atomic-I/O placement:
  `crates/stwo-macros/src/air_fns.rs:1691-1832`.
- Public compensation: `crates/prover/src/public_data.rs:171-273`.
- Component and interaction-tree order:
  `crates/prover/src/components/mod.rs:6-37` and
  `crates/stwo-macros/src/components.rs:514-550`.

All paths above are relative to the pinned Stark-V checkout, not this repository.

## Relation schema

The relation draw order and tuple order are normative:

| # | Relation | Arity | Tuple order |
|---:|---|---:|---|
| 0 | `registers_state` | 2 | `(pc, clock)` |
| 1 | `memory_access` | 7 | `(addr_space, addr, clock, limb_0, limb_1, limb_2, limb_3)` |
| 2 | `program_access` | 5 | `(addr, value_0, value_1, value_2, value_3)` |
| 3 | `merkle` | 4 | `(index, depth, value, root)` |
| 4 | `poseidon2` | 16 | `(state0, ..., state15)` |
| 5 | `poseidon2_io` | 32 | `(in0, ..., in15, out0, ..., out15)` |
| 6 | `bitwise` | 4 | `(a, b, result, op_id)` |
| 7 | `range_check_20` | 1 | `(value)` |
| 8 | `range_check_8_11` | 2 | `(limb_0, limb_1)` |
| 9 | `range_check_8_8_4` | 3 | `(limb_0, limb_1, limb_2)` |
| 10 | `range_check_8_8` | 2 | `(limb_0, limb_1)` |
| 11 | `range_check_m31` | 2 | `(lsl, msl)` |

For relation `R` with independently drawn `(z_R, alpha_R)`, the pinned
denominator is:

```text
D_R(v_0, ..., v_n) = v_0 + alpha_R*v_1 + ... + alpha_R^n*v_n - z_R
```

The current implementation of this rule and draw order is correct in
`src/frontends/riscv/air/relation_challenges.zig:15-123`. The older
`src/frontends/riscv/air/relations.zig` is not protocol-valid: it uses relation
IDs and gives incorrect arities for `program_access`, `bitwise`, and
`range_check_m31`. It must not be reachable from the production RISC-V proof.

## Notation

- `e` is the component row enabler.
- `S-(pc,c)` and `S+(pc,c)` mean `-e/D_registers_state(pc,c)` and
  `+e/D_registers_state(pc,c)`.
- `P-(...)` is a `-e` program request.
- For access `x`, `x-`, `x+`, and `Cx` are, in this exact order:

```text
-e * memory_access(as, addr, previous_clock, previous[0..4])
+e * memory_access(as, addr, clock, next[0..4])
-e * range_check_20(clock - previous_clock)
```

- `R20-(x)`, `R811-(a,b)`, `R884-(a,b,c)`, `R88-(a,b)`, and
  `RM31-(a,b)` have the displayed tuple and a negative numerator unless an
  explicit numerator is shown.
- `B_i-` is `-is_bitwise * bitwise(lhs_i, rhs_i, result_i, op_id)`.
- Entries are batched contiguously. `[A+B]` is one secure cumulative column
  holding `A/D_A + B/D_B`; `[A]` is one singleton column.
- One secure/QM31 cumulative column is committed as four M31 columns.

## Opcode placement matrix

The sequence column is the exact AIR and witness order. Unless marked `batch=1`,
adjacent entries are paired, including entries from different relation domains.

| Family | Exact ordered entry sequence | Batch | Entries | QM31 cols | M31 cols |
|---|---|---:|---:|---:|---:|
| `base_alu_reg` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, B0-, B1-, B2-, B3-, R88-(rd0,rd1), R88-(rd2,rd3), rd-, rd+, Crd` | 2 | 18 | 9 | 36 |
| `base_alu_imm` | `P-, R811-(imm0,256*imm1), S-, S+, rs1-, rs1+, C1, B0-, B1-, B2-, B3-, R88-(rd0,rd1), R88-(rd2,rd3), rd-, rd+, Crd` | 2 | 16 | 8 | 32 |
| `shifts_reg` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, R20-(shift_check), R88-(m-e-c0,m-e-c1), R88-(m-e-c2,m-e-c3), R88-(rd0,rd1), R88-(rd2,rd3), rd-, rd+, Crd` | 2 | 17 | 9 | 36 |
| `shifts_imm` | `P-, S-, S+, rs1-, rs1+, C1, R88-(m-e-c0,m-e-c1), R88-(m-e-c2,m-e-c3), R88-(rd0,rd1), R88-(rd2,rd3), rd-, rd+, Crd` | 2 | 13 | 7 | 28 |
| `lt_reg` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, R88-(rs1_msl_shifted,rs2_msl_shifted), -prefix/D_R20(diff-1), rd-, rd+, Crd` | 2 | 14 | 7 | 28 |
| `lt_imm` | `P-, R884-(rs1_msl_shifted,imm0,2*imm1), S-, S+, rs1-, rs1+, C1, -prefix/D_R20(diff-1), rd-, rd+, Crd` | 2 | 11 | 6 | 24 |
| `branch_eq` | `P-, rs1-, rs1+, C1, rs2-, rs2+, C2, S-, S+` | 2 | 9 | 5 | 20 |
| `branch_lt` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, R88-(rs1_msl_shifted,rs2_msl_shifted), -prefix/D_R20(diff-1)` | 2 | 11 | 6 | 24 |
| `lui` | `P-, S-, S+, R884-(imm1,imm2,imm0), rd-, rd+, Crd` | 2 | 7 | 4 | 16 |
| `auipc` | `P-, S-, S+, R88-(rd1,rd2), RM31-(rd0,rd3), rd-, rd+, Crd` | 2 | 8 | 4 | 16 |
| `jalr` | `P-, rs1-, rs1+, C1, RM31-(rs1_0,rs1_3), S-, S+, R88-(rd1,rd2), RM31-(rd0,rd3), rd-, rd+, Crd` | 2 | 12 | 6 | 24 |
| `jal` | `P-, S-, S+, R88-(rd1,rd2), RM31-(rd0,rd3), rd-, rd+, Crd` | 2 | 8 | 4 | 16 |
| `load_store` | `P-, S-, S+, rs1-, rs1+, C1, R20-(aligned_addr_quarter), RM31-(rs1_0,rs1_3), src-, src+, Csrc, dst-, dst+, Cdst` | 2 | 14 | 7 | 28 |
| `mul` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, R811-(rd0,c0), R811-(rd1,c1), R811-(rd2,c2), R811-(rd3,c3), rd-, rd+, Crd` | 1 | 16 | 16 | 64 |
| `mulh` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, R811-(rd0,c0), R811-(rd1,c1), R811-(rd2,c2), R811-(rd3,c3), R811-(high0,c4), R811-(high1,c5), R811-(high2,c6), R811-(high3,c7), rd-, rd+, Crd` | 1 | 20 | 20 | 80 |
| `div` | `P-, S-, S+, rs1-, rs1+, C1, rs2-, rs2+, C2, R811-(q0,c0), R811-(q1,c1), R811-(q2,c2), R811-(q3,c3), R811-(r0,c4), R811-(r1,c5), R811-(r2,c6), R811-(r3,c7), R88-(b_sign_check,c_sign_check), -valid_not_special/D_R20(lt_diff-1), rd-, rd+, Crd` | 1 | 22 | 22 | 88 |

The same data grouped by relation gives the required per-family request-count
matrix. `a-/b+` means `a` negative and `b` positive requests; zero means that the
family must not issue a request in that domain. `B` entries use
`-is_bitwise`, and the comparison/division `R20` entries retain their variable
negative numerators.

| Family | State | Memory | Program | Merkle | P2 | P2 I/O | B | R20 | R811 | R884 | R88 | RM31 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `base_alu_reg` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 4- | 3- | 0 | 0 | 2- | 0 |
| `base_alu_imm` | 1-/1+ | 2-/2+ | 1- | 0 | 0 | 0 | 4- | 2- | 1- | 0 | 2- | 0 |
| `shifts_reg` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 0 | 4- | 0 | 0 | 4- | 0 |
| `shifts_imm` | 1-/1+ | 2-/2+ | 1- | 0 | 0 | 0 | 0 | 2- | 0 | 0 | 4- | 0 |
| `lt_reg` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 0 | 4- | 0 | 0 | 1- | 0 |
| `lt_imm` | 1-/1+ | 2-/2+ | 1- | 0 | 0 | 0 | 0 | 3- | 0 | 1- | 0 | 0 |
| `branch_eq` | 1-/1+ | 2-/2+ | 1- | 0 | 0 | 0 | 0 | 2- | 0 | 0 | 0 | 0 |
| `branch_lt` | 1-/1+ | 2-/2+ | 1- | 0 | 0 | 0 | 0 | 3- | 0 | 0 | 1- | 0 |
| `lui` | 1-/1+ | 1-/1+ | 1- | 0 | 0 | 0 | 0 | 1- | 0 | 1- | 0 | 0 |
| `auipc` | 1-/1+ | 1-/1+ | 1- | 0 | 0 | 0 | 0 | 1- | 0 | 0 | 1- | 1- |
| `jalr` | 1-/1+ | 2-/2+ | 1- | 0 | 0 | 0 | 0 | 2- | 0 | 0 | 1- | 2- |
| `jal` | 1-/1+ | 1-/1+ | 1- | 0 | 0 | 0 | 0 | 1- | 0 | 0 | 1- | 1- |
| `load_store` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 0 | 4- | 0 | 0 | 0 | 1- |
| `mul` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 0 | 3- | 4- | 0 | 0 | 0 |
| `mulh` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 0 | 3- | 8- | 0 | 0 | 0 |
| `div` | 1-/1+ | 3-/3+ | 1- | 0 | 0 | 0 | 0 | 4- | 8- | 0 | 1- | 0 |

### Exact program tuples

| Family group | `program_access` tuple |
|---|---|
| R-type ALU, shifts, compare, MUL/MULH/DIV | `(pc, expected_opcode_id, rd_addr, rs1_addr, rs2_addr)` |
| I-type ALU and compare | `(pc, expected_opcode_id, rd_addr, rs1_addr, imm)` |
| Immediate shifts | `(pc, expected_opcode_id, rd_addr, rs1_addr, imm_truncated)` |
| Equal/less-than branches | `(pc, expected_opcode_id, rs1_addr, rs2_addr, imm_felt)` |
| `lui` | `(pc, Lui, rd_addr, imm, 0)` |
| `auipc` | `(pc, Auipc, rd_addr, imm_felt, 0)` |
| `jalr` | `(pc, Jalr, rd_addr, rs1_addr, imm_felt)` |
| `jal` | `(pc, Jal, rd_addr, imm_felt, 0)` |
| Load/store | `(pc, expected_opcode_id, rs1_addr, r2_idx, imm_felt)` |

All opcode program requests have numerator `-e`.

### Exact state tuples

All families consume `registers_state(pc, clock)`. Sequential families emit
`registers_state(pc + 4, clock + 1)`. Branches emit the selected branch target;
`jal` emits `pc + imm_felt`; and `jalr` emits `2 * to_pc_over_two`. This state
target must be reconstructed from committed family columns, not from an
unconstrained parallel `next_pc` adapter.

### Exact access tuples

Register accesses use address space zero. Load/store has three accesses in this
order:

1. `rs1` register read;
2. `src` at `(src_as, src_addr_selector)`, where loads use RW memory and stores
   use the source register;
3. `dst` at `(dst_as, dst_addr_selector)`, where loads write the destination
   register and stores write RW memory.

The `rd` next tuple for `lt_reg` and `lt_imm` is
`(0, rd_addr, clock, cmp_result, 0, 0, 0)`. The DIV `rd` next tuple is
`(0, rd_addr, clock, a_0, a_1, a_2, a_3)`. Other families use their four
committed `rd_next` limbs, except LUI, whose next limbs are
`(0, rd_val_1, imm_1, imm_2)`.

## Exact batching matrix

This table makes cross-relation pairing explicit. Rows list secure columns in
order; a bracket is one QM31/four-M31 committed column.

| Family | Secure-column relation batches |
|---|---|
| `base_alu_reg` | `[program,state] [state,memory] [memory,r20] [memory,memory] [r20,bitwise] [bitwise,bitwise] [bitwise,r88] [r88,memory] [memory,r20]` |
| `base_alu_imm` | `[program,r811] [state,state] [memory,memory] [r20,bitwise] [bitwise,bitwise] [bitwise,r88] [r88,memory] [memory,r20]` |
| `shifts_reg` | `[program,state] [state,memory] [memory,r20] [memory,memory] [r20,r20] [r88,r88] [r88,r88] [memory,memory] [r20]` |
| `shifts_imm` | `[program,state] [state,memory] [memory,r20] [r88,r88] [r88,r88] [memory,memory] [r20]` |
| `lt_reg` | `[program,state] [state,memory] [memory,r20] [memory,memory] [r20,r88] [r20,memory] [memory,r20]` |
| `lt_imm` | `[program,r884] [state,state] [memory,memory] [r20,r20] [memory,memory] [r20]` |
| `branch_eq` | `[program,memory] [memory,r20] [memory,memory] [r20,state] [state]` |
| `branch_lt` | `[program,state] [state,memory] [memory,r20] [memory,memory] [r20,r88] [r20]` |
| `lui` | `[program,state] [state,r884] [memory,memory] [r20]` |
| `auipc` | `[program,state] [state,r88] [rm31,memory] [memory,r20]` |
| `jalr` | `[program,memory] [memory,r20] [rm31,state] [state,r88] [rm31,memory] [memory,r20]` |
| `jal` | `[program,state] [state,r88] [rm31,memory] [memory,r20]` |
| `load_store` | `[program,state] [state,memory] [memory,r20] [r20,rm31] [memory,memory] [r20,memory] [memory,r20]` |
| `mul` | 16 singleton columns in the ordered-entry sequence above |
| `mulh` | 20 singleton columns in the ordered-entry sequence above |
| `div` | 22 singleton columns in the ordered-entry sequence above |

The singleton rule for the M extension is degree-critical, not a performance
choice. The pinned schema states that quadratic carry denominators must not be
multiplied together (`schema.rs:1056-1059`, `:1127-1130`, `:1323-1326`).

## Infrastructure placement

| Component | Exact ordered entries | Batch | QM31/M31 cols |
|---|---|---:|---:|
| `program` | `+multiplicity*program_access(addr,v0,v1,v2,v3)`, then four `-e*merkle(addr+i,30,v_i,root)` | 2 | 3 / 12 |
| `memory` | `-e*R88(v0,v1)`, `-e*R88(v2,v3)`, `+multiplicity*memory_access(1,addr,clock,v0,v1,v2,v3)`, then four `-e*merkle(addr+i,30,v_i,root)` | 2 | 4 / 16 |
| `merkle` | `+lhs_mult*merkle(index,depth,lhs,root)`, `+rhs_mult*merkle(index+1,depth,rhs,root)`, `-cur_mult*merkle(index/2,depth-1,cur,root)`, `+e*poseidon2(lhs,rhs,0...0)`, `-e*poseidon2(cur,0...0)` | 2 | 3 / 12 |
| `clock_update` | `-e*memory_access(as,addr,clock_prev,value[0..4])`, `+e*memory_access(as,addr,clock_prev+2^20-1,value[0..4])` | 2 | 1 / 4 |
| `poseidon2` | input consume, narrow output emit, wide output emit, atomic I/O emit, as detailed below | 2 | 2 / 8 |
| each preprocessed multiplicity component | `-stored_multiplicity*relation(table_row)` | 2 | 1 / 4 |

Infrastructure batch order is:

```text
program: [program + merkle0] [merkle1 + merkle2] [merkle3]
memory:  [r88_0 + r88_1] [memory + merkle0] [merkle1 + merkle2] [merkle3]
merkle:  [merkle_lhs + merkle_rhs] [merkle_parent + poseidon_input]
         [poseidon_output]
```

The preprocessed counter stores the signed consumer numerator modulo M31. Since
opcode/table consumers are normally negative, the lookup component's
`-stored_multiplicity` numerator emits the positive balancing side. Variable
numerators such as `-prefix` and `-valid_not_special` must be registered exactly,
not collapsed to a boolean request count.

Preprocessed table log sizes are: bitwise 18, range20 20, range8_11 19,
range8_8_4 20, range8_8 16, and rangeM31 15. The bitwise table includes operation
ID 3 as padding, and rangeM31 duplicates `(0,0)` at the otherwise invalid
`(255,127)` row.

## Poseidon2 placement and scope conflict

Pinned Stark-V's Poseidon2 component uses four entries in this order:

1. `-e*(1-io) * poseidon2(input[0..16])`;
2. `+e*(1-wide-io) * poseidon2(output[0])`;
3. `+e*wide * poseidon2(output[0..8])`;
4. `+e*io * poseidon2_io(input[0..16],output[0..16])`.

Entries 1+2 and 3+4 are paired. The RV32IM Merkle runner calls Poseidon2 with
`wide=false, io=false` (`crates/air/src/poseidon2.rs:244-269`), so its input and
one-word output balance the Merkle component through `poseidon2`; it contributes
zero to `poseidon2_io`.

The only pinned consumer of `poseidon2_io` is the separate recursion
`channel_replay` component, with numerator `-e`
(`crates/recursion/src/channel_replay.rs:104-118`). That component is not in the
RV32IM component registry listed in `crates/prover/src/components/mod.rs:6-37`.

The release goal now resolves the earlier conflict in favor of oracle parity:
RV32IM Merkle hashes remain in narrow `poseidon2` mode, the `poseidon2_io`
challenge is drawn in schema order, and its RV32IM relation sum must be zero.
Non-vacuous `poseidon2_io` coverage belongs to the recursion lane. Adding an
RV32IM atomic-I/O consumer would be a protocol divergence and is not part of
this release goal.

Silently setting `io=true` only on the Poseidon row leaves an unbalanced positive
`poseidon2_io` claim and is invalid.

## Per-relation cancellation matrix

| Relation | Negative/consumer side | Positive/emitter side |
|---|---|---|
| `registers_state` | opcode current state; public final state | opcode next state; public initial state |
| `memory_access` | opcode previous accesses; clock-update prior endpoint; memory rows with multiplicity `-1`; public register/output final state | opcode next accesses; clock-update next endpoint; memory rows with multiplicity `+1`; public register/input initial state |
| `program_access` | one request per opcode row | program row weighted by fetch multiplicity |
| `merkle` | program/memory leaves; Merkle parent | Merkle children; public program/initial/final roots |
| `poseidon2` | Poseidon input row; Merkle hashed parent output | Merkle node input; Poseidon narrow/wide output |
| `poseidon2_io` | recursion channel replay only | Poseidon atomic-I/O row only |
| `bitwise` | active bitwise opcode limbs | bitwise multiplicity table |
| `range_check_20` | opcode clock gaps and semantic range requests | range20 multiplicity table |
| `range_check_8_11` | immediate and M-extension requests | range8_11 multiplicity table |
| `range_check_8_8_4` | LT-immediate and LUI requests | range8_8_4 multiplicity table |
| `range_check_8_8` | opcode byte requests and memory boundary bytes | range8_8 multiplicity table |
| `range_check_m31` | AUIPC/JAL/JALR/load-store requests | rangeM31 multiplicity table |

Public compensation is exactly:

- `+1/registers_state(initial_pc,1)` and
  `-1/registers_state(final_pc,clock+1)`;
- `+1/merkle(0,0,root,root)` for every present program, initial-RW, and
  final-RW root;
- for all 32 registers, `+` the initial clock-zero word and `-` the final word
  at `reg_last_clock`;
- `+` every public input RW word at clock zero; and
- `-` every public output RW word at its final access clock.

`src/frontends/riscv/air/public_logup.zig:39-159` already represents these three
public domains independently and is reusable.

## Current Zig gap analysis

1. `interaction_gen.zig:33-36` fixes every opcode component at 20 M31 columns:
   one state column, one program column, and three memory-access columns. The
   oracle requires family-specific layouts from 16 through 88 M31 columns.
2. `interaction_gen.zig:119-189` regroups entries by relation instead of keeping
   schema declaration order. Appending range and bitwise columns would not repair
   accumulator parity; the opcode interaction layout must be replaced.
3. `component.zig:53-60`, `:112-121`, and `:267-385` constrain only those
   regrouped state/program/memory columns. Range, bitwise, Merkle, Poseidon2,
   clock-update, and lookup-table components remain absent or `silent`.
4. The program component commits 4 M31 interaction columns
   (`interaction_gen.zig:202-283`) but the oracle requires 12 because its four
   Merkle leaf requests share the same ordered interaction component.
5. The memory boundary has the correct tuples and signs, but
   `memory_commitment/interaction.zig:104-131` regroups them as memory, two
   Merkle pairs, then range. The oracle order is range pair, memory+Merkle0,
   Merkle1+Merkle2, Merkle3. The claimed total is algebraically equal, while the
   committed columns and cumulative oracle accumulator are not.
6. `preprocessed/bitwise.zig:1-36` is a 65,536-row, five-column table. The pinned
   table is 262,144 rows and four columns `(a,b,result,op_id)`.
7. The current multi-limb range tables also use the wrong row order. Pinned
   indices are `a + (b << 8)` and `a + (b << 8) + (c << 16)`, while
   `preprocessed/range_check.zig:42-48`, `:71-77`, and `:100-108` make the last
   limb vary fastest. Equal tuple sets do not produce the same preprocessed
   commitment.
8. `preprocessed/range_check.zig:121-128` treats rangeM31 as an unmaterialized
   virtual table. The pinned table is a real log-15 two-column `(lsl,msl)` table.
9. `relations.zig` is obsolete and protocol-incompatible; only
   `relation_challenges.zig` has the correct twelve-domain schema.
10. Reusable exact primitives already exist: challenge combination in
   `relation_challenges.zig`, generic pair accumulation and recurrence in
   `logup.zig:50-105`, full access tuples in `memory_logup.zig:27-108`, family
   access reconstruction in `opcode_memory.zig:65-243`, and public compensation
   in `public_logup.zig`.

## Required module decomposition

The smallest maintainable integration replaces relation-specific orchestration,
not the working field/recurrence primitives:

```text
src/frontends/riscv/air/relations/
├── schema.zig              # 12 tags, arities, draw order, table log sizes
├── request.zig             # tagged numerator + tuple, max arity 32
├── batching.zig            # batch=2/default, batch=1/M extension
├── opcode/
│   ├── base_alu.zig        # base reg/imm ordered requests
│   ├── shifts_compare.zig  # shifts and LT families
│   ├── control.zig         # branches, LUI, AUIPC, JAL/JALR
│   ├── load_store.zig      # address-space-sensitive requests
│   └── m_extension.zig     # singleton MUL/MULH/DIV requests
├── infrastructure.zig      # program, memory, Merkle, clock-update requests
├── poseidon2.zig           # narrow/wide/io requests
├── tables.zig              # signed multiplicities and six table counterparts
├── interaction.zig         # generic cumulative columns + recurrence inputs
└── diagnostics.zig         # per-domain sums, tuple digests, provenance
```

`semantic_eval.zig` remains responsible for direct constraints. Each opcode
request module must derive tuples from the same committed family row and expose
one ordered `requests()` function used by both interaction generation and OODS /
on-domain recurrence evaluation. No second trace adapter may reconstruct values
from `TraceRow` on the prover side while the verifier uses committed main columns.

The generic interaction layer must:

1. preserve request order exactly;
2. create `ceil(entries/batch)` QM31 cumulative columns;
3. commit four M31 coordinates per cumulative column;
4. provide the trace-order predecessor mask for every column;
5. constrain every recurrence on-domain and OODS;
6. expose one aggregate claimed sum per component in canonical component order;
7. collect non-committed per-relation diagnostics without changing production
   batching; and
8. fail before commitment on tuple arity, zero denominator, unsupported family,
   request-count, or trace-shape mismatch.

## CP-05 acceptance gates

- A compile-time manifest asserts all relation arities, family request counts,
  batch sizes, QM31 counts, and M31 counts in this document.
- For every family, a one-row test compares the ordered `(relation, numerator,
  tuple)` vector with a live Rust export from the pinned checkout.
- A batching test compares every cumulative column after every row, not only the
  final component sum.
- A canonical-component test compares the aggregate accumulator after every
  component in this exact order: `auipc`, `base_alu_imm`, `base_alu_reg`,
  `branch_eq`, `branch_lt`, `div`, `jal`, `jalr`, `load_store`, `lt_imm`,
  `lt_reg`, `lui`, `mul`, `mulh`, `shifts_imm`, `shifts_reg`, `program`,
  `memory`, `merkle`, `poseidon2`, `clock_update`, `bitwise`,
  `range_check_20`, `range_check_8_11`, `range_check_8_8_4`,
  `range_check_8_8`, and `range_check_m31`.
- Per-relation signed tuple multisets and digests match Rust independently.
- One-, two-, and many-shard runs preserve exact-once provenance and final public
  cancellation while using deterministic row placement.
- Padding and absent components produce canonical zero claims and no denominator
  inversion.
- Mutating any relation tag, sign, tuple element, request ordinal, batch boundary,
  component order, multiplicity, or challenge pair fails the proof.
- Production and verifier paths consume the same request API; tests reject a
  prover-only request or an unconstrained interaction column.
- The `poseidon2_io` scope decision above is recorded in the release goal and
  divergence log before CP-05 or CP-06 can be marked complete.
