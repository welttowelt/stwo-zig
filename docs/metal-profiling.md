# Metal Profiling

This is the profiler operating guide. Its production integration requirements,
async command-graph changes, accounting gates, and roofline plan are specified
in `docs/sn-pie-metal-production-architecture.md`.

The Metal runtime has an opt-in profiler that works with the public Metal API
and does not require Xcode or Instruments. It is disabled unless
`STWO_ZIG_METAL_PROFILE_OUT` names an output file. The disabled path uses the
original `MTLCommandQueue` directly; it does not allocate counter buffers or
proxy command encoders.

With only `STWO_ZIG_METAL_PROFILE_OUT`, the profiler records the full
command-buffer timeline without counter sample buffers. This is the default for
SN PIE proofs. Set `STWO_ZIG_METAL_PROFILE_ENCODER_COUNTERS=1` only for targeted
encoder/kernel drill-downs: stage-boundary sampling strongly perturbs the wide
SN4 transforms and is not appropriate for an end-to-end proving-speed run.

## Capture

Prepend the profile output variable to an existing proof or persistent-session
command. For example, a small standalone commitment capture is:

```sh
PATH="/tmp/zig-xcrun:$PATH" mise x zig@0.15.2 -- \
  zig build metal-bench -Doptimize=ReleaseFast
STWO_ZIG_METAL_PROFILE_OUT=/private/tmp/metal-smoke.ndjson \
STWO_ZIG_METAL_PROFILE_ENCODER_COUNTERS=1 \
  zig-out/bin/metal-bench --columns 16 --log-size 12 --repetitions 1
python3 scripts/metal_profile_report.py \
  /private/tmp/metal-smoke.ndjson \
  --strict \
  --json-out /private/tmp/metal-smoke.report.json
```

For an SN PIE proof, set the same variable on the normal verified full-proof
command. Do not change the proof flags or timing scope for profiling. A
persistent session writes all blocks handled by that Runtime to one NDJSON
stream:

```sh
STWO_ZIG_METAL_PROFILE_OUT=/private/tmp/sn-pie-session.metal.ndjson \
STWO_ZIG_METAL_REPLAY_RETAINED_LOOKUPS=1 \
  python3 scripts/sn_pie_metal_queue.py \
  --manifest scripts/sn_pie_metal_queue.example.json \
  --length 10 --seed 20260715 --production \
  --output-dir /private/tmp/sn-pie-profile-10 \
  --session-command 'zig-out/bin/metal-arena-session --jsonl'
python3 scripts/metal_profile_report.py \
  /private/tmp/sn-pie-session.metal.ndjson \
  --strict --json-out /private/tmp/sn-pie-session.metal.report.json
```

Profile runs are diagnostic runs. Proxy dispatch, debug labels, and NDJSON
writes add overhead; encoder-counter mode adds materially more overhead. Keep
verified unprofiled runs as the MHz source of record, and use identical inputs
and build settings when measuring whether an optimization improved proving
speed.

In encoder-counter mode, `STWO_ZIG_METAL_PROFILE_MAX_ENCODERS` changes the
per-command-buffer sample capacity. The default is 1024. The report fails
`--strict` when this capacity is exceeded, a counter buffer cannot be allocated,
or an encoder lacks a timestamp pair. In command-only mode, intentionally
untimed encoders are valid; command errors and profiler configuration errors
still fail strict mode.

## Recorded Data

The first NDJSON object is `metadata`; later objects are `command_buffer`
events under schema `stwo-metal-profile-v1`. Each command event records:

- Metal command-buffer `GPUStartTime` to `GPUEndTime` and completion status.
- CPU time spent encoding before commit, inside `commit`, and blocked in
  `waitUntilCompleted`.
- In encoder-counter mode, one calibrated GPU timestamp-counter interval for
  every compute and blit encoder.
- Compute pipeline names, dispatch count, total grid threads, maximum
  threadgroup size, inline argument bytes, and debug labels/groups.
- Exact requested copy/fill bytes for blit work.
- `bound_buffer_capacity_bytes`, the unique capacity of buffers bound to an
  encoder. This is a resource-footprint upper bound, not bytes accessed or
  memory bandwidth.

`scripts/metal_profile_report.py` aggregates both command operations and
encoder/kernel names. It always ranks command-buffer GPU time and reports count,
p50, p95, dispatch geometry, bound capacity, CPU wait, and failures. With
encoder counters enabled it also ranks exact encoder GPU intervals and checks
that their sum is consistent with the command-buffer duration. The JSON report
uses schema `stwo-metal-profile-report-v1` and is suitable for regression
comparison.

The M5 Max currently exposes the public `timestamp` counter set with
`GPUTimestamp` and supports stage-boundary sampling. It does not expose public
occupancy, cache, bandwidth, or compute-utilization counters. Those metrics
require the full Xcode Metal tools and a Metal System Trace or GPU capture. Once
Xcode is installed and selected, confirm availability with:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcrun xctrace list templates | grep -E 'Metal|GPU'
```

The public command timeline remains the repeatable full-system ranking and
regression gate. Targeted timestamp-counter captures provide kernel drill-downs.
Instruments is the deeper occupancy and memory-system pass; it does not replace
verified unprofiled MHz measurements.

## Current SN PIE 4 Stage Baseline

The verified warm SN PIE 4 run in
`/tmp/SN_PIE_4.warm-batched-verified.stdout` reports 22.9171 seconds prove wall
time. Its largest existing stage-level GPU totals are composition 3571.846 ms,
witness graph 2667.002 ms, commitments 2385.161 ms, decommit LDE 2282.577 ms,
interaction witness 1452.061 ms, base interpolation 948.608 ms, and OODS
evaluation 743.147 ms. These totals identify the first profiler drill-downs;
they are overlapping hierarchy values in places and must not be summed as a
proof wall time. The command-only profile ranks complete operations without
making the full proof pay the stage-counter cost; targeted encoder-counter runs
then separate kernels within the selected operations.
