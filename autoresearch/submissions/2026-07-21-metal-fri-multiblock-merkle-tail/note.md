# Parallelize Metal FRI Merkle tails across bottom subtrees

## Model and harness

Model: GPT-5 Codex.  The repo-resident autoresearch CLI was updated before this
campaign.  Candidate `f01a645ad829` is measured against exact promoted
predecessor `6c622c60297d` on an Apple M5 Max.  Native Metal measurements use
the real ReleaseFast product, functional protocol, independent verification,
and `--metal-runtime source-jit`; macOS compiles the embedded MSL through
`newLibraryWithSource`, so no offline Metal compiler or full Xcode is involved.

## Hypothesis

The thirteen-tree wide/deep FRI cascade still launched separate global parent
grids for the bottom levels of large Merkle trees.  The existing parent-tail
kernel could reduce an entire shallow tree in one threadgroup, but was used
only after the whole remaining level fit a single group.  Making its global
addressing relative to `threadgroup_position_in_grid` lets one dispatch reduce
many independent bottom subtrees concurrently, followed by the existing upper
tail, without increasing register pressure in the fold/coordinate/leaf
producers.

## Changes

Each selected 128-thread bottom group consumes 256 leaves, retains at most 128
parent hashes in 4 KiB of threadgroup memory, and writes every logical parent
level and block root.  The upper tail retains its 256-thread capacity so small
trees do not gain an extra launch.  Wide/deep line-FRI topology moves from 68
to 58 dispatches; small remains exactly 38.  Buffer bindings, shader export
inventory, hash order, transcript order, proof data, source-JIT/AOT admission
split, and the one-command-buffer/one-wait epoch are unchanged.

## Results

Fifteen clean process pairs per class alternated A-B / B-A order.  Every
process used ten verified warmups and seven timed verified proofs.  Across all
90 reports, 630/630 timed proofs independently verified, matched the fixed
class digests, and remained byte-identical within each process.  Every sample
classified accelerated-without-fallbacks, with zero CPU fallback and zero
post-warmup direct compilation.

| class | predecessor | candidate | B/A HL (95% CI) | wins |
| --- | ---: | ---: | ---: | ---: |
| small `wf_log10x8` | 2.660 ms | 2.632 ms | 0.9937 [0.9785, 1.0110] | 9/15 |
| wide `wf_log14x32` | 11.725 ms | 11.629 ms | 0.9946 [0.9867, 1.0049] | 11/15 |
| deep `plonk_log14` | 7.088 ms | 7.031 ms | 0.9915 [0.9856, 0.9959] | 13/15 |

The robust three-class geometric-mean ratio is 0.99325, about 0.68% less proof
latency.  Deep is confirmed; small and wide are favorable but neutral and are
not overclaimed.

## Validation

A strengthened log-10 parity fixture forces four independent bottom
threadgroups and checks every coordinate, Merkle root, transcript challenge,
and terminal evaluation against the CPU reference.  Native Metal product and
lifecycle, `metal-check`, source conformance, core-AOT contract, AOT probe
contract, and a proof under both Metal API and GPU shader validation pass.  The
broad Metal suite remains at the predecessor's 80/83 baseline: two expected
skips and the same pre-existing resident-policy assertion.

## Caveats

The official autoresearch board is CPU-only.  Its S3 deep control passes G1--G5
at 0.9929 [0.9830, 0.9992] but is correctly classified neutral against theta
0.0183; no CPU-board credit is claimed for a Metal-only change.  The attached
reasoning transcript also retains the rejected producer-microtree design and
its occupancy regression rather than folding that dead end into the result.
