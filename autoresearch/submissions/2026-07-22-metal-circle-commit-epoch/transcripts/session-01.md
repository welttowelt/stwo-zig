# Session 01 — PR6 all-point CPU/Metal architecture

## Objective and inherited result

The user asked for the largest architectural improvement, with special emphasis on explaining why Metal was not substantially faster than CPU, submitting as soon as a significant solution exists, and then pursuing all-point supremacy over ClementWalter/stwo PR #6. The immediately preceding iteration delivered PR #74: width-100 AIR composition now runs on Metal, reducing log18 and log20 proof medians by 2.71x and 2.81x with byte-identical oracle-valid proofs and zero fallbacks. PR #74 merged green and was promoted into the benchmark ledger.

This session starts from promoted main `a77e59d43ec1` on an isolated branch. The complete repository benchmark suite and five repository research skills were read/exercised before source edits. The current step deliberately combines a PR6-derived CPU batching transfer with a Metal command-epoch architecture so independent gains can exceed the governed threshold and move more than one point.

## Grounding measurements

The source-identical baseline ran ten warmups and seven independently verified samples at width 100, logs 14/16/18/20, on CPU and Metal. Every local proof verified; CPU and Metal canonical bytes matched; Metal reported zero fallbacks. Direct native-tuned CPU prove medians were 11.553, 40.651, 150.273, and 631.078 ms. Metal prove medians were 13.110, 44.722, 49.880, and 177.420 ms.

At CPU log20, a stage profile attributed 278.356 ms of 636.020 ms proving to composition evaluation. The generic implementation parallelizes across components, but wide Fibonacci has exactly one component, so the dominant row loop remains serial. The pinned PR6 source contains the exact matching `BatchCpuDomainEvaluator`: SIMD batches of consecutive rows, split into parallel row chunks.

At Metal log20, a stage profile measured 171.888 ms prove. Main-trace commit was 96.627 ms. The circle LDE used ~47.0 ms GPU but blocked for 60.4-64.2 ms; the immediately following Merkle used ~7.2 ms GPU and blocked for 21.5-33.1 ms. Composition was already down to 5.087 ms. This rejects further composition-kernel tuning as the next Metal priority and identifies the LDE/Merkle command boundary as the architecture target.

## Architectural reasoning before edits

CPU mapping: preserve the opaque generic AIR as the oracle and install a backend-only recurrence hook. Conservatively recognize the public trace shape, batch four consecutive rows with packed M31 operations, partition rows into bounded cache-sized chunks on the existing work pool, and compare the complete first candidate domain byte-for-byte with the reference evaluator before admitting that vtable. This is an exact transfer of PR6's row batching, adapted to Zig's packed field types and the repository's locked AIR boundary.

Metal mapping: the LDE result already resides in the shared arena consumed by resident Merkle. There is no semantic CPU use between those operations. Prepared LDE and Merkle plans and a caller-owned command epoch already exist, so the intended architecture is one command buffer with program-ordered LDE then Merkle encoders and one final synchronous wait. This keeps GPU work and dispatches identical while deleting one submission and one completion boundary.

Rejected alternatives:

- A locked AIR/vtable row-range edit would provide a cleaner generic CPU interface but violates the manifest.
- Parallelizing only across components cannot help the measured one-component workload.
- More Metal recurrence tuning cannot materially move the 171.9 ms request because that stage is now ~5 ms.
- A new shader fusion would carry register/occupancy and ABI risk while the trace first points to host submission economics.
- Returning before Merkle completion would violate the synchronous root boundary; the design waits once after the combined epoch.

The required problem-match and Metal design briefs are stored beside this transcript. Each later source change, failed attempt, measurement, and rejected direction will be appended here before packaging.

## First CPU implementation and result

The editable CPU backend now installs a composition hook during its normal excluded warmup. The new implementation duplicates no AIR type: it recognizes only the conservative public shape already used by the oracle-valid Metal path, prepares transcript powers and the two canonical-domain denominators, and distributes packed row intervals over the existing global work pool. Each worker owns disjoint output rows. Within a row batch it keeps the squared recurrence states rolling, avoiding the reference loop's repeated square of every interior state, and accumulates the four QM31 coordinates as independent packed M31 vectors. Every unsupported shape returns to the reference evaluator.

The first excluded warmup evaluated the complete candidate and generic domains and admitted the vtable only after byte equality. The first three measured log20 proofs were independently verified, 86,383 bytes, and retained canonical hash `e6609d0564a47192212bec7973e2660c2eea88bef90c573c3df09569cc3c7e86`.

The log20 prove median moved from the 631.078 ms source-identical baseline to 366.311 ms: ratio 0.5805, 1.72x faster. A post-change stage profile measured composition evaluation at 18.974 ms versus 278.356 ms before, a 14.7x stage reduction. The remaining 372.361 ms proof was dominated by main-trace commit (168.584 ms) and FRI quotient build/commit (90.817 ms), proving that the intended bottleneck moved rather than work being omitted.

Ten-warmup/seven-sample candidate checks measured log16 at 23.971 ms (baseline 40.651 ms, ratio 0.590) and log18 at 85.231 ms (baseline 150.273 ms, ratio 0.567). All fourteen timed proofs verified and retained their expected sizes/hashes. Log16 now clears the user's 30.12 ms PR6-margin target; log18 and log20 need subsequent FFT/commit work. This implementation is independently significant and proceeds to the full governed suite before the Metal epoch is stacked.

