#!/usr/bin/env python3
"""Re-runnable peer-Rust reference measurement.

Reproduces autoresearch/reference/peer-rust-scalar.json on any device:
same-session, back-to-back medians of the matched three-workload suite —
the zig prover at the recorded pre-optimization commit versus the pinned
upstream Rust prover (through the parity oracle tool, CpuBackend with the
crate's `parallel` feature). Stdlib only.

  python3 autoresearch/reference/measure_peer_rust.py            # from repo root
  python3 autoresearch/reference/measure_peer_rust.py --samples 15 --warmups 10

Requires: zig 0.15.2, rustup with the pinned nightly toolchain, network for
the first cargo build. Writes the JSON next to this script by default; the
feed publishes it verbatim. Numbers are reference-grade (not ABBA-judged):
ordering and magnitude are meaningful, sub-percent differences are not.
"""

from __future__ import annotations

import argparse
import json
import platform
import shutil
import statistics
import subprocess
import tempfile
from datetime import date
from pathlib import Path

ZIG_ORIGINAL_COMMIT = "31a3132ef2e6df99deef7773f6cb5ef797e70d0f"
RUST_TOOLCHAIN = "nightly-2025-07-14"
WORKLOADS = [
    {
        "class": "small", "workload": "wf_log10x8", "example": "wide_fibonacci",
        "parameters": {"log_n_rows": 10, "sequence_len": 8},
        "zig_args": ["--example", "wide_fibonacci", "--log-n-rows", "10", "--sequence-len", "8"],
        "rust_args": ["--example", "wide_fibonacci", "--wf-log-n-rows", "10", "--wf-sequence-len", "8"],
    },
    {
        "class": "wide", "workload": "wf_log14x32", "example": "wide_fibonacci",
        "parameters": {"log_n_rows": 14, "sequence_len": 32},
        "zig_args": ["--example", "wide_fibonacci", "--log-n-rows", "14", "--sequence-len", "32"],
        "rust_args": ["--example", "wide_fibonacci", "--wf-log-n-rows", "14", "--wf-sequence-len", "32"],
    },
    {
        "class": "deep", "workload": "plonk_log14", "example": "plonk",
        "parameters": {"log_n_rows": 14},
        "zig_args": ["--example", "plonk", "--log-n-rows", "14"],
        "rust_args": ["--example", "plonk", "--plonk-log-n-rows", "14"],
    },
]


def run(cmd: list[str], cwd: Path, timeout: float = 1800) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise SystemExit(f"{' '.join(cmd[:4])}… failed:\n{proc.stderr[-800:]}")
    return proc.stdout


def host_identity() -> str:
    if platform.system() == "Darwin":
        try:
            return subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError:
            pass
    return f"{platform.system()} {platform.machine()} ({platform.processor() or 'unknown cpu'})"


