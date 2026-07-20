# Enumerate bit-reversed FRI cosets in linear group work

## Model and harness

Model: GPT-5 Codex. Harness: repo-resident `stwo-perf`, updated before research
to current `main` at `b275053b9c42`. The change was measured in ReleaseFast on
arm64 macOS with paired S3/time runs against the unchanged updated-main
predecessor. A reasoning-first sanitized session transcript is attached.

All four prior promoted notes, transcripts, and diffs were read before new
profiling. Their packed quotient rows, resident/deeper Merkle scheduling,
four-way FRI leaf cascade, and packed sampled-value evaluation are retained and
treated as the starting frontier.

## Hypothesis

Both circle-to-line and line-to-line FRI folds filled inverse-coordinate
workspaces by calling `domain.at(bitReverseIndex(i << 1, log_size))` for every
output. Each indexed lookup reconstructed a circle-group point from the set
bits of its index, repeating roughly logarithmic group work per coordinate.

For `w = log_size - 1`, `bitrev_log_size(2*i) = bitrev_w(i)`, and bit reversal
is self-inverse. A coset is already an arithmetic progression with a fixed
group step. Walking it once in natural order and scattering point `j` to
destination `bitrev_w(j)` must therefore produce the identical coordinate
array with linear rather than `N log N` group work.

The pinned upstream Rust CPU fold calls the same indexed lookup and explicitly
labels it inefficient pending stored domain twiddles. The selected traversal
uses only this repository's existing coset iterator and bit-reversal helper; no
external implementation is copied.

## Changes

Added one private coordinate-filling helper in `src/core/fri/folding.zig`. It
walks a circle coset through repeated addition of its fixed step and scatters
either x or y coordinates through the existing bit-reversal permutation. Four
duplicated indexed-generation loops now use it:

- allocating and in-place line folds;
- secure-slice and coordinate-column circle folds.

The batch inversion inputs are byte-for-byte equivalent and remain in the same
order. Inversion, butterfly arithmetic, alpha powers, evaluation ownership,
Merkle hashing, transcript order, and protocol output are unchanged. A new
differential test checks the traversal against independent indexed lookup for
shifted line and circle cosets at every log size from the minimum through 15.

## Results

An S1 live-core ABBA profile at log size 14 measured the coset-walk candidate
at 3.823 ns per coordinate versus 28.177 ns for indexed reconstruction. The
baseline/candidate wall ratio was 7.3005 with 95% CI [7.1535, 7.4194]; the
candidate used about 12.7% of the instructions and 13.6% of the cycles.

Seven-sample profiled diagnostics showed the intended FRI stage moving from
3.870 to 3.229 ms on wide and 3.804 to 3.177 ms on deep, about a 16.5% stage
reduction. All fresh proofs retained the frontier digests and were mutually
byte-identical.

Paired S3 results, 15 rounds each, all with G1–G5 passing:

- small `wf_log10x8`: ratio **0.9690**, 95% CI **[0.9507, 0.9824]**,
  1.590 to 1.540 ms;
- wide `wf_log14x32`: ratio **0.9408**, 95% CI **[0.9284, 0.9539]**,
  11.412 to 10.752 ms;
- deep `plonk_log14`: ratio **0.9189**, 95% CI **[0.9091, 0.9610]**,
  8.108 to 7.456 ms.

The three-class geometric ratio is approximately **0.9427**, a **5.73%** suite
improvement before judge rerun. ReleaseFast core, prover, and native CPU product
closures passed across 70, 152, and 190 transitive Zig sources respectively.

## Caveats

These are local claimed verdicts; the locked judge rerun is authoritative. The
anchor remains unfrozen, so judged promotion and drift budgets are inactive.
Native mechanism telemetry is still pending in the harness; the live counter
ratio, exact stage reduction, source complexity change, shifted-domain
differential test, and byte-identical proofs provide the current mechanism
evidence.

Metal was measured for applicability as requested, but the scored binary is
compile-time CPU-only and rejects Metal options, so no Metal change can move
this board. Full Metal System Trace was unavailable because the host has
Command Line Tools rather than full Xcode; this did not affect CPU profiling or
the paired verdicts.
