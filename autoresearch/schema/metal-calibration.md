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

## Measurement

Build two byte-identical AOT bundles, then measure on the designated M5 host:

```sh
zig build metal-core-aot -Doptimize=ReleaseSafe
python3 scripts/metal_core_aot_receipt.py reproduce \
  --builder zig-out/bin/metal-core-aot \
  --output-dir /tmp/stwo-metal-aot

autoresearch/cli/stwo-perf calibrate-metal measure \
  --aot-bundle /tmp/stwo-metal-aot/build-a \
  --out-dir /tmp/stwo-metal-calibration
```

The command requires a clean exact commit, Apple M5 Max with 18 logical CPUs,
complete Darwin process counters, offline Metal tools, and production source-JIT
runtime admission. The independently reproduced AOT bundle is not mislabeled as
the measured runtime: its source, manifest, and metallib digests are frozen next
to the executed source-JIT identity, and the shader-source digests must agree.
The command executes small, wide, deep, xlarge, and huge sequentially
in manifest order. Each class retains its own command and wall-clock limits.
The existing ABBA runner verifies every proof and requires cross-arm byte
identity. It records A/A dispersion, prove/request medians, peak physical
footprint, process energy, proof bytes, raw report digests, runtime identity,
and AOT source/manifest/metallib digests.

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