def measure(repo: Path, warmups: int, samples: int) -> dict:
    # Zig side: the recorded pre-optimization commit, built fresh in a worktree.
    worktree = Path(tempfile.mkdtemp(prefix="peer-rust-zig-original-"))
    run(["git", "worktree", "add", "--detach", str(worktree), ZIG_ORIGINAL_COMMIT], cwd=repo)
    try:
        run(["zig", "build", "native-proof-bench-cpu", "-Doptimize=ReleaseFast"], cwd=worktree)
        zig_bench = worktree / "zig-out/bin/native-proof-bench-cpu"
        zig_results = {}
        for spec in WORKLOADS:
            out = run(
                [str(zig_bench), *spec["zig_args"], "--warmups", str(warmups),
                 "--samples", str(samples), "--protocol", "functional"],
                cwd=worktree,
            )
            report = json.loads(out)
            zig_results[spec["class"]] = round(
                report["timing"]["prove_seconds"]["median"] * 1000, 6
            )
    finally:
        run(["git", "worktree", "remove", "--force", str(worktree)], cwd=repo)

    # Rust side: the pinned parity oracle with the crate's parallel feature.
    run(
        ["cargo", f"+{RUST_TOOLCHAIN}", "build", "--release", "--locked",
         "--manifest-path", "tools/stwo-interop-rs/Cargo.toml"],
        cwd=repo,
    )
    rust_bin = repo / "tools/stwo-interop-rs/target/release/stwo-interop-rs"
    rust_results = {}
    with tempfile.TemporaryDirectory() as raw:
        for spec in WORKLOADS:
            out = run(
                [str(rust_bin), "--mode", "bench", "--artifact", f"{raw}/artifact.json",
                 *spec["rust_args"], "--bench-warmups", str(warmups),
                 "--bench-repeats", str(samples)],
                cwd=repo,
            )
            report = json.loads(out)
            samples_s = report["prove"]["samples_seconds"]
            rust_results[spec["class"]] = {
                "median_ms": round(statistics.median(samples_s) * 1000, 6),
                "samples_ms": [round(s * 1000, 6) for s in samples_s],
            }

    per_workload = []
    log_sum = 0.0
    for spec in WORKLOADS:
        cls = spec["class"]
        ratio = rust_results[cls]["median_ms"] / zig_results[cls]
        log_sum += __import__("math").log(ratio)
        per_workload.append({
            "class": cls,
            "workload": spec["workload"],
            "example": spec["example"],
            "parameters": spec["parameters"],
            "zig_original_median_ms": zig_results[cls],
            "rust_scalar_median_ms": rust_results[cls]["median_ms"],
            "ratio_rust_over_zig_original": round(ratio, 6),
            "rust_samples_ms": rust_results[cls]["samples_ms"],
        })
    geomean = __import__("math").exp(log_sum / len(WORKLOADS))

    return {
        "schema": "autoresearch-reference-v1",
        "name": "peer-rust-scalar",
        "title": "Upstream Stwo prover (Rust, CpuBackend + parallel feature) on the matched suite",
        "measured_at_utc": date.today().isoformat(),
        "host": host_identity(),
        "zig_reference": {
            "commit": ZIG_ORIGINAL_COMMIT,
            "description": "pre-optimization stwo-zig main — the suite-score baseline (score 100)",
            "build": "zig build native-proof-bench-cpu -Doptimize=ReleaseFast",
        },
        "rust_reference": {
            "crate_rev": "a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2",
            "toolchain": RUST_TOOLCHAIN,
            "tool": "tools/stwo-interop-rs --mode bench (the pinned parity oracle)",
            "backend": "CpuBackend (scalar lanes) with the crate's `parallel` (rayon) feature",
        },
        "suite_ratio_geomean_rust_over_zig_original": round(geomean, 6),
        "per_workload": per_workload,
        "method": [
            f"Same host, same session, back-to-back medians of {samples} samples after {warmups} warmups per workload, via autoresearch/reference/measure_peer_rust.py.",
            "Reference-grade: NOT interleaved ABBA pairing and NOT a judged run; ordering and magnitude are meaningful, sub-percent differences are not.",
            "Rust prove samples include JSON wire serialization of the proof (the bench tool times prove+encode); zig timings are prove only — the Rust side is slightly overstated.",
            "The parity tool pins upstream CpuBackend with the `parallel` feature enabled; upstream also ships a SIMD backend this reference does NOT exercise. A SIMD-matched reference is the known follow-up before any cross-implementation performance claim beyond this oracle.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--warmups", type=int, default=10)
    parser.add_argument("--samples", type=int, default=15)
    parser.add_argument("--out", type=Path,
                        default=Path(__file__).resolve().parent / "peer-rust-scalar.json")
    args = parser.parse_args()
    if shutil.which("zig") is None or shutil.which("cargo") is None:
        raise SystemExit("zig and cargo are required on PATH")
    doc = measure(args.repo_root.resolve(), args.warmups, args.samples)
    args.out.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"✓ wrote {args.out}")
    print(f"  suite geomean rust/zig-original: {doc['suite_ratio_geomean_rust_over_zig_original']:.3f}")
    for row in doc["per_workload"]:
        print(f"  {row['class']:5s} zig {row['zig_original_median_ms']:.3f} ms · "
              f"rust {row['rust_scalar_median_ms']:.3f} ms · ×{row['ratio_rust_over_zig_original']:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
