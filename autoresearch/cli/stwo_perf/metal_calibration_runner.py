"""Bounded, sequential M5 Metal calibration measurement."""

from __future__ import annotations

import copy
import json
import os
import subprocess
from pathlib import Path

from scripts.metal_core_aot_receipt_lib import ReceiptError, load_bundle
from scripts.metal_core_aot_receipt_lib.artifacts import bundle_identity
from scripts.native_proof_matrix_lib.provenance import (
    collect_static,
    validate_environment,
)

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


def _runtime_manifest_sha(bundle: dict) -> str:
    return bundle["files"]["stwo_zig_core.manifest.json"]["sha256"]


def _measurement_manifest(manifest: Manifest) -> Manifest:
    raw = copy.deepcopy(manifest.raw)
    suffix = f" --metal-runtime {RUNTIME_MODE}"
    for workload in raw["workload_registry"]["groups"]["metal"]["workloads"].values():
        workload["args"] += suffix
    return Manifest(root=manifest.root, raw=raw)


def _runtime_evidence(class_dir: Path, expected_commit: str) -> tuple[list[str], dict]:
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
        platform_identity = admission.get("platform_identity")
        if (
            not isinstance(runtime_manifest, str)
            or "mode=source-jit" not in runtime_manifest
            or not isinstance(aot_manifest, str)
            or aot_manifest != "none"
            or not isinstance(platform_identity, str)
            or not platform_identity
        ):
            raise CalibrationError(f"{path.name}: runtime identity is incomplete")
        selected = {
            "runtime_manifest": runtime_manifest,
            "runtime_manifest_sha256": sha256(runtime_manifest.encode("utf-8")),
            "aot_manifest": aot_manifest,
            "aot_manifest_sha256": sha256(aot_manifest.encode("utf-8")),
            "source_sha256": admission.get("source_sha256"),
            "platform_identity": platform_identity,
            "platform_identity_sha256": sha256(platform_identity.encode("utf-8")),
        }
        key = json.dumps(selected, sort_keys=True, separators=(",", ":")).encode()
        identities[key] = selected
        digests.append(sha256(encoded))
    if not digests:
        raise CalibrationError(f"no Native report artifacts found under {class_dir}")
    if len(identities) != 1:
        raise CalibrationError("Metal runtime/AOT identity changed during calibration")
    return sorted(set(digests)), next(iter(identities.values()))


def _release_lock(lock: Path) -> None:
    try:
        words = lock.read_text(encoding="utf-8").split()
        if words and words[0] == str(os.getpid()):
            lock.unlink()
    except OSError:
        pass


def measure(manifest: Manifest, bundle_path: Path, out_dir: Path) -> Path:
    """Measure every score-bearing Metal class in manifest order.

    The caller supplies one independently reproduced AOT bundle.  The command
    never samples classes concurrently and every class retains its manifest
    wall deadline, preventing huge-trace calibration from monopolizing a host.
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

    try:
        bundle = load_bundle(bundle_path.resolve(strict=True))
    except (OSError, ReceiptError) as exc:
        raise CalibrationError(f"invalid AOT calibration bundle: {exc}") from exc
    bundle_id = bundle_identity(bundle)
    aot = {
        "format": bundle["manifest"]["format"],
        "bundle_identity_sha256": sha256(
            json.dumps(bundle_id, sort_keys=True, separators=(",", ":")).encode()
        ),
        "source_sha256": bundle["files"]["stwo_zig_core.metal"]["sha256"],
        "manifest_sha256": _runtime_manifest_sha(bundle),
        "metallib_sha256": bundle["files"]["stwo_zig_core.metallib"]["sha256"],
    }
    host = collect_static(RUNTIME_MODE)
    try:
        validate_environment(host, RUNTIME_MODE)
    except ValueError as exc:
        raise CalibrationError(str(exc)) from exc
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
            report_digests, class_identity = _runtime_evidence(class_dir, commit)
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
    if runtime_identity["source_sha256"] != aot["source_sha256"]:
        raise CalibrationError("executed shader source differs from supplied AOT bundle")
    identity_payload = dict(runtime_identity)
    runtime_identity = {
        "identity_sha256": sha256(
            b"stwo-perf-metal-runtime-identity-v1\0"
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
        "aot": aot,
        "runtime_identity": runtime_identity,
        "classes": class_results,
    }
    validate_document(document, manifest)
    output = out_dir / "calibration.json"
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return output
