"""Pinned Stark-V source validation, helper overlay, and cached build policy."""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import platform
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from riscv_release_oracle_lib import build_cache


ROOT = Path(__file__).resolve().parents[2]
ADAPTER_REL = "crates/prover/src/bin/cp11_dump.rs"
ADAPTER_SOURCE_PATH = Path(__file__).resolve().parent / "cp11_dump.rs"
ADAPTER_SUMS_REL = "crates/prover/src/bin/cp11_dump/relation_sums.rs"
ADAPTER_SUMS_SOURCE_PATH = ADAPTER_SOURCE_PATH.parent / "cp11_dump" / "relation_sums.rs"
ADAPTER_TUPLES_REL = "crates/prover/src/bin/cp11_dump/relation_tuples.rs"
ADAPTER_TUPLES_SOURCE_PATH = ADAPTER_SOURCE_PATH.parent / "cp11_dump" / "relation_tuples.rs"
ADAPTER_LIMITATION_REL = "crates/prover/src/bin/cp11_dump/relation_limitation.rs"
ADAPTER_LIMITATION_SOURCE_PATH = (
    ADAPTER_SOURCE_PATH.parent / "cp11_dump" / "relation_limitation.rs"
)
ADAPTER_OVERLAYS = (
    (ADAPTER_REL, ADAPTER_SOURCE_PATH),
    (ADAPTER_SUMS_REL, ADAPTER_SUMS_SOURCE_PATH),
    (ADAPTER_TUPLES_REL, ADAPTER_TUPLES_SOURCE_PATH),
    (ADAPTER_LIMITATION_REL, ADAPTER_LIMITATION_SOURCE_PATH),
)
PROVER_MANIFEST_REL = "crates/prover/Cargo.toml"
SHA2_DEPENDENCY = 'sha2 = { version = "0.10", default-features = false }'
BUILD_IDENTITY_SCHEMA = "riscv-stark-v-oracle-build-identity-v1"
BUILD_COMMAND = (
    "cargo", "build", "--locked", "--release", "-p", "prover",
    "--bin", "cp11_dump",
)


@dataclass(frozen=True)
class BuildInputs:
    identity: dict[str, object]
    submodule_status: tuple[str, ...]
    tree_digest_sha256: str
    lockfile_sha256: str
    adapter_overlay: dict[str, object]
    rust: dict[str, object]


def _run(cmd: list[str], cwd: Path | None = None) -> str:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout


def _sha256_file(path: Path) -> str:
    return build_cache.sha256_file(path)


def _canonical_digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _tree_digest(source: Path) -> str:
    out = _run(["git", "ls-files", "-s"], cwd=source)
    return hashlib.sha256(out.encode()).hexdigest()


def _promote_locked_sha2_dependency(original: bytes) -> tuple[bytes, dict[str, str]]:
    """Temporarily expose the pinned manifest's already-locked SHA-256 crate."""
    try:
        text = original.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SystemExit("pinned prover manifest is not UTF-8") from error
    lines = text.splitlines(keepends=True)
    logical = [line.rstrip("\r\n") for line in lines]
    if logical.count("[dependencies]") != 1 or logical.count("[dev-dependencies]") != 1:
        raise SystemExit("pinned prover manifest has unexpected dependency sections")
    if logical.count(SHA2_DEPENDENCY) != 1:
        raise SystemExit("pinned prover manifest has unexpected sha2 dependency shape")
    dependencies_index = logical.index("[dependencies]")
    dev_dependencies_index = logical.index("[dev-dependencies]")
    sha2_index = logical.index(SHA2_DEPENDENCY)
    next_section_index = next(
        (
            index
            for index in range(dev_dependencies_index + 1, len(logical))
            if logical[index].startswith("[") and logical[index].endswith("]")
        ),
        len(logical),
    )
    if not dependencies_index < dev_dependencies_index < sha2_index < next_section_index:
        raise SystemExit("pinned sha2 dependency is not in [dev-dependencies]")

    sha2_line = lines.pop(sha2_index)
    lines.insert(dependencies_index + 1, sha2_line)
    transformed = "".join(lines).encode("utf-8")
    before_sha256 = hashlib.sha256(original).hexdigest()
    after_sha256 = hashlib.sha256(transformed).hexdigest()
    patch_record = {
        "operation": "promote_locked_dev_dependency",
        "path": PROVER_MANIFEST_REL,
        "dependency": SHA2_DEPENDENCY,
        "before_sha256": before_sha256,
        "after_sha256": after_sha256,
    }
    return transformed, {
        **patch_record,
        "sha256": after_sha256,
        "patch_sha256": _canonical_digest(patch_record),
    }


