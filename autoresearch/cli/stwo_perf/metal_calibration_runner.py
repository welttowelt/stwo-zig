"""Bounded, sequential M5 Metal calibration measurement."""

from __future__ import annotations

import copy
import json
import os
import platform
import subprocess
from pathlib import Path

from . import ledger, runner
from .manifest import Manifest
from .metal_calibration import (
    ANCHOR_FIELDS,
    BOARD,
    RUNTIME_MODE,
    SCHEMA,
    CalibrationError,
    policy_sha256,
    sha256,
    validate_document,
)


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True,
    )
    return result.stdout.strip()


def _command(*argv: str) -> str | None:
    try:
        result = subprocess.run(
            argv, check=False, capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def _collect_host() -> dict:
    """Collect source-JIT provenance without importing repository-level scripts."""
    profile = _command(
        "system_profiler", "SPHardwareDataType", "SPDisplaysDataType",
        "-json", "-detailLevel", "mini",
    )
    document = json.loads(profile) if profile is not None else {}
    hardware_rows = document.get("SPHardwareDataType", [])
    display_rows = document.get("SPDisplaysDataType", [])
    hardware_row = (
        hardware_rows[0]
        if isinstance(hardware_rows, list) and hardware_rows
        and isinstance(hardware_rows[0], dict)
        else {}
    )
    display_row = (
        display_rows[0]
        if isinstance(display_rows, list) and display_rows
        and isinstance(display_rows[0], dict)
        else {}
    )
    sdk_path = _command("xcrun", "--sdk", "macosx", "--show-sdk-path")
    clang_path = _command("xcrun", "--sdk", "macosx", "--find", "clang")
    required = {
        "os_product_version": _command("sw_vers", "-productVersion"),
        "os_build_version": _command("sw_vers", "-buildVersion"),
        "hardware.machine_model": hardware_row.get("machine_model"),
        "hardware.chip": hardware_row.get("chip_type"),
        "metal_device.name": display_row.get("sppci_model") or display_row.get("_name"),
        "metal_device.metal_family": display_row.get("spdisplays_mtlgpufamilysupport"),
        "toolchain.developer_dir": _command("xcode-select", "-p"),
        "toolchain.macos_sdk_path": sdk_path,
        "toolchain.macos_sdk_version": _command(
            "xcrun", "--sdk", "macosx", "--show-sdk-version"
        ),
        "toolchain.clang_path": clang_path,
        "toolchain.zig_version": _command("zig", "version"),
    }
    blockers = [f"missing_{name}" for name, value in required.items() if value is None]
    return {
        "schema": "native_matrix_host_environment_v1",
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "os_product_version": required["os_product_version"],
            "os_build_version": required["os_build_version"],
        },
        "hardware": {
            "machine_model": hardware_row.get("machine_model"),
            "machine_name": hardware_row.get("machine_name"),
            "chip": hardware_row.get("chip_type"),
            "physical_memory": hardware_row.get("physical_memory"),
            "logical_cpu_count": os.cpu_count(),
        },
        "metal_device": {
            "name": display_row.get("sppci_model") or display_row.get("_name"),
            "gpu_cores": display_row.get("sppci_cores"),
            "metal_family": display_row.get("spdisplays_mtlgpufamilysupport"),
        },
        "toolchain": {
            "developer_dir": required["toolchain.developer_dir"],
            "macos_sdk_path": sdk_path,
            "macos_sdk_version": required["toolchain.macos_sdk_version"],
            "clang_path": clang_path,
            "clang_version": _command(clang_path, "--version") if clang_path else None,
            "runtime_compiler": "Metal.framework_source_jit_bound_to_os_build",
            "zig_version": required["toolchain.zig_version"],
        },
        "randomness": {
            "external_seed": None,
            "input_policy": "canonical_workload_descriptor_and_fixed_statement",
            "proof_policy": "deterministic_transcript_no_external_random_seed",
        },
        "complete": not blockers,
        "blockers": blockers,
    }


def _measurement_manifest(manifest: Manifest) -> Manifest:
    raw = copy.deepcopy(manifest.raw)
    suffix = f" --metal-runtime {RUNTIME_MODE}"
    for workload in raw["workload_registry"]["groups"]["metal"]["workloads"].values():
        workload["args"] += suffix
    return Manifest(root=manifest.root, raw=raw)


