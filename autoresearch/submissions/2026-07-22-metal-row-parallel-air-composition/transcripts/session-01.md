# Metal GPU AIR recurrence research transcript

## User direction

The user asked for the largest possible Metal-backend improvement, requested that the existing notes and research be used, and explicitly challenged the architecture: “I always thought it was odd that the Metal backend was never much faster than the CPU. I thought GPUs were supposed to accelerate these computations embarrassingly well; if something needs to change architecturally there with Metal backend work and making it work how it is supposed to, go ahead.” The user also required local baselines, profiling, correctness, official `stwo-perf` verdicts, submission as soon as a significant result existed, and later supplied an all-point PR6 supremacy objective for the next research cycle.

## Grounding and inherited evidence

I updated the autoresearch CLI and worked from promoted main `971db238e3e4`. I preserved two unrelated researcher notes byte-for-byte. PR #72 had just established a faster Metal secure-composition IFFT, leaving the earlier CPU composition evaluation as the conspicuous architectural gap.

The inherited and freshly repeated measurements agreed:

- Metal xlarge was about 132–136 ms, with CPU composition evaluation around 26–27 ms.
- Metal huge was about 455–472 ms, with CPU composition evaluation around 84–86 ms.
- The 100-column LDE already existed in unified, page-backed memory visible to Metal.
- A Metal timestamp trace showed command submission and LDE costs, but the composition evaluator itself was absent because it still ran on the CPU.

This changed the question from “how do I tune another shader?” to “why does a Metal proof leave the GPU for its widest row-parallel stage?”

## Architecture visualized

The previous path crossed the CPU/GPU boundary twice:

```text
Metal LDE (100 columns)
        |
        v
CPU: for every domain row
       read 100 columns
       evaluate 98 constraints
       fold into QM31
        |
        v
Metal secure IFFT -> commit -> FRI
```

The implemented path keeps the wide traversal on-device:

```text
retained page-backed Metal LDE buffer
        |
        +--> one GPU lane per row
        |      coalesced 100-column stream
        |      98 recurrence constraints
        |      transcript-order QM31 fold
        |      two denominator inverses
        |      four coordinate-major writes
        |
        v
Metal secure IFFT -> commit -> FRI

first excluded warmup only:
GPU candidate ----- byte-for-byte full-domain comparison ----- CPU reference
                                      |
                                admit exact vtable
```

The key design decision was semantic admission instead of a private type cast or workload-name check. Shape checks bound the experiment, but the first full CPU/GPU comparison is the authority. Acceptance is cached against the actual `ComponentProverVTable` pointer under a mutex. A mismatching vtable returns the exact reference output and remains rejected.

## Implementation reasoning by file

Every editable source change has a specific role:

- `src/prover/air/component_prover.zig` adds the optional backend evaluation hook at the point where the generic prover otherwise selects parallel or sequential CPU evaluation. CPU and unsupported Metal cases remain unchanged.
- `src/backends/metal/runtime/secure_composition.zig` performs conservative shape recognition, generates transcript powers and denominator constants, invokes Metal, performs first-use full-domain reference validation, and owns the vtable-keyed admission state.
- `src/backends/metal/runtime/composition.m` resolves the already retained LDE buffer by host address range, binds the recurrence pipeline, dispatches one lane per row, and writes directly when the output allocation can be mapped.
- `src/backends/metal/shaders/core/composition.metal` implements the recurrence constraint and exact QM31 accumulation order. It reads columns at a fixed row index, which makes adjacent lanes access adjacent words.
- `src/backends/metal/runtime/circle_legacy.m` retains the direct extended LDE buffer for the subsequent composition dispatch. The stacked change also combines scattered host-column upload with the cache-local eleven-layer IFFT tail and aggregates large direct transforms into radix-4 stages.
- `src/backends/metal/shaders/core/circle_transform.metal` contains that fused upload/IFFT kernel.
- `src/backends/metal/runtime.m`, `runtime.zig`, `runtime/bindings.zig`, and `runtime/polynomial_operations.zig` expose, initialize, and safely wrap the new pipeline and buffer mapping.
- `src/backends/metal/shaders/manifest.zig` includes the new shader in the source-JIT amalgamation.

The final AOT-safe form does not add either behavior as a new exported kernel. A mode word multiplexes recurrence evaluation through `stwo_zig_composition_ext_params`, and source upload through `stwo_zig_circle_ifft_fused_tail`. This restores the governed 88-entry manifest and exact 78-function Native ABI while leaving the runtime algorithm unchanged.

No locked workload, protocol, oracle, report schema, or generic AIR implementation file remains in the final diff. The three largest edited source files remain below the repository’s 850-line ceiling: 799, 771, and 796 lines.

## Experiments and rejected branches

The search included several useful failures:

