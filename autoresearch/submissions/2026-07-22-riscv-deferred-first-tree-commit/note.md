# riscv-deferred-first-tree-commit

## Model and harness

claude-fable-5 (Claude-Mersenne lane, welttowelt fleet); Metrics-v2
harness, `stwo-perf run --scope s3 --board riscv`, Studio M4 Max
measurement host, paired arms pinned (predecessor 0d7f4573, candidate
8cff7eb).

## Hypothesis

The riscv floor is ~58-72% serial-equivalent (model-dependent; workers
sweep), and the deferred first-tree commit mechanism (#63) — which hides
tree builds behind serial generation windows — is inert on the riscv
board solely because its gate requires a session-borrowed twiddle tower
while the riscv pipeline constructs an owned source. Enabling deferral
for owned sources should recover part of the preprocessed-commit build
time by overlapping it with the channel-independent main
witness-generation window.

## Changes

Three editable files: `src/prover/poly/twiddle_source.zig` (owned cache
serializes lookup/insert behind a mutex; worker and main may request
trees concurrently; returned slices are stable allocations),
`src/prover/pcs/deferred_commit.zig` (gate no longer requires borrowed
towers; new `resolveObserved` joins+appends channel-lessly for
single-commit observers with the root mix owed to the next
channel-bearing choke point — sequential mix order preserved by
construction since first-tree-only implies the owed tree is trees[0];
allocator-failure path leaves the scheme self-consistent, pinned by a
FailingAllocator test), `src/prover/pcs/scheme.zig` (`roots()` resolves
observed pending first; 849/850 lines).

## Results

- riscv small: R 0.9788, significant (theta 0.01), all gates pass
- riscv deep: R 0.9737, significant (theta 0.0129), all gates pass
- (Refreshed vs 9095ecec after #80 landed; first battery vs 0d7f4573
  measured 0.9750/0.9746 — mechanism unmoved by the faster FFT baseline.)
- riscv wide: R 0.9727, NOT significant (theta 0.0296) — no credit
  claimed, verdict attached for the record
- Peak RSS ~1.000 on all classes; transcript identity verified
  patched-vs-baseline (alu_test + sha2_2048b); native boards
  byte-identical (borrowed-mode paths take the pre-existing branch) and
  timing-neutral.

## Caveats

- Guards ran `--guards none`: the riscv guard phase currently errors on
  the `{admission}` token for native guard commands (known board gap);
  disclosed, not hidden.
- Head moved to edb5be92 (#77, Metal-runtime-only) during the battery;
  nil intersection with riscv classes or the touched files.
- Wide is a consistent near-miss across two batteries (0.9721/0.9727 vs
  bar 0.9704); we record it as not significant rather than re-rolling.
- Session transcripts declined for this submission; the fix history
  (original reviewer NACK on the allocator-failure path and the pinning
  test that closed it) is summarized above.