def _runtime_evidence(
    class_dir: Path, expected_commit: str, expected_tree: str,
) -> tuple[list[str], dict]:
    digests: list[str] = []
    identities: dict[bytes, dict] = {}
    for path in sorted(class_dir.glob("*.json")):
        encoded = path.read_bytes()
        try:
            report = json.loads(encoded)
        except json.JSONDecodeError:
            continue
        if not isinstance(report, dict) or report.get("schema_version") != 7:
            continue
        identity = report.get("product_identity")
        admission = report.get("runtime_admission")
        resources = report.get("resources")
        if not isinstance(identity, dict) or identity.get("backend") != "metal":
            raise CalibrationError(f"{path.name}: report is not the Metal product")
        if identity.get("implementation_commit") != expected_commit:
            raise CalibrationError(f"{path.name}: product identity commit mismatch")
        if identity.get("implementation_tree") != expected_tree:
            raise CalibrationError(f"{path.name}: product identity tree mismatch")
        if identity.get("implementation_dirty") is not False:
            raise CalibrationError(f"{path.name}: product identity is dirty")
        if (
            not isinstance(admission, dict)
            or admission.get("origin") != "diagnostic_source_jit"
            or admission.get("initialized") is not True
            or admission.get("manifest_sha256") is not None
            or admission.get("metallib_sha256") is not None
        ):
            raise CalibrationError(f"{path.name}: production source-JIT was not admitted")
        if not isinstance(resources, dict) or resources.get("complete") is not True:
            raise CalibrationError(f"{path.name}: resource vector is incomplete")
        runtime_manifest = identity.get("runtime_manifest")
        aot_manifest = identity.get("aot_manifest")
        sdk_manifest = identity.get("sdk_manifest")
        platform_identity = admission.get("platform_identity")
        if (
            not isinstance(runtime_manifest, str)
            or "mode=source-jit" not in runtime_manifest
            or not isinstance(aot_manifest, str)
            or aot_manifest != "none"
            or not isinstance(sdk_manifest, str)
            or not sdk_manifest.startswith("apple-metal-sdk-v2:")
            or not isinstance(platform_identity, str)
            or not platform_identity
        ):
            raise CalibrationError(f"{path.name}: runtime identity is incomplete")
        fields: dict[str, str] = {}
        prefix, separator, payload = runtime_manifest.partition(":")
        for item in payload.split(";") if separator == ":" else ():
            key, item_separator, value = item.partition("=")
            if item_separator != "=" or not key or not value or key in fields:
                raise CalibrationError(f"{path.name}: runtime manifest is malformed")
            fields[key] = value
        if prefix != "metal-runtime-v2" or tuple(fields) != (
            "mode", "shader-amalgamation-sha256", "runtime-objc-sha256",
        ) or fields["mode"] != RUNTIME_MODE:
            raise CalibrationError(f"{path.name}: runtime manifest is unsupported")
        if admission.get("source_sha256") != fields["shader-amalgamation-sha256"]:
            raise CalibrationError(
                f"{path.name}: executed shader source differs from the runtime manifest"
            )
        selected = {
            "runtime_manifest": runtime_manifest,
            "runtime_manifest_sha256": sha256(runtime_manifest.encode("utf-8")),
            "sdk_manifest": sdk_manifest,
            "sdk_manifest_sha256": sha256(sdk_manifest.encode("utf-8")),
            "source_sha256": admission.get("source_sha256"),
            "shader_amalgamation_sha256": fields["shader-amalgamation-sha256"],
            "runtime_objc_sha256": fields["runtime-objc-sha256"],
            "platform_identity": platform_identity,
            "platform_identity_sha256": sha256(platform_identity.encode("utf-8")),
        }
        key = json.dumps(selected, sort_keys=True, separators=(",", ":")).encode()
        identities[key] = selected
        digests.append(sha256(encoded))
    if not digests:
        raise CalibrationError(f"no Native report artifacts found under {class_dir}")
    if len(identities) != 1:
        raise CalibrationError("Metal runtime identity changed during calibration")
    return sorted(set(digests)), next(iter(identities.values()))


def _release_lock(lock: Path) -> None:
    try:
        words = lock.read_text(encoding="utf-8").split()
        if words and words[0] == str(os.getpid()):
            lock.unlink()
    except OSError:
        pass


