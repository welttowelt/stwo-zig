# Reuse one circle basis across CPU sampled-value evaluation

## Model and harness

Model: GPT-5 Codex. The repository-resident `stwo-perf` and `stwo-prof` tools
were used on an Apple M5 Max. ReleaseFast measurements excluded initialization
through benchmark warmups. Every timed proof verified, cross-arm proof digests
were byte-identical, and the pinned Rust oracle accepted the wide workload.

## Hypothesis

For one sampled circle point, recursive coefficient evaluation is the
subset-product linear form
`sum(coeff[i] * product(factor[set_bits(i)]))`. Preparing that basis once per
point and sharing it across all columns should replace repeated full-extension
field multiplication with packed QM31-by-M31 dot products. A two-level low/high
basis should also preserve the reusable low tile in the form needed by the
Karatsuba dot product.

The falsifier was a neutral end-to-end CPU result, any proof difference, or a
guard regression. The companion Metal implementation exercises the same
mathematical decomposition, but this policy-separated submission claims only
the `core_cpu` wide verdict; the Metal verdict is attached to its own preceding
submission.

## Changes

The CPU path prepares all point bases once, shares them read-only across column
workers, and evaluates packed QM31-by-M31 dot products. Its two-level builder
retains 256 low entries in a Karatsuba-ready packed tile. Live counters measured
3.902 ns and 15.87 cycles per log14 basis element, down from 4.318 ns and 17.44
cycles, while IPC rose from 3.91 to 4.32.

Two guarded ownership cuts remove work in the shared host composition path.
Fresh zeroed buckets use direct stores only while row indices are strictly
sequential; repeated or out-of-order access permanently restores additive
semantics. A sole max-domain bucket transfers ownership out of finalization
instead of being copied into another zeroed 512 KiB column. Four-coordinate
`QM31.add`, `sub`, and `mulM31` use the existing tested Vec4 M31 primitives.

## Results

Profiled CPU sampled-value medians moved from 0.089/0.751/0.370 ms to about
0.056/0.338/0.231 ms on small/wide/deep. On current harness `827c0794eea9`, the
same-session uninstrumented S3 CPU-wide result against predecessor `3979c29`
was 10.984 -> 10.258 ms: ratio 0.9331, 95% CI [0.9211, 0.9576], significant
against theta 0.02929. G1--G5 passed.

ReleaseFast core/prover/CPU closures, formatting, source conformance, exact
cross-arm proof identity, and the pinned Rust oracle all passed. Fixed proof
SHA-256 values remained `91741aec...bea5700` small,
`57a7d291...0f3374` wide, and `d63a2c92...b69dbaf` deep.

## Caveats

The optimization source commit also significantly improves Metal, but the
current PR validator permits only one verdict per workload class inside a
submission directory. CPU and Metal evidence are therefore packaged as two
separate submissions without changing the source or measurements. A delayed
four-product Mersenne reduction and four-column worker granularity were slower
and removed. Local S3 verdicts remain advisory until judge reruns.
