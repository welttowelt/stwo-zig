# Cairo Arena Schedule Decomposition

Status: required follow-up to the general Cairo runtime-geometry work.

## Problem

`scripts/sn_pie_arena_schedule.py` is 1,643 lines and currently owns binary parsing,
projection policy, schedule mutation, retention policy, proof geometry, and CLI orchestration.
Those responsibilities have different authorities and failure modes. Keeping them together makes
authenticated projection changes difficult to review and exceeds the repository's file-size
ratchet.

The split must preserve behavior. It is not an opportunity to change schedule ordering, buffer
lifetimes, retention policy, proof bytes, or artifact formats.

## Target layout

```text
scripts/
├── sn_pie_arena_schedule.py              # argument parsing and JSON output only
└── cairo_arena_schedule/
    ├── __init__.py                        # narrow retarget API
    ├── orchestrator.py                    # ordered projection pipeline and report
    ├── schedule.py                        # entry indexing, grouping, cloning, and re-ID
    ├── formats/
    │   ├── proof.py                       # Rust proof claim and tree geometry
    │   ├── adapted_input.py               # authenticated STWZCPI metadata
    │   ├── fixed_tables.py                # authenticated STWZFIX v2 reader
    │   ├── relations.py                   # STWZREL reader and source layouts
    │   ├── composition.py                 # STWZEVA reader and plan hash
    │   ├── quotient.py                    # STWZQI geometry
    │   └── transcript.py                  # transcript fixture geometry
    ├── projection/
    │   ├── components.py                  # active component closure and ordinal mapping
    │   ├── preprocessed.py                # identity projection and tree-0 bindings
    │   ├── fixed_tables.py                # fixed lookup/source/multiplicity bindings
    │   ├── relations.py                   # relation instances and claimed-sum order
    │   └── trace_groups.py                # commitment/decommit group reconstruction
    └── geometry/
        ├── execution.py                   # row scaling and execution-table buffers
        ├── composition.py                 # accumulator, coefficient, and LDE sizing
        ├── quotient.py                    # quotient partials and scratch sizing
        ├── fri.py                         # runtime rounds, layers, and domain buffers
        ├── retention.py                   # retained-evaluation selection and workspaces
        └── proof.py                       # transcript inputs, assembly, and proof bytes
```

No module should exceed 500 lines without a design-note amendment. The thin CLI should remain
below 120 lines and `orchestrator.py` below 250 lines. Public imports are limited to the retarget
request/result types and `retarget`; format records and schedule mutation helpers remain private.

## Dependency direction

`formats` parses immutable authority records and may depend only on the standard library.
`schedule.py` owns generic schedule mechanics and knows no Cairo artifact format. `projection`
depends on typed format records plus schedule mechanics. `geometry` depends on schedule mechanics
and already projected geometry, never on raw bytes. `orchestrator` is the only module allowed to
sequence projection and geometry passes. The CLI depends only on `orchestrator`.

Artifact readers must validate magic, version, bounds, trailing bytes, graph identity, and plan
hash where the format provides one. Projection modules must consume parsed records; they must not
reparse binary offsets or infer authority from template buffer counts.

## Migration sequence

1. Extract `schedule.py` and the seven format readers without changing call sites. Add parser
   tests for truncation, trailing bytes, duplicate identities, graph mismatch, and plan mismatch.
2. Extract component, preprocessed, fixed-table, and relation projection in separate commits.
   Preserve the exact logical-buffer order and IDs after every pass.
3. Extract trace-group and execution geometry, then composition, quotient, FRI, retention, and
   proof geometry one module per commit.
4. Move sequencing into `orchestrator.py`; reduce `sn_pie_arena_schedule.py` to CLI translation.
5. Remove compatibility re-exports after all repository callers import the narrow package API.

Each extraction commit must keep the Python suite green and reproduce byte-identical JSON for:

- the canonical SN2 schedule at eight FRI rounds;
- projected Fib25k at seven FRI rounds and zero retention; and
- a synthetic schedule with a different fixed/relation component subset.

Golden tests compare a canonical JSON digest plus purpose/ordinal/length tuples, not only total
buffer counts. The SN2 proof-copy ordinal sequence and proof-byte size are explicit regression
gates. Fib25k must continue to pass the host-only five-pack `metal-arena-plan` binding gate.

## Completion criteria

The decomposition is complete when no Python source file exceeds the stated cap, the CLI exposes
the same arguments and report fields, authenticated malformed inputs fail before output is
written, SN2 and Fib golden schedules are unchanged, and the full Python and Zig test suites pass.
Performance or Metal execution changes belong in later commits and are not part of this split.
