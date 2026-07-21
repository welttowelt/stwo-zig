#!/usr/bin/env python3
"""Create one immutable same-host peer-relative wide-Fibonacci audit point."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "peer-relative-wide-fibonacci-series-point-v1"
SERIES_ID = "clementwalter-pr6-wide-fibonacci-v1"
PEER_REPOSITORY = "https://github.com/ClementWalter/stwo"
PEER_COMMIT = "07ea1ccca13351028da94e66babf79e7ce91437f"
RUST_TOOLCHAIN = "nightly-2025-07-14"
LOG_SIZES = (14, 16, 18, 20)
N_COLUMNS = 100
LANES = ("peer_cpu", "peer_metal", "zig_cpu", "zig_metal")
LARGE_LOG_SIZES = (18, 20)
LARGE_RESOURCE_ARGS = ("--resource-profile", "large")


class SeriesError(RuntimeError):
    pass


def run(cmd: list[str], cwd: Path, timeout: float = 3600) -> tuple[str, float]:
    started = time.perf_counter()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    wall_ms = (time.perf_counter() - started) * 1000.0
    if proc.returncode != 0:
        rendered = " ".join(cmd[:6])
        raise SeriesError(f"{rendered} failed:\n{proc.stderr[-1600:]}\n{proc.stdout[-800:]}")
    return proc.stdout, wall_ms


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def host_identity() -> dict:
    processor = platform.processor() or "unknown cpu"
    if platform.system() == "Darwin":
        try:
            processor = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError:
            pass
    return {
        "platform": platform.platform(),
        "system": platform.system(),
        "machine": platform.machine(),
        "processor": processor,
        "logical_cpu_count": os.cpu_count(),
    }


def interleave_order(log_index: int, round_index: int) -> list[str]:
    """Balanced rotation: over four rounds every lane occupies every position."""
    offset = (log_index + round_index) % len(LANES)
    return list(LANES[offset:] + LANES[:offset])


def _git(repo: Path, *args: str) -> str:
    stdout, _ = run(["git", *args], repo)
    return stdout.strip()


def assert_clean_checkout(repo: Path, allow_dirty: bool) -> str:
    commit = _git(repo, "rev-parse", "HEAD")
    dirty = _git(repo, "status", "--porcelain", "--untracked-files=no")
    if dirty and not allow_dirty:
        raise SeriesError("peer series requires a clean committed stwo-zig checkout")
    return commit


def assert_large_resource_profile(repo: Path, zig_cpu: Path) -> None:
    proc = subprocess.run(
        [str(zig_cpu), "--help"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    help_text = proc.stdout + proc.stderr
    if proc.returncode != 0 or "--resource-profile" not in help_text:
        raise SeriesError(
            "stwo-zig audit commit lacks the required '--resource-profile large' "
            "admission for the log-18/log-20 x 100 lanes; integrate Issue #44 W1 "
            "before calibration"
        )


def _cargo_build(
    repo: Path,
    target_dir: Path,
    *,
    metal: bool,
) -> tuple[Path, list[str]]:
    command = [
        "cargo",
        f"+{RUST_TOOLCHAIN}",
        "build",
        "--release",
        "--locked",
        "--manifest-path",
        "tools/current-stwo-fib-bench/Cargo.toml",
        "--target-dir",
        str(target_dir),
    ]
    if metal:
        command.extend(["--features", "metal"])
    run(command, repo)
    binary = target_dir / "release/peer-stwo-fib-bench"
    if not binary.is_file():
        raise SeriesError(f"peer adapter build did not create {binary}")
    return binary, command


def prepare_binaries(repo: Path, build_root: Path) -> tuple[dict, dict]:
    peer_cpu, peer_cpu_build = _cargo_build(repo, build_root / "peer-cpu", metal=False)
    peer_metal, peer_metal_build = _cargo_build(repo, build_root / "peer-metal", metal=True)
    zig_cpu_build = ["zig", "build", "native-proof-bench-cpu", "-Doptimize=ReleaseFast"]
    zig_metal_build = ["zig", "build", "native-proof-bench-metal", "-Doptimize=ReleaseFast"]
    run(zig_cpu_build, repo)
    run(zig_metal_build, repo)
    binaries = {
        "peer_cpu": peer_cpu,
        "peer_metal": peer_metal,
        "zig_cpu": repo / "zig-out/bin/native-proof-bench-cpu",
        "zig_metal": repo / "zig-out/bin/native-proof-bench-metal",
    }
    for lane, binary in binaries.items():
        if not binary.is_file():
            raise SeriesError(f"missing {lane} binary: {binary}")
    builds = {
        "peer_cpu": peer_cpu_build,
        "peer_metal": peer_metal_build,
        "zig_cpu": zig_cpu_build,
        "zig_metal": zig_metal_build,
    }
    return binaries, builds


def _one_peer(
    repo: Path,
    binary: Path,
    lane: str,
    log_size: int,
    warmups: int,
    scratch: Path,
) -> dict:
    output = scratch / f"{lane}-log{log_size}.json"
    stdout, wall_ms = run([
        str(binary), lane.replace("_", "-"), str(log_size), str(warmups), "1", str(output)
    ], repo)
    if stdout.strip():
        raise SeriesError(f"{lane} wrote unexpected stdout")
    report = json.loads(output.read_text())
    expected_backend = lane.replace("_", "-")
    if report.get("schema") != "peer-stwo-wide-fibonacci-adapter-v1":
        raise SeriesError(f"{lane} adapter schema mismatch")
    if report.get("peer_source_commit") != PEER_COMMIT:
        raise SeriesError(f"{lane} source commit mismatch")
    if report.get("backend") != expected_backend:
        raise SeriesError(f"{lane} backend mismatch")
    if report.get("backend_type") != "stwo::prover::backend::cpu::CpuBackend":
        raise SeriesError(f"{lane} backend type mismatch")
    if report.get("n_columns") != N_COLUMNS or report.get("log_n_instances") != log_size:
        raise SeriesError(f"{lane} workload mismatch")
    if not report.get("all_verified") or not report.get("all_proofs_identical"):
        raise SeriesError(f"{lane} proof receipt failed")
    features = set(report.get("cargo_features", []))
    if lane == "peer_metal" and "metal" not in features:
        raise SeriesError("peer_metal did not compile the metal feature")
    if lane == "peer_cpu" and "metal" in features:
        raise SeriesError("peer_cpu unexpectedly compiled the metal feature")
    if lane == "peer_metal" and report.get("metal_device_admitted") is not True:
        raise SeriesError("peer_metal did not admit a real unified-memory Metal device")
    if lane == "peer_cpu" and report.get("metal_device_admitted") is not False:
        raise SeriesError("peer_cpu unexpectedly reports Metal device admission")
    protocol = {
        "channel": "Blake2sM31Channel/Blake2sM31MerkleChannel",
        "pcs_config": "PcsConfig::default()",
        "security_bits": report.get("security_bits"),
        "fri_queries": report.get("fri_queries"),
        "pow_bits": report.get("pow_bits"),
        "commitments": report.get("commitments"),
        "proof_size_bytes": report.get("proof_size_bytes"),
    }
    if not all(isinstance(value, int) and value >= 0 for value in list(protocol.values())[2:]):
        raise SeriesError(f"{lane} omitted concrete peer protocol parameters")
    return {
        "lane": lane,
        "reported_prove_ms": report["prove_samples_ms"][0],
        "verified_request_ms": report["total_samples_ms"][0],
        "process_wall_ms": wall_ms,
        "proof_identity": {
            "scheme": "sha256(debug(StarkProof))",
            "digest": report["proof_debug_sha256"],
            "bytes_hashed": report["proof_debug_bytes"],
        },
        "verified": True,
        "timing_scope": report["timing_scope"],
        "metal_device_admitted": report["metal_device_admitted"],
        "trace_generation_backend": report["trace_generation_backend"],
        "protocol": protocol,
        "raw_report_sha256": sha256_file(output),
    }


def _one_zig(
    repo: Path,
    binary: Path,
    lane: str,
    log_size: int,
    warmups: int,
) -> dict:
    command = [
        str(binary),
        "--example", "wide_fibonacci",
        "--log-n-rows", str(log_size),
        "--sequence-len", str(N_COLUMNS),
        "--protocol", "functional",
        "--warmups", str(warmups),
        "--samples", "1",
    ]
    if log_size in LARGE_LOG_SIZES:
        command.extend(LARGE_RESOURCE_ARGS)
    stdout, wall_ms = run(command, repo)
    report = json.loads(stdout)
    workload = report.get("workload", {})
    parameters = workload.get("parameters", {})
    if workload.get("name") != "wide_fibonacci":
        raise SeriesError(f"{lane} workload name mismatch")
    if parameters != {"log_n_rows": log_size, "sequence_len": N_COLUMNS}:
        raise SeriesError(f"{lane} workload parameters mismatch")
    if report.get("protocol", {}).get("name") != "functional":
        raise SeriesError(f"{lane} protocol mismatch")
    proof = report.get("proof", {})
    if proof.get("verified_samples") != 1 or not proof.get("all_samples_byte_identical"):
        raise SeriesError(f"{lane} proof receipt failed")
    if lane == "zig_metal":
        telemetry = report.get("backend_telemetry") or {}
        if telemetry.get("total_cpu_fallbacks") != 0 or not telemetry.get("valid"):
            raise SeriesError("zig_metal did not provide zero-fallback valid telemetry")
    sample = report["timing"]["samples"][0]
    return {
        "lane": lane,
        "reported_prove_ms": sample["prove_seconds"] * 1000.0,
        "verified_request_ms": sample["request_seconds"] * 1000.0,
        "process_wall_ms": wall_ms,
        "proof_identity": {
            "scheme": "sha256(canonical-proof-wire)",
            "digest": proof["samples"][0]["sha256"],
            "bytes_hashed": proof["samples"][0]["bytes"],
        },
        "verified": True,
        "timing_scope": {
            "prove": "prepared-input handoff through proof construction",
            "verify": "independent verifier; excluded from reported_prove_ms",
            "total": "input preparation + prove + canonical encode + independent verify",
            "exclusions": "backend/session initialization and process startup",
        },
        "resource_profile": "large" if log_size in LARGE_LOG_SIZES else "default",
        "backend_telemetry": report.get("backend_telemetry"),
    }


def _median(samples: list[dict], lane: str, metric: str) -> float:
    return statistics.median(item[metric] for item in samples if item["lane"] == lane)


def _proof_receipt(log_size: int, samples: list[dict]) -> dict:
    digests = {
        lane: sorted({
            item["proof_identity"]["digest"] for item in samples if item["lane"] == lane
        })
        for lane in LANES
    }
    stable = all(len(values) == 1 for values in digests.values())
    peer_equal = digests["peer_cpu"] == digests["peer_metal"]
    zig_equal = digests["zig_cpu"] == digests["zig_metal"]
    if not stable or not peer_equal or not zig_equal:
        raise SeriesError(f"proof equivalence failed at log {log_size}: {digests}")
    return {
        "log_n_rows": log_size,
        "all_samples_stable": stable,
        "peer_cpu_equals_peer_metal": peer_equal,
        "zig_cpu_equals_zig_metal": zig_equal,
        "all_samples_verified": all(item["verified"] for item in samples),
        "digests": {lane: values[0] for lane, values in digests.items()},
        "cross_implementation_byte_equality_claimed": False,
        "cross_implementation_relation": (
            "matched AIR geometry and independently verified proofs; peer and Zig use "
            "different pinned protocol implementations, so byte equality is not claimed"
        ),
    }


def summarize_size(log_size: int, samples: list[dict]) -> dict:
    medians = {
        lane: {
            "verified_request_ms": _median(samples, lane, "verified_request_ms"),
            "reported_prove_ms": _median(samples, lane, "reported_prove_ms"),
            "process_wall_ms": _median(samples, lane, "process_wall_ms"),
        }
        for lane in LANES
    }
    return {
        "log_n_rows": log_size,
        "rows": 1 << log_size,
        "n_columns": N_COLUMNS,
        "medians": medians,
        "ratios": {
            "zig_cpu_over_peer_cpu_verified_request": (
                medians["zig_cpu"]["verified_request_ms"]
                / medians["peer_cpu"]["verified_request_ms"]
            ),
            "zig_metal_over_peer_metal_verified_request": (
                medians["zig_metal"]["verified_request_ms"]
                / medians["peer_metal"]["verified_request_ms"]
            ),
        },
        "proof_equivalence": _proof_receipt(log_size, samples),
        "samples": samples,
    }


def validate_point(point: dict) -> None:
    if point.get("schema") != SCHEMA or point.get("series_id") != SERIES_ID:
        raise SeriesError("peer series schema identity mismatch")
    peer = point.get("peer_source", {})
    if peer.get("repository") != PEER_REPOSITORY or peer.get("commit") != PEER_COMMIT:
        raise SeriesError("peer series source pin mismatch")
    sizes = point.get("sizes", [])
    if [item.get("log_n_rows") for item in sizes] != list(LOG_SIZES):
        raise SeriesError("peer series must contain exact log sizes 14,16,18,20")
    for size in sizes:
        if size.get("n_columns") != N_COLUMNS:
            raise SeriesError("peer series must use exactly 100 columns")
        if set(size.get("medians", {})) != set(LANES):
            raise SeriesError("peer series lane set mismatch")
        receipt = size.get("proof_equivalence", {})
        if not all(receipt.get(key) for key in (
            "all_samples_stable",
            "peer_cpu_equals_peer_metal",
            "zig_cpu_equals_zig_metal",
            "all_samples_verified",
        )):
            raise SeriesError("peer series proof receipt is incomplete")


def measure(
    repo: Path,
    binaries: dict[str, Path],
    builds: dict[str, list[str]],
    *,
    rounds: int,
    warmups: int,
    allow_dirty: bool,
) -> dict:
    if platform.system() != "Darwin":
        raise SeriesError("the four-lane peer CPU/Metal series requires macOS")
    zig_commit = assert_clean_checkout(repo, allow_dirty)
    assert_large_resource_profile(repo, binaries["zig_cpu"])
    sizes = []
    with tempfile.TemporaryDirectory(prefix="peer-series-") as raw:
        scratch = Path(raw)
        for log_index, log_size in enumerate(LOG_SIZES):
            samples = []
            for round_index in range(rounds):
                order = interleave_order(log_index, round_index)
                for lane in order:
                    if lane.startswith("peer_"):
                        sample = _one_peer(
                            repo, binaries[lane], lane, log_size, warmups, scratch
                        )
                    else:
                        sample = _one_zig(repo, binaries[lane], lane, log_size, warmups)
                    sample["round"] = round_index
                    sample["interleave_position"] = order.index(lane)
                    samples.append(sample)
            sizes.append(summarize_size(log_size, samples))

    rustc, _ = run(["rustc", f"+{RUST_TOOLCHAIN}", "--version", "--verbose"], repo)
    cargo, _ = run(["cargo", f"+{RUST_TOOLCHAIN}", "--version"], repo)
    zig_version, _ = run(["zig", "version"], repo)
    point = {
        "schema": SCHEMA,
        "series_id": SERIES_ID,
        "measured_at_utc": datetime.now(timezone.utc).isoformat(),
        "audit_point": {
            "stwo_zig_commit": zig_commit,
            "cadence": "run at every direct end-to-end audit point",
        },
        "peer_source": {
            "repository": PEER_REPOSITORY,
            "pull_request": 6,
            "commit": PEER_COMMIT,
        },
        "host": host_identity(),
        "toolchains": {
            "rust": RUST_TOOLCHAIN,
            "rustc_version": rustc.strip(),
            "cargo_version": cargo.strip(),
            "zig_version": zig_version.strip(),
        },
        "measurement_contract": {
            "rounds": rounds,
            "warmups_per_lane_invocation": warmups,
            "interleaving": "balanced four-lane rotation within each size and round",
            "primary_metric": "verified_request_ms",
            "workload": "wide_fibonacci",
            "log_n_rows": list(LOG_SIZES),
            "sequence_len_columns": N_COLUMNS,
            "zig_protocol": "functional",
            "peer_protocol": {
                "channel": "Blake2sM31Channel/Blake2sM31MerkleChannel",
                "pcs_config": "PcsConfig::default()",
                "parameters": "retained per sample from the exact peer proof configuration",
            },
            "large_resource_profile": {
                "name": "large",
                "log_n_rows": list(LARGE_LOG_SIZES),
                "argv": list(LARGE_RESOURCE_ARGS),
            },
            "timing_semantics": (
                "verified request is implementation-native end-to-end work with independent "
                "verification; exact included stages are retained per sample"
            ),
        },
        "executables": {
            lane: {
                "path": str(path.resolve()),
                "sha256": sha256_file(path),
                "build_command": builds[lane],
            }
            for lane, path in binaries.items()
        },
        "proof_equivalence_receipt": {
            "all_sizes_pass": True,
            "relations": [
                "peer_cpu proof equals peer_metal proof at each size",
                "zig_cpu proof equals zig_metal proof at each size",
                "every timed proof independently verifies",
            ],
        },
        "sizes": sizes,
    }
    validate_point(point)
    return point


def write_immutable(path: Path, point: dict) -> None:
    encoded = json.dumps(point, indent=2, sort_keys=True) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("x", encoding="utf-8") as destination:
            destination.write(encoded)
    except FileExistsError:
        if path.read_text(encoding="utf-8") != encoded:
            raise SeriesError(f"refusing to replace immutable peer series point {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--allow-dirty", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.rounds <= 0 or args.warmups < 0:
        parser.error("rounds must be positive and warmups non-negative")
    if not all(shutil.which(tool) for tool in ("cargo", "rustc", "zig")):
        raise SystemExit("cargo, rustc, and zig are required on PATH")

    repo = args.repo_root.resolve()
    commit = _git(repo, "rev-parse", "HEAD")
    build_root = args.build_root or (
        Path(tempfile.gettempdir()) / "stwo-peer-series-build" / commit[:12]
    )
    binaries, builds = prepare_binaries(repo, build_root)
    point = measure(
        repo,
        binaries,
        builds,
        rounds=args.rounds,
        warmups=args.warmups,
        allow_dirty=args.allow_dirty,
    )
    out = args.out or (
        repo / "autoresearch/reference/peer-series/runs" / f"{commit}.json"
    )
    write_immutable(out, point)
    print(f"wrote immutable peer series point {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
