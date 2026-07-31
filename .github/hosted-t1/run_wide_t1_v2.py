#!/usr/bin/env python3
"""Run one evidence-retaining RISC-V wide T1 proxy estimate.

The proxy is installed only in an in-memory copy of the canonical manifest.
Neither the candidate nor predecessor worktree is modified.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


PROXY_ID = "riscv_fixed_tables_memcpy_proxy"
BOARD = "riscv"
WORKLOAD_CLASS = "wide"
ERA = 2
BOUNDARY = "prove_ms"
COST_TARGET_SECONDS = 300
PROMOTION_THRESHOLD = 0.98
TARGET_WORKLOAD_IDS = [
    "riscv_memcpy_loop",
    "riscv_sieve_primes",
    "riscv_bubble_sort",
    "riscv_collatz",
    "riscv_keccak_128b",
    "riscv_sha2_128b",
    "riscv_sha2_256b",
]
SOURCE_WORKLOAD_ID = "riscv_memcpy_loop"
EXPECTED_SOURCE_ARGS = (
    "bench --elf vectors/riscv_elfs/memcpy_loop.elf --backend cpu "
    "--protocol functional {admission} --warmups {warmups} --samples {samples}"
)
PROXY_ARGS = (
    "bench --elf vectors/riscv_elfs/memcpy_loop.elf --backend cpu "
    "{admission} --warmups {warmups} --samples {samples}"
)
EXPECTED_NATIVE_UNIT = "executed instructions"
SECURE_DEFAULT_SOURCE = Path("src/products/riscv_shared/cli.zig")
SECURE_DEFAULT_SOURCE_SHA256 = (
    "8b6a895e9bd2100f7d36a0daae1c8bc41cfc39865b272d1269fa2b9ce7d63347"
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def tracked_clean(root: Path) -> bool:
    unstaged = subprocess.run(
        ["git", "-C", str(root), "diff", "--quiet", "--"],
        check=False,
    ).returncode
    staged = subprocess.run(
        ["git", "-C", str(root), "diff", "--cached", "--quiet", "--"],
        check=False,
    ).returncode
    return unstaged == 0 and staged == 0


def raw_artifact_manifest(raw_dir: Path, rounds: int) -> dict:
    report_re = re.compile(rf"^{re.escape(PROXY_ID)}\.[ab][1-9][0-9]*\.json$")
    proof_re = re.compile(
        rf"^{re.escape(PROXY_ID)}\.[ab][1-9][0-9]*\.proof\.json$"
    )
    paths = sorted(path for path in raw_dir.iterdir() if path.is_file())
    reports = [path for path in paths if report_re.fullmatch(path.name)]
    proofs = [path for path in paths if proof_re.fullmatch(path.name)]
    expected = 2 * rounds
    if len(reports) != expected:
        raise RuntimeError(
            f"expected {expected} raw report envelopes, found {len(reports)}"
        )
    if len(proofs) != expected:
        raise RuntimeError(
            f"expected {expected} retained proofs, found {len(proofs)}"
        )
    allowed = set(reports + proofs)
    unexpected = [path.name for path in paths if path not in allowed]
    if unexpected:
        raise RuntimeError(f"unexpected raw artifact(s): {unexpected}")
    entries = [
        {
            "id": f"raw-{index:03d}",
            "path": path.relative_to(raw_dir.parent).as_posix(),
            "kind": "proof" if proof_re.fullmatch(path.name) else "report",
            "sha256": sha256_file(path),
            "bytes": path.stat().st_size,
        }
        for index, path in enumerate(paths, start=1)
    ]
    return {
        "schema": "stwo-riscv-hosted-t1-raw-abba-manifest/v1",
        "proxy_id": PROXY_ID,
        "rounds": rounds,
        "report_count": len(reports),
        "proof_count": len(proofs),
        "artifact_count": len(entries),
        "artifacts": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--predecessor-root", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--raw-manifest", type=Path, required=True)
    parser.add_argument("--proxy-contract", type=Path, required=True)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    predecessor_root = args.predecessor_root.resolve()
    out_dir = args.out_dir.resolve()
    result_path = args.result.resolve()
    raw_manifest_path = args.raw_manifest.resolve()
    proxy_contract_path = args.proxy_contract.resolve()
    if out_dir.exists() and any(out_dir.iterdir()):
        raise RuntimeError(f"raw output directory is not empty: {out_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(repo_root / "autoresearch" / "cli"))
    from stwo_perf import manifest as manifest_mod  # noqa: PLC0415
    from stwo_perf import runner  # noqa: PLC0415

    base = manifest_mod.load(repo_root)
    manifest_path = repo_root / "autoresearch" / "MANIFEST.json"
    manifest_sha256 = sha256_file(manifest_path)
    group = base.group_for_board(BOARD)
    source = next(
        (
            workload
            for workload in group.workloads
            if workload.workload_id == SOURCE_WORKLOAD_ID
        ),
        None,
    )
    if source is None:
        raise RuntimeError(f"missing source workload {SOURCE_WORKLOAD_ID}")
    if source.workload_class != WORKLOAD_CLASS:
        raise RuntimeError("source workload class drifted")
    if source.args != EXPECTED_SOURCE_ARGS:
        raise RuntimeError("source workload arguments drifted")
    if source.native_unit != EXPECTED_NATIVE_UNIT:
        raise RuntimeError("source workload native unit drifted")
    observed_targets = [
        workload.workload_id
        for workload in group.workloads
        if workload.workload_class == WORKLOAD_CLASS
    ]
    if observed_targets != TARGET_WORKLOAD_IDS:
        raise RuntimeError(
            f"wide workload universe drifted: {observed_targets}"
        )
    if group.report_schema != "riscv_proof_v2":
        raise RuntimeError(f"RISC-V report schema drifted: {group.report_schema}")
    if group.scored_dimension != BOUNDARY:
        raise RuntimeError(
            f"current-era scored boundary drifted: {group.scored_dimension}"
        )
    phases = runner.PHASE_SECONDS_FIELDS.get(group.report_schema, {})
    if "prove" not in phases:
        raise RuntimeError("RISC-V report schema no longer exposes prove")
    if base.tier_cost_target_seconds("T1") != COST_TARGET_SECONDS:
        raise RuntimeError("official T1 cost target drifted")
    if base.proxy_fixture(WORKLOAD_CLASS) is not None:
        raise RuntimeError("canonical wide class gained a proxy; controller is stale")
    for root, label in (
        (repo_root, "candidate"),
        (predecessor_root, "predecessor"),
    ):
        source_path = root / SECURE_DEFAULT_SOURCE
        if sha256_file(source_path) != SECURE_DEFAULT_SOURCE_SHA256:
            raise RuntimeError(f"{label} secure protocol default source drifted")
        if "protocol: Protocol = .secure," not in source_path.read_text(
            encoding="utf-8"
        ):
            raise RuntimeError(f"{label} no longer defaults to secure protocol")

    proxy = {
        "proxy_id": PROXY_ID,
        "args": PROXY_ARGS,
        "native_unit": source.native_unit,
        "official_params": True,
        "target_workload_ids": TARGET_WORKLOAD_IDS,
        "note": (
            "Controller-only T1 scheduling proxy reusing the riscv_memcpy_loop "
            "ELF and inheriting the official secure protocol default; no era "
            "validity receipt exists."
        ),
    }
    raw = copy.deepcopy(base.raw)
    raw["workload_registry"]["classes"][WORKLOAD_CLASS][
        "proxy_fixture"
    ] = proxy
    manifest_mod._validate(raw)
    overlay = manifest_mod.Manifest(base.root, raw)
    if overlay.proxy_fixture(WORKLOAD_CLASS) != proxy:
        raise RuntimeError("in-memory proxy did not round-trip")

    before = {
        "candidate_head": git(repo_root, "rev-parse", "HEAD"),
        "candidate_tree": git(repo_root, "rev-parse", "HEAD^{tree}"),
        "candidate_tracked_clean": tracked_clean(repo_root),
        "predecessor_head": git(predecessor_root, "rev-parse", "HEAD"),
        "predecessor_tree": git(predecessor_root, "rev-parse", "HEAD^{tree}"),
        "predecessor_tracked_clean": tracked_clean(predecessor_root),
    }
    if not before["candidate_tracked_clean"] or not before["predecessor_tracked_clean"]:
        raise RuntimeError("a measurement arm has tracked changes before execution")
    proxy_contract = {
        "schema": "stwo-riscv-hosted-t1-proxy-contract/v1",
        "board": BOARD,
        "workload_class": WORKLOAD_CLASS,
        "era": ERA,
        "boundary": BOUNDARY,
        "fast_boundary": False,
        "cost_target_seconds": COST_TARGET_SECONDS,
        "promotion_threshold": PROMOTION_THRESHOLD,
        "canonical_manifest_sha256": manifest_sha256,
        "canonical_proxy_fixture": None,
        "overlay_scope": "memory-only",
        "proxy": proxy,
        "source_workload_id": SOURCE_WORKLOAD_ID,
        "source_workload_args_sha256": sha256_bytes(source.args.encode("utf-8")),
        "secure_default_source": SECURE_DEFAULT_SOURCE.as_posix(),
        "secure_default_source_sha256": SECURE_DEFAULT_SOURCE_SHA256,
        "git_before": before,
    }
    write_json(proxy_contract_path, proxy_contract)

    result = runner.iterate_estimate(
        repo_root,
        predecessor_root,
        overlay,
        WORKLOAD_CLASS,
        out_dir,
        board=BOARD,
        fast_boundary=False,
        era=ERA,
    )
    if result.get("schema") != runner.LADDER_T1_SCHEMA:
        raise RuntimeError("unexpected T1 result schema")
    if result.get("ranks") is not False:
        raise RuntimeError("T1 result unexpectedly claims ranking authority")
    if result.get("boundary") != BOUNDARY:
        raise RuntimeError(f"result boundary drifted: {result.get('boundary')}")
    if result.get("cost_target_seconds") != COST_TARGET_SECONDS:
        raise RuntimeError("result T1 cost target drifted")
    if result.get("proxy") != proxy:
        raise RuntimeError("result proxy contract drifted")
    if (result.get("proxy_validity") or {}).get("validated") is not False:
        raise RuntimeError("controller-only proxy unexpectedly claims validity")
    per_workload = result.get("per_workload")
    if not isinstance(per_workload, dict) or list(per_workload) != [PROXY_ID]:
        raise RuntimeError("result did not measure exactly the frozen proxy")
    rounds = per_workload[PROXY_ID].get("rounds")
    if type(rounds) is not int or not 3 <= rounds <= 15:
        raise RuntimeError(f"invalid paired-round count: {rounds}")
    write_json(result_path, result)
    write_json(raw_manifest_path, raw_artifact_manifest(out_dir, rounds))

    after = {
        "candidate_head": git(repo_root, "rev-parse", "HEAD"),
        "candidate_tree": git(repo_root, "rev-parse", "HEAD^{tree}"),
        "candidate_tracked_clean": tracked_clean(repo_root),
        "predecessor_head": git(predecessor_root, "rev-parse", "HEAD"),
        "predecessor_tree": git(predecessor_root, "rev-parse", "HEAD^{tree}"),
        "predecessor_tracked_clean": tracked_clean(predecessor_root),
    }
    if after != before:
        raise RuntimeError(f"measurement arm identity changed: {before} -> {after}")
    proxy_contract["git_after"] = after
    proxy_contract["result_sha256"] = sha256_file(result_path)
    proxy_contract["raw_manifest_sha256"] = sha256_file(raw_manifest_path)
    write_json(proxy_contract_path, proxy_contract)

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
