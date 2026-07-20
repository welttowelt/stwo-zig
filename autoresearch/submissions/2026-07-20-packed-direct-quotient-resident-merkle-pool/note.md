# Pack direct quotient rows and reuse the resident Merkle pool

## Model and harness

Model: GPT-5 Codex. Harness: stwo-perf at `962dbbae393f`, ReleaseFast on arm64 macOS, paired S3 wide/time against predecessor `31a3132ef2e6`. The repository test closure passed across 356 transitive Zig sources. Transcripts: none capturable.

## Hypothesis

FRI quotient construction spends repeated scalar work accumulating direct lifting-column contributions into four M31 numerator planes. Traversing native packed row lanes should preserve each output cell's contribution order while reducing loop and arithmetic instructions. Merkle commits already run under a prover-global work pool, so their layer executors can reuse that resident pool instead of constructing short-lived pools.

## Changes

Direct-column quotient contributions now load four adjacent rows as one native `PackedM31`, reuse that base vector across the four secure-field coordinate planes, and perform packed multiply/add/store operations. Non-direct views retain the scalar index mapping. Full tiles clear their contiguous numerator allocation with one memset; partial tiles retain plane-aware clearing. Merkle commits reuse an installed global pool while keeping the existing environment opt-in fallback for standalone callers.

## Results

S1 isolated quotient-tile A/B: wall ratio 0.5089, 95% CI [0.5041, 0.5132], instruction ratio 0.3632, cycle ratio 0.4455. arm64 disassembly contains packed `ldr q`/`str q`, `umull.2d`/`umull2.2d`, `uzp1.4s`, and `add.4s` operations in `quotient_tile_executor.execute`.

S3 `wf_log14x32`: ratio 0.9736, 95% CI [0.9639, 0.9862], 15 paired rounds; predecessor median 17.761 ms, candidate median 17.321 ms. Every timed sample verified and remained byte-identical; proof SHA-256 was `57a7d291eb8a103d0e4395c23fd7dc9ab7e9ed2d0f95558835cc6482630f3374`.

## Caveats

This is a local claimed result. The anchor is not frozen, so budgets and judge-host promotion remain pending; the immutable judge rerun is authoritative. Native mechanism telemetry wiring is also still listed as pending by the harness, with the counter and codegen evidence above providing the current mechanism check. The optimization targets direct full-size columns, so small workloads are not expected to move materially.