@contextlib.contextmanager
def _temporary_sha2_dependency(source: Path):
    manifest = source / PROVER_MANIFEST_REL
    original = manifest.read_bytes()
    transformed, evidence = _promote_locked_sha2_dependency(original)
    try:
        manifest.write_bytes(transformed)
        yield evidence
    finally:
        manifest.write_bytes(original)


def _normalized_submodules(raw_status: str) -> list[dict[str, str]]:
    submodules: list[dict[str, str]] = []
    for line in raw_status.splitlines():
        fields = line[1:].split()
        if not line.startswith(" ") or len(fields) < 2:
            raise SystemExit(
                "oracle submodules are not initialized at the recorded commits: " + line
            )
        commit, path = fields[:2]
        if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
            raise SystemExit(f"oracle submodule has invalid commit identity: {line}")
        if any(item["path"] == path for item in submodules):
            raise SystemExit(f"oracle submodule path is duplicated: {path}")
        submodules.append({"path": path, "commit": commit})
    return submodules


def _resolved_rust_build(source: Path) -> dict[str, object]:
    toolchain_file = source / "rust-toolchain.toml"
    if toolchain_file.is_symlink() or not toolchain_file.is_file():
        raise SystemExit("pinned Stark-V rust-toolchain.toml is missing or non-regular")
    rustc = _run(["rustc", "--version", "--verbose"], cwd=source).strip()
    cargo = _run(["cargo", "--version", "--verbose"], cwd=source).strip()
    host_lines = [
        line.removeprefix("host: ")
        for line in rustc.splitlines()
        if line.startswith("host: ")
    ]
    if len(host_lines) != 1 or not host_lines[0]:
        raise SystemExit("resolved rustc identity has no unique host target")
    cargo_config = _run(
        ["cargo", "-Z", "unstable-options", "config", "get", "--format", "json"],
        cwd=source,
    )
    try:
        config_value = json.loads(cargo_config)
        config_target = config_value.get("build", {}).get("target")
    except (AttributeError, json.JSONDecodeError) as error:
        raise SystemExit("effective Cargo configuration is not a JSON object") from error
    if config_target is not None and not isinstance(config_target, str):
        raise SystemExit("effective Cargo build.target is not a single target triple")
    configured_target = os.environ.get("CARGO_BUILD_TARGET") or config_target
    target = configured_target or host_lines[0]
    target_layout = "explicit" if configured_target else "host_default"
    if re.fullmatch(r"[A-Za-z0-9_.-]+", target) is None:
        raise SystemExit(f"invalid Rust build target: {target!r}")
    environment_names = (
        "CARGO_BUILD_TARGET",
        "RUSTFLAGS",
        "CARGO_ENCODED_RUSTFLAGS",
        "RUSTC",
        "RUSTC_WRAPPER",
        "RUSTC_WORKSPACE_WRAPPER",
        "CC",
        "CFLAGS",
        "CXXFLAGS",
        "LDFLAGS",
        "MACOSX_DEPLOYMENT_TARGET",
    )
    return {
        "rustc_verbose": rustc,
        "cargo_verbose": cargo,
        "rust_toolchain_sha256": _sha256_file(toolchain_file),
        "target": target,
        "target_layout": target_layout,
        "cargo_config_sha256": hashlib.sha256(cargo_config.encode()).hexdigest(),
        "build_environment": {
            name: os.environ[name] for name in environment_names if name in os.environ
        },
    }


def _adapter_overlay_evidence(source: Path) -> dict[str, object]:
    manifest = source / PROVER_MANIFEST_REL
    _transformed, manifest_evidence = _promote_locked_sha2_dependency(manifest.read_bytes())
    overlay_files: list[dict[str, str]] = [manifest_evidence]
    for relative_path, source_path in ADAPTER_OVERLAYS:
        overlay_files.append({"path": relative_path, "sha256": _sha256_file(source_path)})
    return {
        "path": ADAPTER_REL,
        "sha256": _canonical_digest(overlay_files),
        "files": overlay_files,
        "note": "aggregate identity of thin serializers over the oracle's "
        "own production APIs and a recorded, temporary manifest transform; "
        "applied after tree digest, removed after build",
    }


