"""Metal calibration artifact, freeze, and activation contract.

Calibration is deliberately separate from ordinary promotion measurement.  A
reviewed freeze binds an epoch to one complete M5/AOT run; judged Metal scoring
then fails closed if either policy file or the immutable artifact drifts.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import subprocess
from pathlib import Path

from .manifest import Manifest


SCHEMA = "stwo_perf_metal_calibration_v1"
FREEZE_SCHEMA = "stwo_perf_metal_calibration_freeze_v1"
BOARD = "core_metal"
RUNTIME_MODE = "source-jit"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
ANCHOR_FIELDS = (
    "prove_ms", "request_ms", "peak_rss_mib", "energy_j", "proof_bytes",
)


class CalibrationError(RuntimeError):
    pass


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    ).encode("ascii")


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    try:
        return sha256(path.read_bytes())
    except OSError as exc:
        raise CalibrationError(f"cannot read calibration artifact {path}: {exc}") from exc


def policy_document(manifest: Manifest) -> dict:
    """Subset that defines what a Metal class calibration actually measured."""
    config = manifest.raw["harness"]["metal_calibration"]
    group = manifest.group("metal")
    return {
        "schema": "stwo_perf_metal_calibration_policy_v1",
        "board": BOARD,
        "runtime_mode": config["runtime_mode"],
        "designated_host": config["designated_host"],
        "classes": manifest.raw["workload_registry"]["classes"],
        "group": manifest.raw["workload_registry"]["groups"][group.group_id],
        "statistics": {
            "ci_level": manifest.gates["ci_level"],
            "dispersion_multiplier": manifest.gates["dispersion_multiplier"],
        },
    }


def policy_sha256(manifest: Manifest) -> str:
    return sha256(b"stwo-perf-metal-calibration-policy-v1\0" + _canonical(
        policy_document(manifest)
    ))


def _positive(value: object, field: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or float(value) <= 0
    ):
        raise CalibrationError(f"{field} must be a positive finite number")
    return float(value)


def _digest(value: object, field: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise CalibrationError(f"{field} must be lowercase SHA-256 hex")
    return value


def _exact_keys(value: object, expected: set[str], field: str) -> dict:
    if not isinstance(value, dict) or set(value) != expected:
        actual = set(value) if isinstance(value, dict) else set()
        raise CalibrationError(
            f"{field} fields differ: missing={sorted(expected - actual)}, "
            f"unknown={sorted(actual - expected)}"
        )
    return value


def _validate_host(host: object, manifest: Manifest) -> dict:
    value = _exact_keys(host, {
        "schema", "platform", "hardware", "metal_device", "toolchain",
        "randomness", "complete", "blockers",
    }, "host")
    if value["complete"] is not True or value["blockers"] != []:
        raise CalibrationError("host provenance is incomplete")
    expected = manifest.raw["harness"]["metal_calibration"]["designated_host"]
    hardware = value.get("hardware")
    if not isinstance(hardware, dict):
        raise CalibrationError("host.hardware is missing")
    if hardware.get("chip") != expected["chip"]:
        raise CalibrationError("calibration did not run on the designated chip")
    if hardware.get("logical_cpu_count") != expected["logical_cpu_count"]:
        raise CalibrationError("calibration logical CPU count differs from policy")
    metal = value.get("metal_device")
    if not isinstance(metal, dict) or not metal.get("name") or not metal.get("metal_family"):
        raise CalibrationError("calibration Metal device identity is incomplete")
    return value


def validate_document(document: object, manifest: Manifest) -> dict:
    doc = _exact_keys(document, {
        "schema", "board", "epoch", "repository", "policy_sha256",
        "runtime_mode", "host", "aot", "runtime_identity", "classes",
    }, "calibration")
    if doc["schema"] != SCHEMA or doc["board"] != BOARD:
        raise CalibrationError("calibration schema or board mismatch")
    if type(doc["epoch"]) is not int or doc["epoch"] <= 0:
        raise CalibrationError("calibration epoch must be a positive integer")
    if doc["runtime_mode"] != RUNTIME_MODE:
        raise CalibrationError("calibration must execute the production source-JIT runtime")
    expected_policy = policy_sha256(manifest)
    if _digest(doc["policy_sha256"], "policy_sha256") != expected_policy:
        raise CalibrationError("calibration policy is stale")
    repository = _exact_keys(
        doc["repository"], {"commit", "tree", "dirty"}, "repository"
    )
    if (
        not isinstance(repository["commit"], str)
        or COMMIT_RE.fullmatch(repository["commit"]) is None
        or not isinstance(repository["tree"], str)
        or COMMIT_RE.fullmatch(repository["tree"]) is None
        or repository["dirty"] is not False
    ):
        raise CalibrationError("calibration requires an exact clean commit and tree")
    _validate_host(doc["host"], manifest)
    aot = _exact_keys(
        doc["aot"],
        {"format", "bundle_identity_sha256", "source_sha256",
         "manifest_sha256", "metallib_sha256"},
        "aot",
    )
    if aot["format"] != "stwo-zig-metal-core-aot-v2":
        raise CalibrationError("AOT format mismatch")
    for field in aot:
        if field != "format":
            _digest(aot[field], f"aot.{field}")
    runtime = _exact_keys(
        doc["runtime_identity"],
        {"identity_sha256", "runtime_manifest", "runtime_manifest_sha256",
         "aot_manifest", "aot_manifest_sha256", "source_sha256",
         "platform_identity", "platform_identity_sha256"},
        "runtime_identity",
    )
    for field in (
        "identity_sha256", "runtime_manifest_sha256", "aot_manifest_sha256",
        "source_sha256", "platform_identity_sha256",
    ):
        _digest(runtime[field], f"runtime_identity.{field}")
    for field in ("runtime_manifest", "aot_manifest", "platform_identity"):
        if not isinstance(runtime[field], str) or not runtime[field]:
            raise CalibrationError(f"runtime_identity.{field} must be non-empty")
    if "mode=source-jit" not in runtime["runtime_manifest"]:
        raise CalibrationError("runtime manifest does not select source-JIT")
    if runtime["aot_manifest"] != "none":
        raise CalibrationError("source-JIT product identity unexpectedly names an AOT bundle")
    for field in ("runtime_manifest", "aot_manifest", "platform_identity"):
        if runtime[f"{field}_sha256"] != sha256(runtime[field].encode("utf-8")):
            raise CalibrationError(f"runtime_identity.{field}_sha256 is inconsistent")
    identity_payload = {
        field: value for field, value in runtime.items() if field != "identity_sha256"
    }
    expected_identity = sha256(
        b"stwo-perf-metal-runtime-identity-v1\0" + _canonical(identity_payload)
    )
    if runtime["identity_sha256"] != expected_identity:
        raise CalibrationError("runtime_identity.identity_sha256 is inconsistent")
    if runtime["source_sha256"] != aot["source_sha256"]:
        raise CalibrationError("runtime shader source disagrees with the AOT source")

    expected_classes = manifest.class_names(
        board=BOARD, scored_only=True, include_disabled=True,
    )
    classes = doc["classes"]
    if not isinstance(classes, dict) or set(classes) != set(expected_classes):
        raise CalibrationError("calibration class set differs from the manifest")
    for name in expected_classes:
        raw = classes[name]
        item = _exact_keys(raw, {
            "classification", "aa_r", "ci", "dispersion", "anchor",
            "measurement_rounds", "measurement_seconds", "report_sha256s",
        }, f"classes.{name}")
        if item["classification"] != "neutral":
            raise CalibrationError(f"classes.{name} is not a neutral A/A result")
        _positive(item["aa_r"], f"classes.{name}.aa_r")
        ci = item["ci"]
        if (
            not isinstance(ci, list) or len(ci) != 2
            or _positive(ci[0], f"classes.{name}.ci[0]") > 1.0
            or _positive(ci[1], f"classes.{name}.ci[1]") < 1.0
        ):
            raise CalibrationError(f"classes.{name} A/A CI does not contain 1")
        _positive(item["dispersion"], f"classes.{name}.dispersion")
        anchor = _exact_keys(item["anchor"], set(ANCHOR_FIELDS), f"classes.{name}.anchor")
        for field in ANCHOR_FIELDS:
            _positive(anchor[field], f"classes.{name}.anchor.{field}")
        if type(item["measurement_rounds"]) is not int or item["measurement_rounds"] < 3:
            raise CalibrationError(f"classes.{name}.measurement_rounds must be >= 3")
        _positive(item["measurement_seconds"], f"classes.{name}.measurement_seconds")
        reports = item["report_sha256s"]
        if not isinstance(reports, list) or not reports or len(reports) != len(set(reports)):
            raise CalibrationError(f"classes.{name}.report_sha256s must be unique and non-empty")
        for index, digest in enumerate(reports):
            _digest(digest, f"classes.{name}.report_sha256s[{index}]")
    return doc


def _load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CalibrationError(f"cannot load calibration JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CalibrationError(f"calibration JSON root is not an object: {path}")
    return value


def _current_epoch(root: Path) -> tuple[Path, dict, dict]:
    path = root / "autoresearch/ledger/epochs.json"
    document = _load_json(path)
    epochs = document.get("epochs")
    if not isinstance(epochs, list) or not epochs:
        raise CalibrationError("epochs.json has no epochs")
    epoch = max(epochs, key=lambda item: item.get("epoch", 0))
    return path, document, epoch


def _frozen_state(manifest: Manifest) -> tuple[dict, dict]:
    config = manifest.raw["harness"]["metal_calibration"]
    _, _, epoch = _current_epoch(manifest.root)
    state = epoch.get("metal_calibration")
    if not isinstance(state, dict):
        raise CalibrationError("current epoch has no Metal calibration freeze")
    return config, state


def require_frozen(manifest: Manifest, workload_class: str | None = None) -> dict:
    """Validate both policy files and the immutable artifact, with no null fallback."""
    config, state = _frozen_state(manifest)
    for label, value in (("manifest", config), ("epoch", state)):
        if value.get("status") != "frozen":
            raise CalibrationError(f"{label} Metal calibration is not frozen")
        for field in (
            "artifact_sha256", "measured_commit", "policy_sha256",
            "runtime_identity_sha256", "aot_manifest_sha256", "aot_metallib_sha256",
        ):
            if value.get(field) is None:
                raise CalibrationError(f"{label} Metal calibration has null {field}")
    shared = (
        "schema", "status", "board", "epoch", "artifact", "artifact_sha256",
        "measured_commit", "policy_sha256", "runtime_identity_sha256",
        "aot_manifest_sha256", "aot_metallib_sha256",
    )
    for field in shared:
        if config.get(field) != state.get(field):
            raise CalibrationError(f"manifest/epoch Metal calibration mismatch: {field}")
    if config["schema"] != FREEZE_SCHEMA or config["board"] != BOARD:
        raise CalibrationError("Metal calibration freeze schema or board mismatch")
    if config["policy_sha256"] != policy_sha256(manifest):
        raise CalibrationError("frozen Metal calibration policy is stale")
    artifact_path = manifest.root / config["artifact"]
    actual_sha = file_sha256(artifact_path)
    if actual_sha != config["artifact_sha256"]:
        raise CalibrationError("frozen Metal calibration artifact digest mismatch")
    artifact = validate_document(_load_json(artifact_path), manifest)
    if artifact["epoch"] != config["epoch"]:
        raise CalibrationError("artifact epoch differs from its freeze")
    if artifact["repository"]["commit"] != config["measured_commit"]:
        raise CalibrationError("artifact commit differs from its freeze")
    if artifact["runtime_identity"]["identity_sha256"] != config["runtime_identity_sha256"]:
        raise CalibrationError("artifact runtime identity differs from its freeze")
    if artifact["aot"]["manifest_sha256"] != config["aot_manifest_sha256"]:
        raise CalibrationError("artifact AOT manifest differs from its freeze")
    if artifact["aot"]["metallib_sha256"] != config["aot_metallib_sha256"]:
        raise CalibrationError("artifact metallib differs from its freeze")
    try:
        subprocess.run(
            ["git", "merge-base", "--is-ancestor", config["measured_commit"], "HEAD"],
            cwd=manifest.root, check=True, capture_output=True,
        )
        measured_tree = subprocess.run(
            ["git", "rev-parse", f"{config['measured_commit']}^{{tree}}"],
            cwd=manifest.root, check=True, capture_output=True, text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as exc:
        raise CalibrationError("calibration commit is stale or absent from HEAD history") from exc
    if measured_tree != artifact["repository"]["tree"]:
        raise CalibrationError("calibration artifact tree differs from its commit")

    names = [workload_class] if workload_class else list(artifact["classes"])
    epoch_dispersion = state.get("aa_dispersion")
    anchors = state.get("anchors")
    if not isinstance(epoch_dispersion, dict) or not isinstance(anchors, dict):
        raise CalibrationError("epoch Metal calibration lacks dispersion or anchors")
    harness = manifest.raw["harness"]
    for name in names:
        if name not in artifact["classes"]:
            raise CalibrationError(f"class {name} is absent from Metal calibration")
        measured = artifact["classes"][name]
        if epoch_dispersion.get(name) != measured["dispersion"]:
            raise CalibrationError(f"class {name} dispersion differs from artifact")
        if anchors.get(name) != measured["anchor"]:
            raise CalibrationError(f"class {name} epoch anchor differs from artifact")
        if harness["anchor_prove_ms"][BOARD].get(name) != measured["anchor"]["prove_ms"]:
            raise CalibrationError(f"class {name} prove anchor differs from artifact")
        if harness["anchor_request_ms"][BOARD].get(name) != measured["anchor"]["request_ms"]:
            raise CalibrationError(f"class {name} request anchor differs from artifact")
        resources = harness["anchor_resources"][BOARD].get(name)
        expected = {
            key: measured["anchor"][key]
            for key in ("peak_rss_mib", "energy_j", "proof_bytes")
        }
        if resources != expected:
            raise CalibrationError(f"class {name} resource anchor differs from artifact")
        epoch_value = _current_epoch(manifest.root)[2]["aa_dispersion"][BOARD].get(name)
        if epoch_value != measured["dispersion"]:
            raise CalibrationError(f"class {name} epoch A/A dispersion differs from artifact")
    return artifact


def freeze(manifest: Manifest, source: Path) -> Path:
    """Stage one validated report and both policy updates as one reviewed change."""
    artifact = validate_document(_load_json(source), manifest)
    config = manifest.raw["harness"]["metal_calibration"]
    if config["status"] != "pending":
        raise CalibrationError("the current epoch already has a frozen calibration")
    _, epochs_doc, epoch = _current_epoch(manifest.root)
    if artifact["epoch"] != epoch["epoch"] or config["epoch"] != epoch["epoch"]:
        raise CalibrationError("calibration report does not target the current epoch")
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=manifest.root, check=True,
        capture_output=True, text=True,
    ).stdout.strip()
    if artifact["repository"]["commit"] != head:
        raise CalibrationError("freeze requires the exact measured commit at HEAD")
    head_tree = subprocess.run(
        ["git", "rev-parse", "HEAD^{tree}"], cwd=manifest.root, check=True,
        capture_output=True, text=True,
    ).stdout.strip()
    if artifact["repository"]["tree"] != head_tree:
        raise CalibrationError("freeze report tree differs from the measured HEAD")
    if subprocess.run(
        ["git", "status", "--porcelain"], cwd=manifest.root, check=True,
        capture_output=True, text=True,
    ).stdout:
        raise CalibrationError("freeze requires a clean tree")

    destination = manifest.root / config["artifact"]
    if destination.exists():
        raise CalibrationError("calibration artifact path already exists")
    encoded = _canonical(artifact) + b"\n"
    artifact_sha = sha256(encoded)
    freeze_fields = {
        "schema": FREEZE_SCHEMA,
        "status": "frozen",
        "board": BOARD,
        "epoch": artifact["epoch"],
        "artifact": config["artifact"],
        "artifact_sha256": artifact_sha,
        "measured_commit": artifact["repository"]["commit"],
        "policy_sha256": artifact["policy_sha256"],
        "runtime_identity_sha256": artifact["runtime_identity"]["identity_sha256"],
        "aot_manifest_sha256": artifact["aot"]["manifest_sha256"],
        "aot_metallib_sha256": artifact["aot"]["metallib_sha256"],
    }
    config.clear()
    config.update({
        **freeze_fields,
        "runtime_mode": RUNTIME_MODE,
        "designated_host": {
            "chip": artifact["host"]["hardware"]["chip"],
            "logical_cpu_count": artifact["host"]["hardware"]["logical_cpu_count"],
        },
    })
    epoch["metal_calibration"] = {
        **freeze_fields,
        "aa_dispersion": {
            name: value["dispersion"] for name, value in artifact["classes"].items()
        },
        "anchors": {
            name: value["anchor"] for name, value in artifact["classes"].items()
        },
    }
    for name, value in artifact["classes"].items():
        anchor = value["anchor"]
        epoch["aa_dispersion"][BOARD][name] = value["dispersion"]
        manifest.raw["harness"]["anchor_prove_ms"][BOARD][name] = anchor["prove_ms"]
        manifest.raw["harness"]["anchor_request_ms"][BOARD][name] = anchor["request_ms"]
        manifest.raw["harness"]["anchor_resources"][BOARD][name] = {
            key: anchor[key] for key in ("peak_rss_mib", "energy_j", "proof_bytes")
        }

    destination.parent.mkdir(parents=True, exist_ok=True)
    outputs = (
        (destination, encoded),
        (manifest.root / "autoresearch/MANIFEST.json",
         (json.dumps(manifest.raw, indent=2) + "\n").encode()),
        (manifest.root / "autoresearch/ledger/epochs.json",
         (json.dumps(epochs_doc, indent=2) + "\n").encode()),
    )
    staged = []
    for path, data in outputs:
        temporary = path.with_name(f".{path.name}.tmp")
        temporary.write_bytes(data)
        staged.append((temporary, path))
    for temporary, path in staged:
        temporary.replace(path)
    return destination
