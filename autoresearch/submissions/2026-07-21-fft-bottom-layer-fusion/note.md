# Fused bottom FFT layers and degenerate-first-layer extension skip

## Model and harness

Model: Claude Fable 5. Autonomous session on an Apple M4 Pro (12 cores)
running macOS. Candidate built in a fresh `stwo-perf clone` on tip
`8e58d701`; predecessor is the clean canonical checkout at the same commit,
re-synced immediately before the final paired runs. Evidence chain:
`--profiled` stage attribution, `stwo-prof zig isolate` hardware counters on
live repo code, and `stwo-perf run --scope s3` paired verdicts with the
pinned Rust oracle. No file overlap with the concurrently pending
`cpu-merkle-subtree-scheduling` submission, so the two attribute
independently.

## Hypothesis

The isolated per-column extend-evaluate (2^14 coefficients zero-padded into
a 2^15 buffer) measured 101 µs, 2.22M instructions at IPC 5.56 —
compute-bound, so only instruction reduction pays. Two structural defects in
the circle-FFT cascade account for a large instruction share:

1. **Degenerate first layer under zero-padding.** The largest layer pairs
   every lower-half element with a padded zero: `v ± 0·t = v`. The cascade
   nevertheless memset the upper half and ran full butterflies over the
   whole buffer — the layer is exactly "duplicate the lower half".
2. **Near-scalar bottom layers.** The half-block-4 and half-block-2 layers
   run short-vector fallbacks with per-block call overhead, and the final
   adjacent-pair layer issues one scalar call per pair (16384 calls at
   2^15). All three layers operate strictly within 8-element blocks, and
   the last two share one interleaved twiddle slice (x at even, y at odd
   indices, pair-layer pattern `[y, -y, -x, x]`), so the three layers fuse
   into one in-register pass with three twiddle loads per block.

Prediction: byte-identical proofs with a double-digit percentage cut in FFT
instructions, visible in the interpolate, extended-evaluation, and
composition interpolate/split stage telemetry across the scored classes.

## Changes

- `src/prover/poly/circle/fft_kernels.zig`: `fftBottomThreeLayersForwardM31`
  and `fftBottomThreeLayersInverseM31` — per 8-element block: two 4-lane
  loads, three modular multiplies, six shuffles, two stores; butterfly
  order, twiddle selection, and arithmetic identical to the unfused cascade.
- `src/prover/poly/circle/transforms.zig`: forward and inverse cascades
  (single-buffer and batched) stop at half-block 8 and finish with the fused
  kernel; new `evaluateExtensionBufferWithTwiddles` (+ batched form) replaces
  the upper-half memset and the first layer with one memcpy when the
  coefficient count is exactly half the target domain.
- `src/prover/poly/circle/poly.zig`,
  `src/prover/pcs/columns/circle_transforms.zig`: padded-evaluate callers
  route through the extension path when `coeffs.len * 2 == values.len`
  (always true at the suite's blowup factor 1); mixed batches keep the
  original path.

Small domains (log size < 4) keep the original cascade; the fused kernels
assert 8-element alignment, which every fused call site guarantees.

## Results

Isolated column extend-evaluate: 101 → 85 µs, 2.22M → 1.49M instructions
(−33%). Fixed proof digests match the committed values on all three
workloads; every timed sample verified and byte-identical; `zig build test`
passes. Warmed wide-class stage medians: evaluate_extended_domain
0.773 → 0.647 ms, interpolate_columns 0.322 → 0.283 ms,
composition_interpolate_and_split 0.469 → 0.428 ms.

Paired S3 against the clean predecessor (15/7/10 rounds, quiet machine,
G1–G5 green, 13/13 guards on every run):

| class | R | 95% CI | theta | outcome |
| --- | --- | --- | --- | --- |
| wide | 0.9477 | [0.9388, 0.9666] | 0.0293 | significant — claimed |
| deep | 0.9701 | [0.9487, 0.9819] | 0.0183 | upper CI 0.0002 over the gate — reported, not claimed |
| small | 0.9723 | [0.9618, 0.9842] | 0.0373 | not significant — reported, not claimed |

The wide verdict is attached as the claimed objective. Deep and small moved
in the predicted direction but did not clear the significance gate on the
first attempt; per the no-first-significance-fishing discipline they are
recorded here as measured, with no re-rolled runs.

## Caveats

- The end-to-end effect is concentrated where FFT stages carry weight (wide
  above all); classes whose verdicts did not clear the significance gate are
  reported as measured, not claimed.
- Verdicts are claimed/advisory from an M4 Pro; the judged re-run is
  authoritative. The mechanism (fewer instructions in fixed serial kernels)
  is topology-independent, so it should transfer across hosts.
- The fused kernel fixes 4-lane vector shapes; wider-SIMD hosts still run
  it as 4-lane. The unfused packed paths remain for all other layers.
- A CPU combined interpolate+evaluate hook (saving a copy pass between the
  inverse and forward FFT) is a natural follow-up and was deliberately left
  out to keep this diff single-mechanism.
