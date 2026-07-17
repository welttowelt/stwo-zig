# Cairo Fib25k Adapted-Input Checkpoint

Status: local conformance checkpoint, not production admission evidence.

This checkpoint gives the general Cairo parity loop one canonical execution and adaptation input.
It is the Fib25k `STWZCPI/1` artifact that underlies the existing claim geometry, and it is small
enough to regenerate before per-component base-trace comparisons without running a proof.

## Authority

The fixture is governed by:

- `docs/conformance/upstream.md` for the Cairo verifier and prover revision tuples;
- `docs/design/2026-07-17-pre-optimization-conformance-goal.md` for the Fib25k-first acceptance
  sequence and content-addressed evidence requirements;
- `docs/design/2026-07-17-cairo-program-matrix.md` for the program-agnostic Cairo matrix; and
- `CONTRIBUTING.md` for final Rust-oracle acceptance and component-checkpoint localization.

The machine-readable authority is
`vectors/cairo/checkpoints/fib_25000_stwzcpi.json`. It binds the compiled Cairo program, exact
revisions, exporter source, exporter patch, Cargo lockfile, observed generator binary, command,
artifact, structural checkpoint, and negative cases.

The same manifest binds the immutable Rust base- and interaction-trace receipts at
`vectors/cairo/checkpoints/fib_25000_base_trace.json` and
`vectors/cairo/checkpoints/fib_25000_interaction_trace.json`. The repository-owned
`tools/stwo-cairo-trace-oracle` commits every logical trace column by component, ordinal, row
count, and SHA-256 digest. The interaction receipt also binds every claimed sum and the complete
diagnostic lookup challenge. That challenge is deliberately independent of the Fiat-Shamir proof
transcript and cannot be used as proof-acceptance evidence.

## Canonical Identity

```text
case:           Cairo Fib(25000)
cycle rule:     7 * n + 16
cycles:         175016
format:         STWZCPI/1
bytes:          4233092
sha256:         3e5f076f30efbf9f295803ac7198750879267ba78d1e98c820742de08255e366
program sha256: bd79e52ee27d3faa2bf12dde995ebd4398070878278cfb62557143fe15ea1589
components:     30
base columns:   396
base receipt:   fca68639b3c8a5c7b498f1961118f4ea8c7af157a65267a3d00adbeef2ef9972
base accum.:    8a75a4dbf68a1ad36680d4e62dc539e41ce539109043c4d4d5645096ebb99fa3
interaction:    324 M31 columns
inter. receipt: 12ef00fea1055d746f0d22bc61e15307829c808066da378e31d024632c47124a
inter. accum.:  536c927621cfc55712d7650ad774d2bb8a7c23d4d0c64f2989c6350366190d5a
```

The 4.1 MiB binary is intentionally not checked in. Its canonical local location is content
addressed:

```text
/private/tmp/stwo-zig-cairo-inputs/
  3e5f076f30efbf9f295803ac7198750879267ba78d1e98c820742de08255e366/
  fib_25000.stwzcpi
```

## Regeneration

The generator authenticates every source before launching Rust, removes inherited `STWO_*`
configuration, writes to a temporary sibling, validates the complete result, and only then uses an
atomic rename to publish it.

```sh
python3 scripts/cairo_input_checkpoint.py generate \
  --gpu-bench "$HOME/code/personal/stwo-cairo/stwo_cairo_prover/target/release/gpu_bench" \
  --program "$HOME/code/personal/stwo-cairo/gpu_benchmarks/fib/compiled.json" \
  --generator-source "$HOME/code/personal/stwo-cairo/stwo_cairo_prover/crates/gpu-prover/src/bin/gpu_bench.rs" \
  --cargo-lock "$HOME/code/personal/stwo-cairo/stwo_cairo_prover/Cargo.lock" \
  --stwo-cairo-root "$HOME/code/personal/stwo-cairo" \
  --output /private/tmp/stwo-zig-cairo-inputs/3e5f076f30efbf9f295803ac7198750879267ba78d1e98c820742de08255e366/fib_25000.stwzcpi
```

