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

That allocator is now implemented in `src/backends/metal/arena_plan.zig`.
Unlike the contiguous Rust lifetime, it accepts exact sparse live ranges, with up
to 64 component-local sub-epochs per protocol phase. Recoverable values occupy
only their live ranges; a deterministic cost comparison selects spill or
recomputation, and an epoch runner enforces restore/recompute before dispatch
and spill/release after the caller's Metal command-buffer barrier. Physical
slots are colored into one 16 KiB-aligned resident Metal slab and validated for
live alias overlap before allocation.

Running the planner over the exact 17,552-buffer SN2 preflight schedule reduces
the plan from 60.56 GiB and 16,589 slots to 28.06 GiB and 6,777 slots. The plan
contains 120,101 materialization actions (4,688 spilled and 12,090 recomputed
buffers), passes alias validation, and fits the laptop's
29 GiB Metal budget. Global workspaces conservatively remain live across all
component sub-epochs in their phase. These are allocation-plan results,
not proof throughput: witness/AIR completion and reference-verifier acceptance
remain the benchmark gate below.

The reproducible planner command is:

```sh
zig build install -Doptimize=ReleaseFast
gzip -dc vectors/cairo/sn_pie_2_arena_schedule.json.gz > /tmp/sn2-arena.json
zig-out/bin/metal-arena-plan /tmp/sn2-arena.json 29 \
  vectors/cairo/sn_pie_2_witness_programs.bin \
  vectors/cairo/sn_pie_2_multiplicity_feeds.bin \
  vectors/cairo/cairo_relation_templates.bin \
  vectors/cairo/cairo_fixed_tables.bin \
  vectors/cairo/sn_pie_2_composition.bin
```

The compressed vector is the exact host-only preflight export used for this
result. The CLI applies the versioned protocol-purpose schedule policy, keeps
global workspaces live for the full phase, and prints the input SHA-256
alongside the deterministic plan hash.

## Executable recovery

`src/backends/metal/recovery.zig` turns the allocation plan into executable,
fail-closed hooks. Irreducible values use deterministic page-aligned extents in
a pre-sized sparse file; spill and restore perform no allocation, verify a
Wyhash checksum, and account exact bytes. `RecoveryEngine.validatePlan` rejects
the session before Metal allocation if any spill extent or recomputation recipe
is absent.

Recomputation is coalesced by schedule tick. One grouped operation can own all
outputs from a witness, LogUp, Merkle, quotient, or FRI launch; the first output
hook dispatches it and the remaining logical bindings do no duplicate work.
The runner indexes actions by tick, avoiding a scan of all 120,101 actions at
each component sub-epoch.

The canonical SN2 witness bundle contains 33 validated recorded programs in the
versioned `STWZWIT` format. The matching `STWZFED` artifact contains the exact
33 multiplicity-feed plans and LUTs. Zig resolves their source and destination
columns through the sparse arena's real offsets; physical contiguity is not
assumed. An artifact-wide test binds every feed against deliberately disjoint
column addresses.

The prepared Metal feed batch owns every descriptor, LUT, source-offset,
destination-offset, and clear-span buffer for the lifetime of the recipe. A
recovery launch clears every unique shared consumer once, crosses a Metal
buffer barrier, then encodes all 33 atomic producer scatters in the same command
buffer. The clear uses a prefix-indexed linear launch and touches exactly the
destination word count instead of `largest_table * table_count`. Repeated
launches allocate no Metal buffers and perform no compatibility readback or CPU
synchronization between producers.

Recorded witness programs bind 3,120 BaseTrace/LookupInputs/SubcomponentInputs
buffers (23.63 GiB), native feeds bind 119 BaseTrace buffers, and three
genuinely unreferenced fixed multiplicity tables use explicit zero recipes.
The `STWZFIX` artifact binds 21 canonical fixed-table LookupInputs slabs through
one prepared Metal batch, covering another 2,473,164,992 bytes. Its descriptor
graph hash and every source, multiplicity, output, and row geometry are checked
against the SN schedule before recomputation is enabled. The remaining
exceptional writer, `ec_op_builtin`, is now one prepared Metal dispatch. It owns
all 273 trace columns, the 488-word lookup row, 127 padded partial-input columns,
and four multiplicity side effects. Stark-field Montgomery arithmetic is
checked independently, and a canonical Rust artifact checks all trace, lookup,
and partial columns for 64 rows. The real SN2 geometry has 1,024 EC instances
and 252 rounds per instance. A parallel prefix/suffix batch-inversion scan
reduced its median GPU time from 6,643.76 ms to 1,640.26 ms (`4.05x`), or
157,321 EC round-steps/s, with zero hot-path allocation and zero compatibility
readback.

