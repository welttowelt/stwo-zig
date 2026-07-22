# Rotate large shared columns across hardware pages

## Model and harness

GPT-5 Codex optimized candidate `bf7cf1849130` against exact predecessor
`5bf964b78643` on an Apple M5 Max. The repository CLI was updated before the
search. Final evidence uses harness `8d9c30a5778c`, ReleaseFast CPU and Metal
products, paired S3 proof transactions, independent verification, and the
pinned correctness oracle.

Metal uses the production source-JIT path on this host. Embedded MSL is
compiled by the macOS Metal runtime before timed samples; no Xcode offline
compiler is present or required. Every profiled Metal proof remained device-
accelerated with 26 dispatches at xlarge, 28 at huge, and zero CPU fallbacks.

## Hypothesis

Profiles explained why Metal had not pulled far ahead of CPU. At huge, Metal
reduced main-trace commitment from roughly 184 ms on CPU to about 91 ms, but
the hybrid prover then spent about 403 ms evaluating composition on the host.
That stage walks each row across 100 column-major arrays produced in unified
memory by Metal.

The already-promoted layout used a 64-byte skew after each power-of-two column.
That rotates cache-line sets, but an 8 MiB logical column still advances the
virtual address by an exact power-of-two number of pages. Most simultaneous
streams therefore retain repeated page/TLB geometry.

```text
Metal LDE output (unified memory)
            │
            ▼
before: [column N words][64 B]          repeated page geometry
after:  [column N words][16 KiB + 64 B] page + cache-line rotation
            │
            └────────► existing CPU AIR row traversal, no gather/copy
```

This is conflict-avoiding array padding/page coloring: it preserves every
logical column slice while changing only physical base addresses. On this
Apple-silicon host, both `getconf PAGESIZE` and `hw.pagesize` report 16,384
bytes. For 100 columns the extra storage is only about 1.55 MiB.

## Changes

For groups with at least 64 columns and at least 2^18 M31 values (1 MiB) per
extended column, the physical stride is now:

```text
logical_column_words + hardware_page_words + 16 M31 words
```

Smaller columns keep the predecessor's 64-byte skew exactly. The first broad
version applied page padding to every 64+-column group. Although Metal huge
improved 12.67%, Blake regressed 8–10% and Poseidon 12–16% because a 16 KiB pad
was material at those small sizes. The cost-model gate restores their prior
layout while selecting xlarge's 2 MiB and huge's 8 MiB extended columns.

No shader, buffer binding, dispatch, synchronization, ownership, proof order,
or AOT ABI changes. Metal-produced columns remain retained through their
existing commitment-tree owners and are consumed as the same contiguous
logical slices.

## Results

| board / class | predecessor median | candidate median | paired R (95% CI) | improvement |
| --- | ---: | ---: | ---: | ---: |
| CPU xlarge `wf_log18x100` | 165.947 ms | 146.031 ms | 0.878534 [0.864409, 0.889791] | 12.15% |
| CPU huge `wf_log20x100` | 687.070 ms | 601.631 ms | 0.878685 [0.875646, 0.883551] | 12.13% |
| Metal xlarge `mwf_log18x100` | 160.028 ms | 139.680 ms | 0.867736 [0.844552, 0.874057] | 13.23% |
| Metal huge `mwf_log20x100` | 565.486 ms | 495.138 ms | 0.880262 [0.868619, 0.888441] | 11.97% |

Request-time ratios are 0.920004, 0.919739, 0.916035, and 0.927620 in table
order. Peak-RSS ratios are 1.003347, 0.995143, 1.003128, and 1.001007; energy
ratios are 0.933821, 0.934418, 0.901533, and 0.902716. Proof sizes remain
exactly 74,328 bytes at xlarge and 86,383 bytes at huge.

All four verdicts pass G1–G5 and all 13 regression guards. Every timed proof
verified, cross-arm digests were byte-identical in every round, and the pinned
oracle accepted all four objective workloads.

## Profiling attribution and rejected alternatives

Three alternated profiled huge screens isolated the effect. CPU composition
moved from 327–330 ms to 270–272 ms; Metal composition moved from 363–371 ms
to 286–289 ms. Metal main-trace commitment stayed around 93–94 ms, so the win
is specifically the host AIR fan-in over GPU-produced unified memory rather
than a change in GPU arithmetic or dispatch count.

A smaller synthetic probe using a 4 KiB displacement moved only about 1%; it
had accidentally modeled one quarter of this host's hardware page. The full
implementation's 16 KiB displacement and paired complete proofs supplied the
decisive evidence. Raising the CPU combined-column ceiling did not admit the
617-column RISC-V tree and was neutral on its already-admitted 188-column tree,
so that change was reverted. A row-major transpose or full gather would add an
800 MiB pass and break existing column-slice consumers; unsafe workload-
specific GPU type inference was rejected because the editable AIR vtable does
not expose a typed constraint program.

## Caveats and next architecture step

The win deliberately targets megabyte-scale, 64+-column groups. Narrow and
small-domain shapes retain the predecessor layout. This repairs the dominant
shared-memory boundary but does not move composition arithmetic onto Metal:
doing that safely requires an explicit typed constraint IR or GPU-evaluable AIR
interface rather than guessing through an opaque callback.
