"""Independent validation of canonical identities emitted by focused products."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

try:
    from scripts.product_identity_lib import (
        ProductIdentityError,
        canonical_identity_sha256,
        validate_canonical_identity,
    )
except ModuleNotFoundError:
    from product_identity_lib import (
        ProductIdentityError,
        canonical_identity_sha256,
        validate_canonical_identity,
    )


ProductEvidenceError = ProductIdentityError


@dataclass(frozen=True)
class ProductSpec:
    name: str
    frontend: str
    backend: str
    report_backend: str
    protocol_features: str
    runtime_manifest: str
    sdk_manifest: str
    aot_manifest: str


PRODUCT_SPECS = {
    "cpu": ProductSpec(
        name="stwo-native-cpu",
        frontend="native-examples",
        backend="cpu",
        report_backend="cpu_native",
        protocol_features="native-examples-v1+lifted-pcs-v1",
        runtime_manifest="none",
        sdk_manifest="none",
        aot_manifest="none",
    ),
    "metal": ProductSpec(
        name="stwo-native-metal",
        frontend="native-examples",
        backend="metal",
        report_backend="metal_hybrid",
        protocol_features="native-examples-v1+lifted-pcs-v1+metal-runtime-v1",
        runtime_manifest="metal-runtime-v1:source-jit+authenticated-aot",
        sdk_manifest="apple-metal-sdk:metal3.1:safe-math",
        aot_manifest="metal-aot-v1:source+compile-profile+metallib-sha256",
    ),
}


def validate_product_identity(
    value: Any,
    lane: str,
    *,
    provenance: dict[str, Any] | None = None,
    required_role: str = "benchmark",
) -> dict[str, Any]:
    if lane not in PRODUCT_SPECS:
        raise ProductEvidenceError(f"unknown focused-product lane: {lane}")
    validate_canonical_identity(value, context=f"{lane}.product_identity")
    spec = PRODUCT_SPECS[lane]
    expected = {
        "name": spec.name,
        "frontend": spec.frontend,
        "backend": spec.backend,
        "role": required_role,
        "protocol_features": spec.protocol_features,
        "runtime_manifest": spec.runtime_manifest,
        "sdk_manifest": spec.sdk_manifest,
        "aot_manifest": spec.aot_manifest,
    }
    for field, expected_value in expected.items():
        if value[field] != expected_value:
            raise ProductEvidenceError(
                f"{lane}.product_identity.{field} does not identify {spec.name}"
            )
    if provenance is not None:
        bindings = {
            "implementation_commit": "git_commit",
            "implementation_dirty": "git_dirty",
            "zig_version": "zig_version",
            "target_arch": "target_arch",
            "target_os": "target_os",
            "optimize": "optimization",
        }
        for identity_field, provenance_field in bindings.items():
            if value[identity_field] != provenance.get(provenance_field):
                raise ProductEvidenceError(
                    f"{lane}.product_identity.{identity_field} disagrees with report provenance"
                )
    return value


def comparable_identity(identity: dict[str, Any]) -> dict[str, Any]:
    """Fields that must match for timing comparisons across source revisions."""

    return {
        field: identity[field]
        for field in (
            "schema_version",
            "name",
            "frontend",
            "backend",
            "role",
            "protocol_features",
            "protocol_manifest_sha256",
            "zig_version",
            "target_arch",
            "target_os",
            "target_abi",
            "cpu_model",
            "cpu_features_sha256",
            "optimize",
            "runtime_manifest",
            "sdk_manifest",
            "aot_manifest",
        )
    }
