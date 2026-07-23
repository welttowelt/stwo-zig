# Sanitized research transcript: Apple performance-core work-pool sizing

Model: Claude Fable 5, with CODEX ANVIL independent review.

## Attribution and hypothesis

A quiet worker-count battery on an 8P+4E Apple host found that eight workers
beat twelve on Native wide in every ABBA pair. The first interpretation was
not accepted as a shippable constant: eight would idle performance cores on a
larger M5 topology. The hypothesis was reformulated as a transfer-safe runtime
policy—use the highest-performance Apple core cluster, not a host-specific
number.

## Implementation and critique

The candidate queries `hw.perflevel0.logicalcpu` on macOS and preserves the
existing total-logical fallback elsewhere. The explicit environment override
still takes precedence. Live detection returned the expected performance-core
count on the development host. Proofs generated with default detection and a
forced worker count were byte-identical, confirming that worker topology
changes scheduling rather than protocol output.

An M4 Pro magnitude screen retained the winning direction but its two nominally
equivalent eight-worker arms differed too much to grade. That result was not
promoted. The final battery was moved to the quieter Studio rather than
rerolled on the noisy host.

## Validation

Before timing, the canonical launch preflight checked live upstream main,
candidate and predecessor HEADs, direct merge-base, clean trees, canonical
`origin/main`, and empty run state. It emitted:

`S3_PREFLIGHT_OK main=799efe87... candidate=9888ea2... tree=b64a6012...`

The exact-current Studio S3 produced R=0.962604 with workload 95% CI
[0.954890, 0.968034], all 13 guards green, pinned Rust oracle success,
cross-arm proof identity, proof-byte ratio 1.0, and peak-RSS ratio 0.888580.
The measured energy ratio 1.010550 and the mildly slower but in-budget guards
are disclosed in the submission note.
