"""Active-scope dependency and thin-owner policy."""

from __future__ import annotations

BUILD_ROOT_CEILING = 500
BUILD_SUPPORT_CEILING = 500
PYTHON_ROOT_CEILING = 350
PYTHON_ENTRYPOINT_CEILING = 100
ZIG_OWNER_CEILING = 300
ZIG_ENTRYPOINT_CEILING = 200
RUST_ENTRYPOINT_CEILING = 100
ACTIVE_NATIVE_RUST_CRATES = frozenset({"stwo-interop-rs", "stwo-vector-gen"})
ACTIVE_PERFORMANCE_ROOTS = (
    "scripts/benchmark_delta.py",
    "scripts/compare_optimization.py",
    "scripts/metal_profile_report.py",
    "scripts/native_profile_capture.py",
    "scripts/native_proof_matrix.py",
)
# Higher-level evidence packages may consume these stable lower-level contracts.
PYTHON_LIBRARY_DEPENDENCIES = {
    "native_profile_capture_lib": frozenset({"native_proof_matrix_lib"}),
}
PYTHON_LIBRARY_TARGETS = {
    "native_profile_capture_lib": frozenset({"scripts/metal_profile_report.py"}),
}
DEFERRED_PREFIXES = (
    "src/bench/cairo_metal/",
    "src/frontends/cairo/",
    "src/frontends/riscv/",
    "src/integrations/cairo_metal/",
    "src/metal_arena_plan_cli.zig",
    "src/riscv_",
    "src/tests/cairo/",
    "src/tests/riscv/",
    "src/tools/cairo/",
    "src/tools/cairo_metal_codegen/",
    "src/tools/metal_arena_plan/",
    "src/tools/metal_prover_session/",
    "src/tools/metal_session/",
    "scripts/cairo_",
    "scripts/riscv_",
    "scripts/sn_pie_",
    "scripts/tests/test_cairo_",
    "scripts/tests/test_riscv_",
    "scripts/tests/test_sn_pie_",
    "tools/stark-v-",
    "tools/stwo-cairo-",
)
