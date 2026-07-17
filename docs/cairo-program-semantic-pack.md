# Cairo program semantic pack

`scripts/cairo_program_semantic_pack.py` projects the non-composition Cairo
artifacts required by a program-specific proving pipeline. Its only component
selection authority is the authenticated composition projection manifest.

The projector computes a dependency closure rooted in active witness feeds. A
feed destination is accepted only when its component, or the component prefix
before `#`, is active in the composition manifest. It then emits:

- `STWZWIT` witness programs whose labels are active;
- `STWZFED` feeds whose producers are active and whose dependencies are
  authorized;
- `STWZREL` relation entries authorized by the active/dependency closure;
- `STWZFIX` v2 fixed-table metadata for active components and the target
  preprocessed identity set; and
- `STWZPPC` coefficients for those identities, copied in a bounded streaming
  pass.

Every retained entry payload is copied byte-for-byte. Fixed-table identity
ordinals are rebuilt by identity and checked against every mapping in the
composition projection manifest. Canonical-to-`canonical_without_pedersen` is
the only supported identity projection. Other transitions fail closed.

`STWZFIX` v2 replaces the legacy fixed `161` identity / `22` entry cardinality
with encoded counts and an FNV-1a plan hash over the complete file, treating
bytes `28..36` as zero. Legacy v1 retains its exact cardinality gate. Other
artifacts retain v1 because their readers already validate encoded counts.

The unified `stwo-zig-cairo-program-semantic-pack` v1 manifest binds the
composition projection manifest, source and projected composition bundle
SHA-256 values, composition plan hash, dependency closure, every artifact's
source/output SHA-256 and count, fixed identity ordinal mapping, and projected
fixed-table plan hash.

```sh
python3 scripts/cairo_program_semantic_pack.py \
  --composition-manifest /path/to/fib.composition.projection.json \
  --witness-programs-source vectors/cairo/sn_pie_2_witness_programs.bin \
  --witness-programs-output /path/to/fib.witness.bin \
  --multiplicity-feeds-source vectors/cairo/sn_pie_2_multiplicity_feeds.bin \
  --multiplicity-feeds-output /path/to/fib.feeds.bin \
  --relation-templates-source vectors/cairo/cairo_relation_templates.bin \
  --relation-templates-output /path/to/fib.relations.bin \
  --fixed-tables-source vectors/cairo/cairo_fixed_tables.bin \
  --fixed-tables-output /path/to/fib.fixed.bin \
  --preprocessed-coefficients-source /path/to/canonical.stwzppc \
  --preprocessed-coefficients-output /path/to/fib.preprocessed.stwzppc \
  --output-manifest /path/to/fib.semantic-pack.json
```

The coefficient pass uses constant memory and hashes the complete source while
writing only retained columns. Tests use 161 one-word synthetic records rather
than copying the multi-gigabyte canonical fixture.

The Rust Stwo Cairo prover remains the final correctness oracle. Artifact hash,
format, and dependency validation are prerequisites, not proof-parity evidence.