The authenticated Rust subprocess command is:

```sh
gpu_bench \
  --program gpu_benchmarks/fib/compiled.json \
  --iterations 25000 \
  --backend simd \
  --engine legacy \
  --reps 2 \
  --reuse-input
```

`STWO_DUMP_STWZCPI={temporary-output}` makes `gpu_bench` stop immediately after Cairo execution and
adaptation. Backend and repetition arguments satisfy the CLI contract but no proof is attempted.

Validate any candidate independently:

```sh
python3 scripts/cairo_input_checkpoint.py validate \
  --input /path/to/fib_25000.stwzcpi
```

Validation covers the artifact digest and size, header and reserved fields, all 20 ordered opcode
counts, cycle total, memory geometry, sorted unique public memory, builtin segments, truncation,
and trailing data.

Generate the pinned Rust base-trace receipt after validating the input:

```sh
cargo run --release --locked \
  --manifest-path tools/stwo-cairo-trace-oracle/Cargo.toml -- \
  /private/tmp/stwo-zig-cairo-inputs/3e5f076f30efbf9f295803ac7198750879267ba78d1e98c820742de08255e366/fib_25000.stwzcpi \
  /tmp/fib_25000_base_trace.json
```

The oracle refuses to replace an existing destination, publishes atomically, and emits
byte-identical JSON for the same authenticated input and source tuple.

Generate the deterministic interaction-trace diagnostic receipt from the same input:

```sh
cargo run --release --locked \
  --manifest-path tools/stwo-cairo-trace-oracle/Cargo.toml -- \
  interaction \
  /private/tmp/stwo-zig-cairo-inputs/3e5f076f30efbf9f295803ac7198750879267ba78d1e98c820742de08255e366/fib_25000.stwzcpi \
  /tmp/fib_25000_interaction_trace.json
```

This mode derives one fixed, domain-separated `CommonLookupElements` value, serializes `z`,
`alpha`, and all 128 alpha powers, and binds them into every component accumulator. It exists only
to make component-local Zig/Rust differential comparison reproducible. It never substitutes for
the transcript-derived challenges used by a real proof.

## Provenance Limitation

The canonical bytes are reproducible now, but the `STWZCPI` exporter is a content-identified local
modification at the pinned Stwo-Cairo revision. It is not a committed file at that revision. Its
generator dependency graph also predates the repository-owned clean prover oracle, so the binary
and lockfile digests remain the authority for these particular bytes. The manifest therefore marks
this fixture `local_checkpoint_only`, names both current Cairo Stwo sub-lanes, and pins all of the
following:

- exporter source SHA-256;
- exporter patch SHA-256 relative to the pinned revision;
- Cargo.lock SHA-256;
- observed generator binary SHA-256; and
- final artifact SHA-256.

The exporter must be committed or replaced by an equivalent repository-owned pinned tool before
this source chain can satisfy production admission. This limitation does not prevent its use as a
strict differential input because any drift is rejected and the generated bytes are exact.

## Downstream Contract

This artifact is the input to the Fib25k per-component loop. The committed Rust receipts fix the
expected base and diagnostic interaction traces, but do not claim AIR, proof-transcript, proof, or
verifier parity on their own. The base-trace portion of the loop is closed: the single
`cairo-input compare-base` command matches all 30 components and all 396 columns against the Rust
receipt. The remaining loop must:

1. reproduce the committed receipt with the pinned Rust base-trace exporter;
2. reproduce and authenticate the fixed diagnostic interaction challenge and receipt;
3. feed the same bytes and backend-neutral base columns to the Zig interaction materializer;
4. compare claimed sums and canonical interaction columns in proof-plan order; and
5. stop at the first differing component, column, row count, or digest.

Only after base and interaction checkpoints agree may the same case progress to PCS, FRI, proof
serialization, and final pinned Rust `verify_cairo` acceptance.
