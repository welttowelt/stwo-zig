# PR6 Supremacy architecture status

> **PR6 Supremacy: not achieved.**

This note records material, general changes on the path to the disabled
`pr6_supremacy` board. It is not a judged verdict.

## Exact matrix before optimization

The board enumerates all 18 required statements. Existing repository Blake,
Plonk, and state-machine examples are explicitly not treated as PR6 ports: PR6
uses a multi-component Blake scheduler/round/XOR-table AIR, a two-interaction-
column Plonk LogUp AIR, and a two-component state machine with global relation
cancellation. Dedicated ports and oracle vectors remain required.

The wide-series runner now treats the following as independent decisions:

```text
                 verified request                 cold process
CPU      peer A -> Zig B -> Zig B -> peer A   A -> B -> B -> A
Metal    peer A -> Zig B -> Zig B -> peer A   A -> B -> B -> A
                   >= 7 rounds                     >= 7 rounds
```

It cannot omit log22. The explicit `extreme` profile admits exactly
419,430,400 cells / 6,710,886,400 accounted bytes while leaving `standard` and
`large` unchanged. Raw samples retain binary/source/shader/toolchain identities,
protocol and statement digests, proof identity, timing, throughput, RSS,
available hardware counters, admission, dispatches, and fallbacks. Missing
Metal synchronization telemetry is explicit and keeps the board disabled.

## Identity-bound cold-process provenance

Profiling showed that warmed source-JIT/session initialization was about 21 ms
at log14, but every Zig proof process also spawned `git rev-parse` and
`git status` after verification. Production product binaries already embed a
validated identity containing commit, tree, dirty-content digest, toolchain,
target, protocol, runtime, SDK, and AOT identities.

Identity-bearing binaries now validate and use that immutable build identity,
while still collecting runtime environment overrides. This removes two child
processes from every complete proof process. Binaries without a product
identity retain runtime Git discovery, so compatibility behavior fails closed.
No workload or size admits the path; it follows only from the structural
presence of a validated product identity.

Local seven-round log14 results on the M5 Max:

| boundary | lane | peer ms | Zig ms | ratio | 95% CI high |
| --- | --- | ---: | ---: | ---: | ---: |
| verified request | CPU | 23.326 | 13.269 | 0.5688 | 0.5798 |
| verified request | Metal | 31.831 | 9.690 | 0.3044 | 0.3135 |
| cold process | CPU | 41.797 | 26.265 | 0.6284 | 0.6545 |
| cold process | Metal | 73.835 | 56.477 | 0.7649 | 0.7949 |

Both ABBA halves win in all four decisions; no sample was discarded. PR6's own
log14 `metal` build deliberately uses its CPU-parallel trace helper below 2^16;
the runner records that peer property rather than inventing Metal work. Zig
Metal remains device-only with zero CPU fallbacks.

## Remaining architecture work

- Port and oracle-gate exact PR6 Blake, Plonk, fixed-wide-Fibonacci, and state
  machine statements.
- Expose per-request Metal command-buffer wait/synchronization counters.
- Run both boundaries through log22, then profile every losing cell.
- Add the forced combined Metal LDE/Merkle differential test.
- Close the broad Native/Metal/RISC-V resource portfolios and publish one
  authenticated locked-M5 `kind: judged` verdict from a clean immutable commit.
