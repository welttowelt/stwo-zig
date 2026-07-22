#!/bin/sh
# Build libstwo_mobile_bench.a for iPhone (arm64-ios) and, if the iOS SDK is
# present, a simulator variant. Run from the repo root: sh mobile/build_ios_lib.sh
# Requires: zig 0.15.2 (the repo's pinned toolchain). Xcode is NOT required
# for the device static lib — only the final app link in Xcode needs it.
set -e

GRAPH="--dep stwo_core --dep stwo_backend_contracts --dep stwo_prover_impl --dep stwo --dep native_resource_admission \
  -Mroot=src/prover/native/mobile_shim.zig \
  -Mstwo_core=src/core/mod.zig \
  --dep stwo_core -Mstwo_backend_contracts=src/backend/mod.zig \
  --dep stwo_core --dep stwo_backend_contracts -Mstwo_prover_impl=src/prover/mod.zig \
  --dep stwo_core --dep stwo_backend_contracts --dep stwo_prover_impl -Mstwo=src/stwo.zig \
  --dep stwo_core --dep stwo_backend_contracts --dep stwo_prover_impl -Mnative_resource_admission=src/prover/native/resource_admission.zig"

echo "== device lib (arm64-ios) =="
zig build-lib -static -OReleaseFast -target aarch64-ios -mcpu baseline $GRAPH \
  --name stwo_mobile_bench
mkdir -p mobile/ios/lib && mv libstwo_mobile_bench.a mobile/ios/lib/
echo "-> mobile/ios/lib/libstwo_mobile_bench.a"

if xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  echo "== simulator lib (arm64-ios-simulator) =="
  zig build-lib -static -OReleaseFast -target aarch64-ios-simulator -mcpu baseline $GRAPH \
    --name stwo_mobile_bench_sim
  mv libstwo_mobile_bench_sim.a mobile/ios/lib/
  echo "-> mobile/ios/lib/libstwo_mobile_bench_sim.a"
else
  echo "(no iOS SDK found — skipped simulator lib; device lib built fine)"
fi
