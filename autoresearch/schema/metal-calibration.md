# Metal calibration contract

`core_metal` is score-bearing only after every manifest class has a frozen,
same-host A/A calibration in the current ledger epoch. There is no generic
dispersion fallback.

## Authority

The reviewed freeze spans three files and they must land together:

- `autoresearch/MANIFEST.json` owns the designated host, runtime mode, artifact
  path, frozen identity digests, and prove/request/resource anchor maps.
- `autoresearch/ledger/epochs.json` owns per-class A/A dispersion and repeats
  the exact anchor and identity binding for the current epoch.
- `autoresearch/reference/metal-calibration-epoch-<N>.json` is the immutable
  measurement artifact.

The loader recomputes a calibration-policy digest from the class registry,
Metal group commands, resource/sampling bounds, and statistical policy. A
workload or policy edit therefore makes old calibration evidence stale. It
also verifies that the measured commit remains in `HEAD` history, the artifact
digest matches, manifest and epoch bindings agree, every counter is positive,
and each A/A confidence interval contains 1. Missing or mismatched values fail
closed before a judged Metal run starts.

The v2 freeze binds the runtime actually executed: the embedded shader source
digest, canonical source-JIT runtime manifest, shader-amalgamation digest,
Objective-C runtime digest, SDK manifest, and Metal platform identity. It does
not require or bind an offline metallib that calibration never executes. A v1
AOT-era report or freeze is rejected; migration requires a fresh v2 run.

## Measurement

Build and measure the source-JIT product on the designated M5 host:

```sh
zig build native-proof-bench-metal -Doptimize=ReleaseFast

autoresearch/cli/stwo-perf calibrate-metal measure \
  --out-dir /tmp/stwo-metal-calibration
```

The command requires a clean exact commit, Apple M5 Max with 18 logical CPUs,
complete Darwin process counters, the macOS SDK/Clang used by the focused
product, and production source-JIT runtime admission. Full Xcode's offline
`metal` and `metallib` tools are not prerequisites.
The command executes small, wide, deep, xlarge, and huge sequentially
in manifest order. Each class retains its own command and wall-clock limits.
The existing ABBA runner verifies every proof and requires cross-arm byte
identity. It records A/A dispersion, prove/request medians, peak physical
footprint, process energy, proof bytes, raw report digests, and runtime identity.

## Review and freeze

Validate the candidate independently, then stage the coordinated freeze:

```sh
autoresearch/cli/stwo-perf calibrate-metal validate \
  --report /tmp/stwo-metal-calibration/calibration.json

autoresearch/cli/stwo-perf calibrate-metal freeze \
  --report /tmp/stwo-metal-calibration/calibration.json

autoresearch/cli/stwo-perf calibrate-metal validate --require-frozen
```

`freeze` requires the exact measured commit at `HEAD` and a clean tree. It does
not commit or publish. Reviewers must commit the artifact, manifest, and epoch
ledger in one change. The weekly/manual `Metal calibration` workflow only
produces and uploads evidence; it deliberately has no write permission and
never freezes policy automatically.