def measure(manifest: Manifest, out_dir: Path) -> Path:
    """Measure every score-bearing Metal class in manifest order.

    The command never samples classes concurrently and every class retains its
    manifest wall deadline, preventing huge-trace calibration from monopolizing
    a host.
    """
    if _git(manifest.root, "status", "--porcelain"):
        raise CalibrationError("Metal calibration requires a clean repository")
    commit = _git(manifest.root, "rev-parse", "HEAD")
    tree = _git(manifest.root, "rev-parse", "HEAD^{tree}")
    current_epoch = ledger.current_epoch(manifest.root)
    config = manifest.raw["harness"]["metal_calibration"]
    if config["epoch"] != current_epoch["epoch"]:
        raise CalibrationError("manifest calibration target is not the current epoch")
    if config["runtime_mode"] != RUNTIME_MODE:
        raise CalibrationError("Metal calibration runtime mode must be source-jit")

    host = _collect_host()
    if host["complete"] is not True or host["blockers"] != []:
        raise CalibrationError("host environment provenance is incomplete")
    expected_host = config["designated_host"]
    if (
        host["hardware"]["chip"] != expected_host["chip"]
        or host["hardware"]["logical_cpu_count"] != expected_host["logical_cpu_count"]
    ):
        raise CalibrationError("this is not the manifest-designated M5 judge host")

    out_dir = out_dir.resolve()
    if out_dir.exists() and any(out_dir.iterdir()):
        raise CalibrationError("calibration output directory must be empty")
    out_dir.mkdir(parents=True, exist_ok=True)
    measurement_manifest = _measurement_manifest(manifest)
    class_results: dict[str, dict] = {}
    runtime_identity: dict | None = None
    lock = runner.acquire_judge_lock(manifest.root)
    try:
        for name in manifest.class_names(board=BOARD, scored_only=True):
            class_dir = out_dir / "raw" / name
            result = runner.evaluate_aa(
                manifest.root,
                measurement_manifest,
                name,
                class_dir,
                board=BOARD,
            )
            ci = result["portfolio"]["ci"]
            if not ci[0] <= 1.0 <= ci[1]:
                raise CalibrationError(
                    f"{name}: A/A interval excludes 1; investigate order/thermal bias"
                )
            report_digests, class_identity = _runtime_evidence(
                class_dir, commit, tree,
            )
            if runtime_identity is None:
                runtime_identity = class_identity
            elif runtime_identity != class_identity:
                raise CalibrationError("Metal runtime identity differs between classes")
            anchor = {
                "prove_ms": result["anchor_prove_ms"],
                "request_ms": result["anchor_request_ms"],
                **result["anchor_resources"],
            }
            if anchor["proof_bytes"] is not None and float(anchor["proof_bytes"]).is_integer():
                anchor["proof_bytes"] = int(anchor["proof_bytes"])
            if set(anchor) != set(ANCHOR_FIELDS) or any(value is None for value in anchor.values()):
                raise CalibrationError(f"{name}: calibration anchor vector is incomplete")
            class_results[name] = {
                "classification": "neutral",
                "aa_r": result["aa_r"],
                "ci": ci,
                "dispersion": result["half_width"],
                "anchor": anchor,
                "measurement_rounds": result["portfolio"]["measurement_rounds"],
                "measurement_seconds": result["portfolio"]["measurement_seconds"],
                "report_sha256s": report_digests,
            }
    finally:
        _release_lock(lock)

    assert runtime_identity is not None
    identity_payload = dict(runtime_identity)
    runtime_identity = {
        "identity_sha256": sha256(
            b"stwo-perf-metal-runtime-identity-v2\0"
            + json.dumps(identity_payload, sort_keys=True, separators=(",", ":")).encode()
        ),
        **identity_payload,
    }
    document = {
        "schema": SCHEMA,
        "board": BOARD,
        "epoch": current_epoch["epoch"],
        "repository": {"commit": commit, "tree": tree, "dirty": False},
        "policy_sha256": policy_sha256(manifest),
        "runtime_mode": RUNTIME_MODE,
        "host": host,
        "runtime_identity": runtime_identity,
        "classes": class_results,
    }
    validate_document(document, manifest)
    output = out_dir / "calibration.json"
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return output