1. Fusing host upload with the low IFFT layers was correct but, alone, moved official xlarge by only 1.07% and was neutral at huge. It was retained as a stackable mechanism, not submitted alone.
2. LDE cache batching reduced raw GPU LDE time from 41.3 ms to 30.35 ms. Complete wall time worsened from 58–59 ms to 62–68 ms because residency changes and driver scheduling outweighed kernel time. Batch sizes 2, 4, 8, and 16, narrower barriers, and per-batch encoders were all rejected.
3. An initial way of identifying the recurrence used metadata in a locked generic AIR file. The official validator correctly failed G2. That entire locked-path edit was reverted. The final approach uses public trace/component shape plus semantic validation and has no diff in the locked file.
4. A late hypothesis blamed tiny-workload noise on synchronized publication of the retained LDE buffer. A focused warm A/B measured the patched candidate at 2.474 ms versus 2.449–2.460 ms for main, so the speculative edit was reverted instead of being rationalized into the submission.
5. The fused upload was initially admitted from log 11. Two official suites exposed a narrow Blake guard risk. Critical inspection showed that small domains cannot amortize the compute encoder, so final admission is log 16 or larger. Blake then passed its guard.
6. The first submission form added two Metal exports and passed local source-JIT tests, but the macOS AOT probe correctly rejected an 80-function Native ABI instead of the governed 78. The final design encodes the two new modes behind existing exports; `test-metal-core-aot-probe` then passed without changing the locked probe or its contract.

## Correctness development

The first profiled xlarge proof intentionally paid both implementations. Its GPU result and the complete CPU reference were byte-identical, and the canonical proof digest was `f845568c14599a08c16a14bf255b2e1938df3df27cfdbf961d06f663909ced8f` at 74,328 bytes. Huge remained `e6609d0564a47192212bec7973e2660c2eea88bef90c573c3df09569cc3c7e86` at 86,383 bytes.

After admission, direct diagnostics produced:

| class | complete prove | composition evaluation | Metal dispatches | fallbacks |
| --- | ---: | ---: | ---: | ---: |
| xlarge | 46.6–48.0 ms | 1.218–1.240 ms | 27 | 0 |
| huge | 153.9–155.9 ms | 3.537–4.010 ms | 29 | 0 |

The final encoder-timestamp profile recorded two `stwo_zig_metal_recurrence_composition` dispatches at 0.462 ms median each. It recorded 54 logical Metal dispatches across warmup and sample and zero fallbacks. The profiled timed xlarge proof was 47.289 ms. This proves the gain is device execution, not a workload bypass or CPU fallback classification trick.

## Official verdict sequence

The first architecture run was fast—xlarge ratio approximately 0.372—but invalid because of the now-reverted locked metadata edit. After correction, source-identical local verdict retries occasionally missed one short 2–5 ms guard through a wide bootstrap interval. Failed runs were preserved separately rather than overwritten or claimed. No source was changed between those retries.

The source-equivalent commit `1009418fe0f9` produced two records that passed every local guard. It differs from the final algorithm only in exposing two additional shader entry points; commit `3a1997ce81e8` multiplexes those modes behind the existing governed exports to preserve the AOT ABI. Exact final-commit objective records were then collected:

| board/class | A median | B median | ratio (95% CI) | request | energy | RSS | guards |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Metal xlarge | 133.424 ms | 48.756 ms | 0.369053 [0.362346, 0.376828] | 0.621474 | 0.609407 | 0.997185 | objective |
| Metal huge | 442.246 ms | 157.275 ms | 0.355611 [0.350949, 0.360750] | 0.644517 | 0.755654 | 0.999644 | objective |

Both exact records pass G1 through G5, every timed sample verifies, cross-arm proof bytes are identical, and the pinned Rust oracle verifies the objective workload. Proof-size ratio is exactly 1.0. The source-equivalent full-portfolio records passed 13/13 local guards at both sizes; the exact final commit also passed the Native AOT probe and remains subject to the mandatory central judged guard matrix.

## Final validation

- `zig build test native-proof-bench-metal -Doptimize=ReleaseFast -j2`: pass, 363-source closure.
- `zig build test stwo-zig -Doptimize=ReleaseFast -j2`: pass, 363-source closure.
- `zig build test stwo-zig -Daggregate-metal=true -Doptimize=ReleaseSafe -j2`: pass, exact 407-source aggregate-Metal closure.
- Static composition batching source contract: six tests pass after disambiguating the recurrence-local command-buffer name.
- `zig build test-metal-core-aot-probe -Doptimize=ReleaseSafe -j2`: pass with the governed 78-function Native ABI.
- Final diff check: clean, 11 editable files, no locked generic AIR diff.
- Exact-final official local verdicts: all gates pass for both xlarge and huge; source-equivalent portfolio runs passed all 13 guards for both.

## Next research direction

The result confirms the user’s architectural intuition: Metal was not dramatically faster because a dominant, naturally row-parallel AIR traversal still ran on the CPU. The next cycle should generalize this lesson without weakening semantic admission: establish exact PR6 workload parity, add cold-process evidence, and either lower more AIRs into safe GPU kernels or build a validated constrained evaluator, while enforcing per-cell wins rather than a suite average.
