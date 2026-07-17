# Cairo composition projection

Program-specific Cairo proving must not reuse the 58-component SN2 composition
schedule by changing only trace log sizes. A target proof with a different
active AIR claim has different trace-tree spans, random-coefficient offsets,
constraint totals, and potentially a different preprocessed trace.

`scripts/sn_pie_composition_bundle.py` supports one explicit projection:

```text
canonical (161 columns) -> canonical_without_pedersen (105 columns)
```

This is the path used by the Cairo Fib25k reference proof. All other variant
transitions fail closed until the Rust Stwo Cairo oracle exports their exact
identity mapping.

## Required inputs

A projection requires:

- the validated `STWZEVA` v1 source bundle;
- the Rust reference proof from which that bundle was exported;
- the target Rust reference proof;
- the source `STWZPPC` preprocessed coefficient fixture, used as the ordered
  column-identity authority; and
- an explicit projection-manifest output path.

The source proof's active claim must equal the source bundle order. The target
claim must be an order-preserving subset. Claim and interaction-claim activity
must agree exactly. Sampled and queried tree widths must agree in both proofs.

The source bundle must encode contiguous, complete base and interaction spans.
Their totals must match the source proof. Retained span widths must match the
target proof after compaction. Preprocessed indices are mapped by identity,
never by ordinal inference.

Evaluator semantic sections remain byte-identical except for explicit,
pinned-AIR-derived transforms. The only supported transform is
`memory_address_to_id`: when its log size changes, the fifteen encoded address
offsets are retargeted from `i * 2^source_log` to `i * 2^target_log`. Projection
requires every expected source constant exactly once and rejects any missing,
duplicate, conflicting, or additional evaluator rewrite.

## Output contract

Projected bundles use `STWZEVA` v2. The header contains rebuilt component
count, total constraint count, maximum evaluation log size, contiguous random
coefficient offsets, compacted tree spans, and a plan hash. The plan hash is
FNV-1a over the complete encoded bundle with header bytes `32..40` treated as
zero. The Zig loader recomputes it and rejects any mismatch.

The sidecar JSON uses format
`stwo-zig-cairo-composition-projection`, version `2`. It binds the source bundle
and both proof files by SHA-256 and records source/target variants, proof tree
widths, output SHA-256 and plan hash, every component span mapping,
preprocessed identity mapping, constraint offset, and source and target
semantic evaluator payload hashes. The retarget result also records exact
domain-dependent constants and their old and new semantic hashes.
The target additionally records `max_evaluation_log_size`. This authenticated
field is the sole authority from which a projected semantic pack derives its
verifier maximum log-degree bound; consumers must reject absent or inconsistent
values rather than recover geometry heuristically.

```sh
python3 scripts/sn_pie_composition_bundle.py \
  --template vectors/cairo/sn_pie_2_composition.bin \
  --template-proof /path/to/sn2.reference.proof.json \
  --proof /path/to/cairo-fib-25000.reference.proof.json \
  --preprocessed-coefficients /path/to/canonical.stwzppc \
  --project-components \
  --projection-manifest /path/to/fib-25000.composition.projection.json \
  --output /path/to/fib-25000.composition.bin
```

## Correctness boundary

The Rust Stwo Cairo prover remains the final correctness oracle. A projected
pack is eligible for proving only after its target claim/proof geometry and
preprocessed variant come from a Rust-verified proof. Proof parity remains the
release gate; successful parsing or Metal kernel loading is not evidence of
proof correctness.

Any evaluator change beyond the narrowly checked `memory_address_to_id` stride
transform requires a Rust semantic-pack exporter. Python projection does not
infer or accept arbitrary evaluator instructions.