Resident circle transforms bind all 5,717 base and interaction coefficient
buffers. A sparse prepared IFFT additionally reconstructs 144 exact
PreprocessedCoefficients columns from their retained evaluation counterparts,
without packing columns or leaving the arena. The 17 coefficient-only columns
remain spill-backed. The `STWZREL` artifact binds all 58 relation instances and
2,268 interaction output columns (5,425,139,968 bytes) to the resident LogUp
engine. Sparse Blake2s parent chains reconstruct 174 upper Merkle layers across
12 commitment/FRI trees. The four Cairo commitment trees now use a single
prepared command buffer per tree: sparse evaluation columns are lifted directly
from their arena offsets into canonically ordered leaves, lower parent levels
ping-pong through two workspaces, and retained upper layers are written in
place. Those commitment bottoms are therefore no longer spill snapshots; FRI
bottoms remain spill-backed.

The three canonical multiset writers also run entirely in the arena. One
prepared command buffer gathers disjoint sparse producers, performs a stable
key-prefix radix sort, rejects equal-key/different-suffix collisions, run-length
encodes the tuples, and writes counts, padding, enablers, and iota columns. At
the exact verify-instruction geometry of 16,777,216 input rows, the M4 Max
median is 194.201 ms (86.39 million rows/s) with a 1,219,231,816-byte prepared
arena footprint, zero hot-path allocations, and zero compatibility readback.

The recovery gate is now fail closed in the planner as well as the executor.
Only 12,090 buffers with concrete recipes may use `.recompute`; every unbound
value is assigned `.spill`, for which `FileSpillStore` has a checksummed extent.
Consequently `RecoveryEngine.validatePlan` has no unbound recomputation. This
also invalidates the earlier 19.97 MiB spill estimate: it depended on classifying
unregistered interaction/Merkle/FRI work as recomputable. The conservative
fallback is currently 4,688 buffers and 3,404,163,836 bytes, down from
25,009,389,380 bytes before exact relation, preprocessed IFFT, fixed-table,
Merkle-parent, and EC-op recipes were bound. Replacing that
fallback with exact resident protocol recipes is performance work, not a reason
to weaken the gate.

The exact SN2 Cairo composition AIR is now exported as the versioned,
GPU-neutral `MetalEvaluationProgramV1` instruction stream. Zig validates the
full binary ABI, section bounds, semantic hashes, register dataflow, typed
extension-parameter provenance, trace subspans, denominator geometry, and
constraint ordering before generating Metal. The Metal-specific 512-instruction
split contains 58 component instances, 279 parts, 1,325 constraints, and 112,956
instructions; the largest indivisible constraint cone is 1,338 instructions.
This avoids translating generated CUDA and keeps the AIR out of Zig `comptime`.

Each V1 part becomes an unrolled per-row MSL kernel that reads sparse resident
columns through arena offset tables and fuses random-coefficient accumulation
and denominator multiplication into four resident coordinate accumulators. A
real Metal parity test checks the generated kernel against scalar M31/QM31
arithmetic, and a retained batch encodes all parts into one command buffer.
All 271 unique SN2 kernels compile together into the portable 7.4 MiB
`sn_pie_2_composition.metallib`. Building that library takes 14.69 seconds
(13.19 seconds Metal compile plus 1.50 seconds link), compared with 148.89
seconds for 279 independent runtime compilations. A machine-specific
`MTLBinaryArchive` takes 25.92 seconds to populate once and then resolves all
279 pipelines in 13.90 ms (80 ms total process time); the 55 MiB sidecar is
ignored by git and regenerated per Metal driver.

Composition graph ownership is now resident at both substitution boundaries.
The prepared front clears the shared accumulator once and, in one command
buffer, interleaves each component's variable-log coefficient LDE with its
fused AIR parts before reusing the single tile. The prepared back lifts all 18
accumulator log classes, interpolates four secure coordinates, normalizes, and
splits them into eight quotient coefficient columns in one command buffer.
Both boundaries have CPU parity tests. One coalesced recovery recipe owns the
eight outputs with no compatibility readback.

The exact planner gate consumes `sn_pie_2_composition.bin`, checks the 58
component instances and 279 parts against every trace span, preprocessed index,
extension-parameter extent, twiddle table, 100,662,912-word accumulator slab,
5,300-word random-power slab, tile, descriptor slab, and output geometry. It
then binds the eight 268,435,456-byte composition outputs as recomputable. This
reduces the conservative spill fallback to 4,680 buffers and 3,135,728,380
bytes. Descending random powers and typed constant/dynamic extension parameters
are now also materialized by Metal at the start of the same front command
buffer; parity covers constant scaling and resident-source scaling. The
remaining composition wiring is construction of the exact prepared front plan
from the validated SN schedule bindings.

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
