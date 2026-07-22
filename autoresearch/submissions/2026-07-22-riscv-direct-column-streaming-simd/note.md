# Vectorize lifted Merkle leaf streams directly from columns

## Model and harness

GPT-5 Codex developed and measured this change with refreshed `stwo-perf`
harness `083877c03a81` on the Apple M5 Max host. The clean immutable candidate
is `f6ef4dd0bcd5165d767b9e81d754347b7f40ffdf` over current-main predecessor
`e6e86b072604f63c78c995f1edd2dbc9152f2de7`. The submitted S3 result covers
the complete seven-program RISC-V deep portfolio in ReleaseFast mode with
paired counterbalanced processes, independent proof verification, resource
telemetry, and the repository-pinned Stark-V oracle.

## Hypothesis

The fresh SHA2-2048 sample put packed incremental BLAKE2s leaf ingestion at the
frontier: it repeatedly staged column-major M31 values into row-major byte
tiles and maintained one large scalar state per leaf. Four adjacent rows are
already the four independent SIMD lanes consumed by the backend's parallel
BLAKE2s compressor. Continuing those four states directly from canonical
columns should remove message repacking, state-array expansion, barriers, and
scratch traffic without changing a single hashed byte.

## Changes

The lifted PCS now admits a structural sparse-tail commit when the remaining
high-domain columns fit the canonical terminal block. A new four-message
BLAKE2s continuation primitive loads complete 16-word blocks directly from
four adjacent column rows and completes the four final states together. The
streaming builder still prepares columns in bounded batches and retains the
same extended columns and PCS order; scalar and big-endian paths retain exact
fallbacks.

The optimization is selected by concrete hasher type, domain shape, column
height, and terminal-block capacity—not workload name, input, or benchmark
size. Differential tests cover distinct prefixes and long updates, distinct
tails, direct column continuation against scalar streams, and the forced
sparse commitment root against the fully materialized generic path.

```text
old: batches -> row staging -> per-leaf states -> finish
new: columns -> four adjacent rows -> SIMD continuation -> sparse finish
```

Two broader alternatives were measured and rejected. Deferring all columns to
the generic mixed-height commit regressed SHA2-2048 request time to 1.220x and
instructions to 1.720x because it rebuilt every mixed-height leaf message.
Grouping existing incremental batches by height was neutral at 1.004x request
and 1.002x instructions. Both experiments were completely reverted. A first
winning candidate passed performance and oracle gates but touched locked
generic wrappers; the specialization was moved into the editable lifted-prover
adapter before the final clean run.

## Results

Every deep workload improves against current main:

| workload | proving ratio | 95% CI | verified-request ratio | energy ratio |
| --- | ---: | ---: | ---: | ---: |
| xorshift | 0.9091 | [0.9048, 0.9127] | 0.9160 | 0.9078 |
| Fibonacci | 0.9392 | [0.9348, 0.9445] | 0.9429 | 0.9083 |
| GCD | 0.9336 | [0.9296, 0.9367] | 0.9379 | 0.9019 |
| multi-shard | 0.9107 | [0.9078, 0.9190] | 0.9140 | 0.9091 |
| SHA2-512 | 0.9302 | [0.9173, 0.9484] | 0.9484 | 0.9025 |
| SHA2-1024 | 0.9426 | [0.9360, 0.9503] | 0.9492 | 0.9072 |
| SHA2-2048 | 0.9469 | [0.9415, 0.9506] | 0.9579 | 0.9190 |

The portfolio proving ratio is **0.930236**, with 95% CI
**[0.927643, 0.933370]**: 7.0% less latency. Geometric-mean energy falls 9.2%
to ratio 0.907941, peak RSS is flat at 1.000545, and proof bytes remain exactly
1.0. The new profile shows packed leaf ingestion collapsing from a leading 774
samples to 49; canonical four-way compression, memory movement, LogUp,
quotient execution, and FFT are the new frontier.

## Correctness and validation

Every timed proof verified independently, candidate and predecessor proof
digests were byte-identical in every paired round, and the pinned Stark-V oracle
accepted all 7/7 programs. Mechanism telemetry was canonical and stable. The
full 374-source ReleaseFast test closure, formatting, source conformance,
RISC-V CPU product, Native CPU product, and device-only Native Metal lifecycle
all pass. Metal completed independent verification with zero CPU fallback.

## Caveats

This is a local claimed verdict; only the authenticated locked judge rerun can
promote it. The harness's automatic Native guard mapping is malformed for this
RISC-V objective, so the paired run used `--guards none` and all three affected
product boundaries were run explicitly and sequentially. The exact PR6
all-cell matrix, log22 oracle vectors, both required timing boundaries, and
judged M5 verdict remain incomplete.

**PR6 Supremacy: not achieved.**