def resolve_build_inputs(source: Path, pinned_commit: str) -> BuildInputs:
    """Resolve the one identity used by pre-restore and inner cache lookup."""
    head = _run(["git", "rev-parse", "HEAD"], cwd=source).strip()
    if head != pinned_commit:
        raise SystemExit(f"oracle checkout at {head}, pinned {pinned_commit}")
    dirty = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=source,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if dirty:
        raise SystemExit("oracle checkout is not clean; refusing to build")
    submodule = _run(["git", "submodule", "status", "--recursive"], cwd=source)
    normalized_submodules = _normalized_submodules(submodule)
    tree_digest = _tree_digest(source)
    lockfile_sha256 = _sha256_file(source / "Cargo.lock")
    overlay_evidence = _adapter_overlay_evidence(source)
    rust_build = _resolved_rust_build(source)
    identity: dict[str, object] = {
        "schema": BUILD_IDENTITY_SCHEMA,
        "oracle": {
            "repository": "https://github.com/ClementWalter/stark-v",
            "commit": head,
            "tree_digest_sha256": tree_digest,
            "submodules": normalized_submodules,
            "lockfile_sha256": lockfile_sha256,
        },
        "adapter_overlay_sha256": overlay_evidence["sha256"],
        "rust": rust_build,
        "build_command": list(BUILD_COMMAND),
        "platform": {"machine": platform.machine(), "system": platform.system()},
    }
    return BuildInputs(
        identity=identity,
        submodule_status=tuple(submodule.strip().splitlines()),
        tree_digest_sha256=tree_digest,
        lockfile_sha256=lockfile_sha256,
        adapter_overlay=overlay_evidence,
        rust=rust_build,
    )


def build_oracle(
    source: Path,
    receipt: dict,
    pinned_commit: str,
    cache_dir: Path | None = None,
) -> Path:
    inputs = resolve_build_inputs(source, pinned_commit)
    identity = inputs.identity
    rust_build = inputs.rust
    target = str(rust_build["target"])
    build_cmd = list(BUILD_COMMAND)
    selected_cache_dir = cache_dir or build_cache.default_cache_dir()
    cached = build_cache.load(selected_cache_dir, identity)
    cache_status = "hit"
    if cached is None:
        cache_status = "miss"
        print(
            "Rust oracle cache miss: building pinned cp11_dump "
            f"({build_cache.cache_key(identity)[:12]})"
        )
        build_started = time.monotonic()
        overlay_paths: list[Path] = []
        with _temporary_sha2_dependency(source) as applied_manifest_evidence:
            if applied_manifest_evidence != inputs.adapter_overlay["files"][0]:
                raise SystemExit("oracle manifest transform changed after cache identity")
            try:
                for relative_path, source_path in ADAPTER_OVERLAYS:
                    destination = source / relative_path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(source_path.read_bytes())
                    overlay_paths.append(destination)
                _run(build_cmd, cwd=source)
                target_root = source / "target"
                if rust_build["target_layout"] == "explicit":
                    target_root /= target
                built_executable = target_root / "release" / "cp11_dump"
                cached = build_cache.store(selected_cache_dir, identity, built_executable)
            finally:
                for overlay_path in reversed(overlay_paths):
                    overlay_path.unlink(missing_ok=True)
                try:
                    (source / ADAPTER_REL).parent.rmdir()
                except OSError:
                    pass
        print(f"Rust oracle build cached in {time.monotonic() - build_started:.3f}s")
    else:
        print(f"Rust oracle cache hit: {cached.key_sha256[:12]}")

    if cached.executable_sha256 != _sha256_file(cached.executable):
        raise SystemExit("Rust oracle cache executable changed after validation")
    receipt["oracle"] = {
        "repository": "https://github.com/ClementWalter/stark-v",
        "commit": pinned_commit,
        "clean": True,
        "tree_digest_sha256": inputs.tree_digest_sha256,
        "submodule_status": list(inputs.submodule_status),
        "lockfile_sha256": inputs.lockfile_sha256,
        "toolchain": str(rust_build["rustc_verbose"]).splitlines()[0],
        "build_command": " ".join(build_cmd),
        "build_mode": "release",
        "adapter_overlay": inputs.adapter_overlay,
        "executable_sha256": cached.executable_sha256,
        "host_arch": platform.machine(),
        "host_os": f"{platform.system()} {platform.release()}",
        "build_cache": {
            "schema": build_cache.CACHE_SCHEMA,
            "status": cache_status,
            "key_sha256": cached.key_sha256,
            "manifest_sha256": cached.manifest_sha256,
            "verification": [
                "identity_exact", "manifest_strict", "regular_executable",
                "size_exact", "executable_sha256_exact",
            ],
        },
    }
    return cached.executable