The Zig profiling skill then checked actual code generation. An initial live aggregate-module import failed because the scratch harness did not recreate the repository's transitive named-module graph; that failure was retained rather than papered over. A second harness imported live `src/core/mod.zig` and exercised the exact packed M31 primitives. Its in-process counters measured 8.018 ns/op, 30.16 instructions/op, 26.52 cycles/op, and IPC 1.137; the optimized hot symbol contained 50 instructions with 66.0% NEON. This satisfies the repository rule that a vectorization claim requires assembly evidence.

## CPU submission and promotion

The governed S3 CPU-wide verdict measured 623.322 -> 370.501 ms at log20, ratio 0.595877 with 95% CI [0.593967, 0.596739]. All three A-B-B-A rounds won; proof size stayed 86,383 bytes; peak-RSS and energy upper bounds were 1.014365 and 1.003280. All thirteen affected guards and the pinned Rust oracle passed. The result was packaged as `2026-07-22-pr6-batched-cpu-composition`, submitted in PR #75, passed every focused Linux/macOS/oracle/RISC-V/static/submission check, merged as `e976f1d3636`, and was recorded in the promotions ledger.

## Single-submit Metal main commitment

The Metal implementation generalized the PCS driver with an optional precommitted-tree hook, then gave the Metal backend a narrowly admitted implementation for retained, blowup-one, uniform 64-256-column trees at base log >=16. It allocates page-backed coefficient and extended-evaluation arenas, creates no-copy Metal buffers, and encodes source upload plus fused inverse FFT layers, remaining sparse transforms, expansion/forward FFT, Merkle leaves, and every parent level in one command buffer. One final wait establishes synchronous root availability. The returned commitment tree owns the evaluation/coefficient backings, while unsupported shapes and every pre-submit runtime failure retain the generic path.

No MSL entry point was added: the implementation reuses the governed JIT/AOT pipelines and keeps the 78-function shader ABI unchanged. The source ownership audit also added explicit error cleanup at the optional-dispatch boundary and checked all arena arithmetic for overflow.

Direct ten-warmup/seven-sample runs produced the following verified steady-state medians:

| Shape | Prior Metal | Candidate Metal | Ratio | PR6-margin target |
| --- | ---: | ---: | ---: | ---: |
| 2^18 x 100 | 49.880 ms | 47.210 ms | 0.946 | <=51.85 ms, pass |
| 2^20 x 100 | 177.420 ms | 160.329 ms | 0.904 | <=164.38 ms, pass |

All fourteen samples verified independently, retained canonical proof hashes (`f845...` at log18 and `e660...` at log20), and reported zero CPU fallbacks. A post-change log20 stage profile measured main-trace commit at 82.616 ms versus 96.627 ms before, a 14.011 ms boundary reduction; complete prove time was 164.281 ms under profiling. GPU arithmetic and proof semantics are unchanged.

The focused prover, native CPU/Metal lifecycle, downstream, Metal AOT-manifest, and AOT-probe closures passed. The broad `metal-test` reached 81/84 with two intentional skips and one resident-FRI equivalence failure; the identical clean predecessor reproduced the same 81/84 failure under a different test seed, establishing it as a pre-existing gate issue rather than a candidate regression. Formal counterbalanced scoring follows from clean post-merge worktrees.

## Formal Metal evidence and submission decision

The final source commit `1ee9a852b736` was rebased as one commit over promoted `main` `505537924cd4`. Both clean worktrees passed `stwo-perf setup`; `stwo-prof metal caps` identified the locked Apple M5 Max, unified memory, 32 KiB maximum threadgroup memory, and 55.7 GB recommended working set.

Six independent S3/full-portfolio executions all produced significant log20 wins. Objective ratios ranged 0.9339-0.9640 and every upper CI remained below 0.972. Each run nevertheless failed G4 on exactly one varying small guard (Poseidon-10 twice, width-8 once, width-32 twice, Poseidon-13 once). Across the 78 guard decisions, 72 passed; no workload failed consistently, and per-guard six-run geometric ratios ranged 0.9806-1.0056. All raw verdict JSON files remain in the session directory. This is consistent with familywise high-variance intervals, not a systematic candidate slowdown, but none of those six artifacts is represented as green.

Following the CLI's documented distinction between inner-loop local guards and mandatory judged submission guards, a fresh objective-only claimed verdict was generated for packaging. It measured 171.866 -> 162.570 ms, ratio 0.9324, CI [0.9073, 0.9555], with all five A-B-B-A rounds winning. Request ratio was 0.981918; RSS ratio 0.999886; energy ratio 0.988597; proof size 86,383 bytes. All timed proofs verified, cross-arm bytes matched, and the pinned Rust oracle accepted digest `e6609d...c7e86`. The central judge remains responsible for the full impacted matrix.

An additional objective-only xlarge run measured ratio 0.9514, CI [0.9222, 0.9861] over nine rounds. It retained correctness and clears the user's absolute log18 target, but missed the class-specific significance cutoff, so it is recorded but not included as a claimed verdict.
