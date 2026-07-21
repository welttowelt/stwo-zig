#!/usr/bin/env python3
"""Measure pinned upstream Stwo scalar and SIMD backends on the matched suite.

The two backend paths are separate, named evidence. ``scalar`` instantiates
``CpuBackend``; ``simd`` instantiates ``SimdBackend`` in the Rust prover. The
adapter's default remains scalar for compatibility with conformance callers.

The script builds the parity adapter at the source-pinned revision, measures
the stwo-zig original once, interleaves scalar/SIMD Rust samples by workload,
and writes one immutable reference document per backend. It also generates and
verifies an artifact through both Rust backends and refuses publication unless
their proof bytes match.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import shutil
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ZIG_ORIGINAL_COMMIT = "31a3132ef2e6df99deef7773f6cb5ef797e70d0f"
RUST_UPSTREAM_REPOSITORY = "https://github.com/starkware-libs/stwo"
RUST_UPSTREAM_COMMIT = "a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2"
RUST_TOOLCHAIN = "nightly-2025-07-14"
RUST_FEATURES = ["parallel", "prover"]
BACKENDS = {
    "scalar": {
        "name": "peer-rust-scalar",
        "title": "Upstream Stwo Rust CpuBackend reference on the matched suite",
        "backend_id": "cpu-scalar",
        "backend_type": "stwo::prover::backend::cpu::CpuBackend",
    },
    "simd": {
        "name": "peer-rust-simd",
        "title": "Upstream Stwo Rust SimdBackend reference on the matched suite",
        "backend_id": "simd",
        "backend_type": "stwo::prover::backend::simd::SimdBackend",
    },
}
WORKLOADS = [
    {
        "class": "small",
        "workload": "wf_log10x8",
        "example": "wide_fibonacci",
        "parameters": {"log_n_rows": 10, "sequence_len": 8},
        "zig_args": [
            "--example", "wide_fibonacci", "--log-n-rows", "10",
            "--sequence-len", "8",
        ],
        "rust_args": [
            "--example", "wide_fibonacci", "--wf-log-n-rows", "10",
            "--wf-sequence-len", "8",
        ],
    },
    {
        "class": "wide",
        "workload": "wf_log14x32",
        "example": "wide_fibonacci",
        "parameters": {"log_n_rows": 14, "sequence_len": 32},
        "zig_args": [
            "--example", "wide_fibonacci", "--log-n-rows", "14",
            "--sequence-len", "32",
        ],
        "rust_args": [
            "--example", "wide_fibonacci", "--wf-log-n-rows", "14",
            "--wf-sequence-len", "32",
        ],
    },
    {
        "class": "deep",
        "workload": "plonk_log14",
        "example": "plonk",
        "parameters": {"log_n_rows": 14},
        "zig_args": ["--example", "plonk", "--log-n-rows", "14"],
        "rust_args": ["--example", "plonk", "--plonk-log-n-rows", "14"],
    },
]


def run(cmd: list[str], cwd: Path, timeout: float = 1800) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        rendered = " ".join(cmd[:5])
        raise RuntimeError(f"{rendered} failed:\n{proc.stderr[-1200:]}")
    return proc.stdout


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def host_identity() -> dict:
    chip = platform.processor() or "unknown cpu"
    if platform.system() == "Darwin":
        try:
            chip = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError:
            pass
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": chip,
        "logical_cpu_count": __import__("os").cpu_count(),
    }


def _artifact_proof_sha256(path: Path) -> str:
    artifact = json.loads(path.read_text())
    return hashlib.sha256(bytes.fromhex(artifact["proof_bytes_hex"])).hexdigest()


def _rust_command(
    rust_bin: Path,
    backend: str,
    spec: dict,
    artifact: Path,
    warmups: int,
    samples: int,
) -> list[str]:
    return [
        str(rust_bin),
        "--mode", "bench",
        "--backend", backend,
        "--artifact", str(artifact),
        *spec["rust_args"],
        "--bench-warmups", str(warmups),
        "--bench-repeats", str(samples),
    ]


def _measure_zig(repo: Path, warmups: int, samples: int) -> dict:
    worktree = Path(tempfile.mkdtemp(prefix="peer-rust-zig-original-"))
    run(["git", "worktree", "add", "--detach", str(worktree), ZIG_ORIGINAL_COMMIT], repo)
    try:
        run(["zig", "build", "native-proof-bench-cpu", "-Doptimize=ReleaseFast"], worktree)
        binary = worktree / "zig-out/bin/native-proof-bench-cpu"
        results = {}
        for spec in WORKLOADS:
            report = json.loads(run([
                str(binary),
                *spec["zig_args"],
                "--warmups", str(warmups),
                "--samples", str(samples),
                "--protocol", "functional",
            ], worktree))
            results[spec["class"]] = {
                "median_ms": round(report["timing"]["prove_seconds"]["median"] * 1000, 6),
                "proof_sha256": report["proof"]["samples"][0]["sha256"],
                "all_verified": report["proof"]["verified_samples"] == samples,
            }
        return {
            "binary_sha256": sha256_file(binary),
            "zig_version": run(["zig", "version"], worktree).strip(),
            "results": results,
        }
    finally:
        run(["git", "worktree", "remove", "--force", str(worktree)], repo)


def _measure_rust(repo: Path, rust_bin: Path, warmups: int, samples: int) -> tuple[dict, dict]:
    results = {backend: {} for backend in BACKENDS}
    parity = {}
    with tempfile.TemporaryDirectory(prefix="peer-rust-reference-") as raw:
        scratch = Path(raw)
        for spec in WORKLOADS:
            cls = spec["class"]
            # Alternate which real backend runs first for each workload.
            order = list(BACKENDS)
            if len(results["scalar"]) % 2:
                order.reverse()
            for backend in order:
                report = json.loads(run(
                    _rust_command(
                        rust_bin,
                        backend,
                        spec,
                        scratch / f"bench-{backend}-{cls}.json",
                        warmups,
                        samples,
                    ),
                    repo,
                ))
                if report.get("backend") != BACKENDS[backend]["backend_id"]:
                    raise RuntimeError(f"Rust adapter mislabeled {backend}: {report.get('backend')}")
                if report.get("backend_type") != BACKENDS[backend]["backend_type"]:
                    raise RuntimeError(f"Rust adapter type mismatch for {backend}")
                sample_ms = [round(value * 1000, 6) for value in report["prove"]["samples_seconds"]]
                results[backend][cls] = {
                    "median_ms": round(statistics.median(sample_ms), 6),
                    "samples_ms": sample_ms,
                    "proof_metrics": report["proof_metrics"],
                }

            digests = {}
            for backend in BACKENDS:
                artifact = scratch / f"proof-{backend}-{cls}.json"
                run([
                    str(rust_bin),
                    "--mode", "generate",
                    "--backend", backend,
                    "--artifact", str(artifact),
                    *spec["rust_args"],
                ], repo)
                run([
                    str(rust_bin),
                    "--mode", "verify",
                    "--artifact", str(artifact),
                ], repo)
                digests[backend] = _artifact_proof_sha256(artifact)
            if len(set(digests.values())) != 1:
                raise RuntimeError(f"scalar/SIMD proof mismatch for {spec['workload']}: {digests}")
            if results["scalar"][cls]["proof_metrics"] != results["simd"][cls]["proof_metrics"]:
                raise RuntimeError(f"scalar/SIMD proof metric mismatch for {spec['workload']}")
            parity[cls] = {
                "proof_sha256": digests["scalar"],
                "scalar_equals_simd": True,
                "scalar_verified": True,
                "simd_verified": True,
            }
    return results, parity


def build_reference_documents(
    *,
    measured_at_utc: str,
    host: dict,
    warmups: int,
    samples: int,
    executable: dict,
    toolchain: dict,
    zig: dict,
    rust: dict,
    parity: dict,
) -> dict[str, dict]:
    documents = {}
    for backend, metadata in BACKENDS.items():
        rows = []
        ratios = []
        for spec in WORKLOADS:
            cls = spec["class"]
            rust_result = rust[backend][cls]
            ratio = rust_result["median_ms"] / zig["results"][cls]["median_ms"]
            ratios.append(ratio)
            rows.append({
                "class": cls,
                "workload": spec["workload"],
                "example": spec["example"],
                "parameters": spec["parameters"],
                "zig_original_median_ms": zig["results"][cls]["median_ms"],
                "rust_median_ms": rust_result["median_ms"],
                "ratio_rust_over_zig_original": round(ratio, 6),
                "rust_samples_ms": rust_result["samples_ms"],
                "proof_parity": parity[cls],
            })
        documents[backend] = {
            "schema": "autoresearch-reference-v2",
            "reference_kind": "upstream-rust-backend",
            "name": metadata["name"],
            "title": metadata["title"],
            "measured_at_utc": measured_at_utc,
            "host": host,
            "zig_reference": {
                "commit": ZIG_ORIGINAL_COMMIT,
                "description": "pre-optimization stwo-zig suite-score baseline",
                "build": "zig build native-proof-bench-cpu -Doptimize=ReleaseFast",
                "zig_version": zig["zig_version"],
                "executable_sha256": zig["binary_sha256"],
            },
            "rust_reference": {
                "repository": RUST_UPSTREAM_REPOSITORY,
                "source_commit": RUST_UPSTREAM_COMMIT,
                "toolchain": RUST_TOOLCHAIN,
                "features": RUST_FEATURES,
                "tool": "tools/stwo-interop-rs --mode bench",
                "backend_id": metadata["backend_id"],
                "backend_type": metadata["backend_type"],
                "executable": executable,
                "toolchain_identity": toolchain,
            },
            "workload_protocol": {
                "suite": "small/wide/deep matched functional suite",
                "pcs": {
                    "pow_bits": 0,
                    "fri_log_blowup": 1,
                    "fri_log_last_layer": 0,
                    "fri_queries": 3,
                    "fold_step": 1,
                },
            },
            "timing_semantics": {
                "rust_metric": "wall clock around proof construction plus JSON wire encoding",
                "zig_metric": "native report prove_seconds; input preparation, encoding, and verification excluded",
                "aggregation": f"median of {samples} samples after {warmups} warmups",
                "comparison_grade": "reference-grade, not paired judge evidence",
            },
            "suite_ratio_geomean_rust_over_zig_original": round(
                math.exp(sum(math.log(value) for value in ratios) / len(ratios)), 6
            ),
            "per_workload": rows,
            "proof_equivalence_receipt": {
                "scope": "Rust scalar versus Rust SIMD for each exact statement and PCS config",
                "all_equal": all(item["scalar_equals_simd"] for item in parity.values()),
                "workloads": parity,
            },
            "method": [
                "Scalar and SIMD are separate real generic instantiations of the pinned Rust prover.",
                "Rust backend order alternates by workload on the same host and executable.",
                "Each generated artifact is independently verified; scalar and SIMD proof bytes must match.",
                "The Rust timing includes proof wire serialization while the Zig metric is prove-only, so the Rust ratio is conservatively overstated.",
            ],
        }
    return documents


def measure(repo: Path, warmups: int, samples: int) -> dict[str, dict]:
    zig = _measure_zig(repo, warmups, samples)
    build_command = [
        "cargo",
        f"+{RUST_TOOLCHAIN}",
        "build",
        "--release",
        "--locked",
        "--manifest-path",
        "tools/stwo-interop-rs/Cargo.toml",
    ]
    run(build_command, repo)
    rust_bin = repo / "tools/stwo-interop-rs/target/release/stwo-interop-rs"
    rust, parity = _measure_rust(repo, rust_bin, warmups, samples)
    return build_reference_documents(
        measured_at_utc=datetime.now(timezone.utc).isoformat(),
        host=host_identity(),
        warmups=warmups,
        samples=samples,
        executable={
            "path": "tools/stwo-interop-rs/target/release/stwo-interop-rs",
            "sha256": sha256_file(rust_bin),
            "build_command": build_command,
            "cargo_lock_sha256": sha256_file(repo / "tools/stwo-interop-rs/Cargo.lock"),
        },
        toolchain={
            "rustc_version": run(["rustc", f"+{RUST_TOOLCHAIN}", "--version", "--verbose"], repo).strip(),
            "cargo_version": run(["cargo", f"+{RUST_TOOLCHAIN}", "--version"], repo).strip(),
        },
        zig=zig,
        rust=rust,
        parity=parity,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--warmups", type=int, default=10)
    parser.add_argument("--samples", type=int, default=15)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="directory for peer-rust-scalar.json and peer-rust-simd.json",
    )
    args = parser.parse_args()
    if args.warmups < 0 or args.samples <= 0:
        parser.error("warmups must be non-negative and samples must be positive")
    if shutil.which("zig") is None or shutil.which("cargo") is None:
        raise SystemExit("zig and cargo are required on PATH")

    documents = measure(args.repo_root.resolve(), args.warmups, args.samples)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for backend, document in documents.items():
        path = args.out_dir / f"{document['name']}.json"
        path.write_text(json.dumps(document, indent=2) + "\n")
        print(
            f"wrote {path}: {backend} rust/zig geomean "
            f"{document['suite_ratio_geomean_rust_over_zig_original']:.3f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
