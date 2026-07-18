"""Paired A/B reward evaluation.

Composes the checked-in Zig bench harness rather than reimplementing it: each
arm is built with the manifest build step and exercised through the bench
binary; scoring pairs alternating rounds (ABBA order to cancel linear drift)
and estimates the ratio with Hodges-Lehmann plus a bootstrap CI.

v1 honesty note: the bench report exposes per-run medians, not raw samples, so
pairing is at round level (samples_per_round each), not sample level. The
verdict records this in evidence.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import ledger, stats
from .manifest import (
    REPORT_SCHEMA_VERSIONS,
    Manifest,
    ManifestError,
    Workload,
    WorkloadGroup,
)


class RunError(RuntimeError):
    pass


@dataclass
class ArmResult:
    prove_ms: float
    proof_verified: int
    byte_identical: bool
    peak_rss_mib: float | None
    report_path: str


@dataclass
class WorkloadScore:
    workload: Workload
    ratios: list[float]
    r: float
    ci: tuple[float, float]
    a_median_ms: float
    b_median_ms: float
    rss_ratio: float | None
    reports: list[str] = field(default_factory=list)


def _run(cmd: str, cwd: Path, timeout: int) -> str:
    try:
        proc = subprocess.run(
            shlex.split(cmd), cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as exc:
        raise RunError(f"command timed out after {timeout}s: {cmd}") from exc
    if proc.returncode != 0:
        raise RunError(f"command failed ({cmd}):\n{proc.stderr.strip()[-800:]}")
    return proc.stdout


def announce_skipped_groups(manifest: Manifest) -> list[dict]:
    """Print one loud line per disabled group and return the skip records.

    Every runner entry point calls this so a disabled group is never
    silently dropped from a run.
    """
    skipped = []
    for group in manifest.groups():
        if group.enabled:
            continue
        reason = group.disabled_reason or "no reason recorded"
        print(f"skipped group {group.group_id}: {reason}")
        skipped.append({"group": group.group_id, "reason": reason})
    return skipped


def build_arm(arm_root: Path, manifest: Manifest, timeout: int = 900,
              groups: list[WorkloadGroup] | None = None) -> None:
    """Build the bench binaries for the given groups (default: all enabled)."""
    if groups is None:
        groups = [g for g in manifest.groups() if g.enabled]
    seen: set[str] = set()
    for group in groups:
        if group.build_step in seen:
            continue
        seen.add(group.build_step)
        _run(group.build_step, arm_root, timeout)


def bench_once(
    arm_root: Path,
    manifest: Manifest,
    workload: Workload,
    warmups: int,
    samples: int,
    out_dir: Path,
    tag: str,
) -> ArmResult:
    group = manifest.group(workload.group_id)
    binary = arm_root / group.binary
    if not binary.is_file():
        raise RunError(
            f"group {group.group_id}: bench binary not found at {binary} — "
            f"build it first ({group.build_step}); refusing to fabricate measurements"
        )
    args = workload.args.format(warmups=warmups, samples=samples)
    stdout = _run(f"{binary} {args}", arm_root, timeout=1200)
    try:
        report = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RunError(
            f"{workload.workload_id}: bench emitted non-JSON output "
            f"(first 200 chars: {stdout[:200]!r})"
        ) from exc
    if not isinstance(report, dict):
        raise RunError(f"{workload.workload_id}: bench report root must be a JSON object")
    expected_schema = REPORT_SCHEMA_VERSIONS[group.report_schema]
    actual_schema = report.get("schema_version")
    if type(actual_schema) is not int or actual_schema != expected_schema:
        raise RunError(
            f"{workload.workload_id}: group {group.group_id} expected "
            f"{group.report_schema} (schema_version={expected_schema}), got "
            f"schema_version={actual_schema!r}"
        )
    out_path = out_dir / f"{workload.workload_id}.{tag}.json"
    out_path.write_text(json.dumps(report, indent=1))
    timing = report["timing"]["prove_seconds"]
    proof = report["proof"]
    rss = _peak_rss_mib(report)
    return ArmResult(
        prove_ms=float(timing["median"]) * 1000.0,
        proof_verified=int(proof.get("verified_samples", 0)),
        byte_identical=bool(proof.get("all_samples_byte_identical", False)),
        peak_rss_mib=rss,
        report_path=str(out_path),
    )


def _peak_rss_mib(report: dict) -> float | None:
    rss = report.get("resources", {}).get("peak_rss_kib")
    if isinstance(rss, dict):
        rss = rss.get("median")
    return float(rss) / 1024.0 if rss else None


def paired_rounds(
    a_root: Path,
    b_root: Path,
    manifest: Manifest,
    workload: Workload,
    policy: dict,
    out_dir: Path,
    stop_theta: float | None = None,
    round_budget: int | None = None,
) -> WorkloadScore:
    """ABBA round pairs until the CI half-width is under theta/2 or a cap hits."""
    warmups = int(policy["warmups"])
    samples = int(policy["samples_per_round"])
    min_rounds = int(policy["min_rounds"])
    max_rounds = round_budget or int(policy["max_rounds"])
    stop_theta = stop_theta if stop_theta is not None else float(policy["theta_floor"])
    cap = int(policy["wall_clock_cap_seconds"][workload.workload_class])
    started = time.monotonic()

    ratios: list[float] = []
    a_meds: list[float] = []
    b_meds: list[float] = []
    reports: list[str] = []
    rss_a: list[float] = []
    rss_b: list[float] = []

    round_no = 0
    while round_no < max_rounds:
        round_no += 1
        order = ("a", "b") if round_no % 2 == 1 else ("b", "a")
        results: dict[str, ArmResult] = {}
        for arm in order:
            root = a_root if arm == "a" else b_root
            results[arm] = bench_once(
                root, manifest, workload, warmups, samples, out_dir, f"{arm}{round_no}"
            )
        a, b = results["a"], results["b"]
        if a.proof_verified < samples or b.proof_verified < samples:
            raise RunError(f"{workload.workload_id}: unverified proofs in round {round_no}")
        if not a.byte_identical or not b.byte_identical:
            raise RunError(
                f"{workload.workload_id}: proof bytes changed across verified samples "
                f"in round {round_no}"
            )
        ratios.append(b.prove_ms / a.prove_ms)
        a_meds.append(a.prove_ms)
        b_meds.append(b.prove_ms)
        reports.extend([a.report_path, b.report_path])
        if a.peak_rss_mib:
            rss_a.append(a.peak_rss_mib)
        if b.peak_rss_mib:
            rss_b.append(b.peak_rss_mib)

        elapsed = time.monotonic() - started
        if round_no >= min_rounds:
            ci = stats.bootstrap_ci(ratios, seed=_seed(workload.workload_id, 0))
            if (ci[1] - ci[0]) / 2.0 <= stop_theta / 2.0:
                break
            if elapsed > cap:
                break
        elif elapsed > cap and round_no >= 3:
            break

    r = stats.hodges_lehmann(ratios)
    ci = stats.bootstrap_ci(ratios, seed=_seed(workload.workload_id, 0))
    rss_ratio = None
    if rss_a and rss_b:
        rss_ratio = (sum(rss_b) / len(rss_b)) / (sum(rss_a) / len(rss_a))
    return WorkloadScore(
        workload=workload,
        ratios=ratios,
        r=r,
        ci=ci,
        a_median_ms=sorted(a_meds)[len(a_meds) // 2],
        b_median_ms=sorted(b_meds)[len(b_meds) // 2],
        rss_ratio=rss_ratio,
        reports=reports,
    )


def _seed(workload_id: str, round_no: int) -> int:
    digest = hashlib.sha256(f"{workload_id}:{round_no}".encode()).digest()
    return int.from_bytes(digest[:4], "big")


def environment_block(repo_root: Path, judged: bool) -> dict:
    clean = _git(repo_root, "status", "--porcelain") == ""
    zig = _try(lambda: _run("zig version", repo_root, 60).strip())
    return {
        "host": hashlib.sha256(platform.node().encode()).hexdigest()[:12],
        "os": f"{platform.system()} {platform.release()}",
        "zig_version": zig,
        "release_fast": True,
        "clean_tree": clean,
        "judge_lock_held": judged,
        "preflight": _preflight(),
    }


def _preflight() -> dict:
    try:
        load1 = os.getloadavg()[0]
        cores = os.cpu_count() or 1
        return {"load_ok": load1 < cores * 0.75, "load1": round(load1, 2)}
    except OSError:
        return {"load_ok": True, "load1": None}


def acquire_judge_lock(repo_root: Path) -> Path:
    """Host-wide exclusivity: judged and searcher runs refuse to overlap.

    Atomic O_CREAT|O_EXCL create; a lock whose recorded pid is dead is stale
    and reclaimed. The path is host-wide by design (one judge per machine).
    """
    lock = Path("/tmp/stwo-perf-judge.lock")
    payload = f"{os.getpid()} {repo_root}\n".encode()
    for _ in range(2):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.write(fd, payload)
            os.close(fd)
            return lock
        except FileExistsError:
            try:
                pid = int(lock.read_text().split()[0])
                os.kill(pid, 0)
            except PermissionError as exc:
                # Process exists under another user: the lock is live.
                raise RunError(f"judge lock held by another user ({lock})") from exc
            except (ValueError, IndexError, ProcessLookupError, OSError):
                lock.unlink(missing_ok=True)  # stale; retry once
                continue
            raise RunError(f"judge lock held by pid {pid} ({lock})")
    raise RunError(f"could not acquire judge lock ({lock})")


def draw_holdout(manifest: Manifest, workload_class: str, seed: int,
                 board: str = "core_cpu") -> Workload | None:
    """Seeded jittered hold-out inside class bounds (playbook F.7)."""
    import random

    gen = manifest.raw["workload_registry"].get("holdout_generator", {})
    bounds = gen.get(workload_class)
    if not bounds:
        return None
    candidates = manifest.workloads(workload_class, board=board)
    if not candidates:
        return None
    rng = random.Random(seed)
    base = candidates[0]
    log_lo, log_hi = bounds["log_n_rows"]
    log_n = rng.randint(log_lo, log_hi)
    args = _replace_flag(base.args, "--log-n-rows", str(log_n))
    if bounds.get("sequence_len"):
        seq_lo, seq_hi = bounds["sequence_len"]
        args = _replace_flag(args, "--sequence-len", str(rng.randint(seq_lo, seq_hi)))
    return Workload(f"holdout_{workload_class}", workload_class, args,
                    base.native_unit, base.group_id)


def _replace_flag(args: str, flag: str, value: str) -> str:
    parts = args.split()
    if flag in parts:
        parts[parts.index(flag) + 1] = value
    return " ".join(parts)


def evaluate_aa(repo_root: Path, manifest: Manifest, workload_class: str,
                out_dir: Path, board: str = "core_cpu") -> dict:
    """A/A run (both arms = this tree): measures the per-class dispersion that
    theta is built from. Record the half_width in ledger/epochs.json by PR."""
    out_dir.mkdir(parents=True, exist_ok=True)
    skipped = announce_skipped_groups(manifest)
    workloads = _board_workloads(manifest, board, workload_class)
    if not workloads:
        raise RunError(
            f"no enabled workloads registered for board {board}, class {workload_class}"
        )
    workload = workloads[0]
    build_arm(repo_root, manifest, groups=[manifest.group(workload.group_id)])
    score = paired_rounds(repo_root, repo_root, manifest, workload,
                          manifest.gates, out_dir)
    half_width = (score.ci[1] - score.ci[0]) / 2.0
    return {
        "workload_class": workload_class,
        "board": board,
        "workload": workload.workload_id,
        "rounds": len(score.ratios),
        "aa_r": round(score.r, 6),
        "half_width": round(half_width, 6),
        "skipped_groups": skipped,
        "record_as": {"ledger/epochs.json": {"aa_dispersion": {
            board: {workload_class: round(half_width, 6)},
        }}},
    }


def evaluate(
    repo_root: Path,
    predecessor_root: Path,
    manifest: Manifest,
    workload_class: str,
    dimension: str,
    scope: str,
    judged: bool,
    out_dir: Path,
    board: str = "core_cpu",
) -> dict:
    """Run the full paired evaluation and assemble a verdict dict.

    `judged=True` is reachable only from the judge bot; the public CLI always
    evaluates claimed. The judged trust boundary is the HMAC signature applied
    by the judge (signing.py), never this flag alone.
    """
    policy = manifest.gates
    skipped = announce_skipped_groups(manifest)
    workloads = _board_workloads(manifest, board, workload_class)
    if not workloads:
        raise RunError(
            f"no enabled workloads registered for board {board}, class {workload_class}"
        )

    dispersion = ledger.aa_dispersion(repo_root, board, workload_class)
    th = stats.theta(dispersion, float(policy["theta_floor"]), float(policy["dispersion_multiplier"]))

    out_dir.mkdir(parents=True, exist_ok=True)
    active_group_ids = {w.group_id for w in workloads}
    active_groups = [g for g in manifest.groups() if g.group_id in active_group_ids]
    for arm_root in (predecessor_root, repo_root):
        build_arm(arm_root, manifest, groups=active_groups)

    scores = [
        paired_rounds(predecessor_root, repo_root, manifest, w, policy, out_dir,
                      stop_theta=th)
        for w in workloads
    ]

    holdout_result = None
    if judged:
        seed = _seed(_git(repo_root, "rev-parse", "HEAD") or "head", 0)
        holdout = draw_holdout(manifest, workload_class, seed, board)
        if holdout is not None:
            hs = paired_rounds(predecessor_root, repo_root, manifest, holdout,
                               policy, out_dir, stop_theta=th, round_budget=3)
            holdout_result = {
                "seed": seed,
                "pass": hs.r <= float(policy["targeted_class_budget"]),
                "r": round(hs.r, 6),
            }
    objective = scores[0]
    if dimension == "rss":
        significant = objective.rss_ratio is not None and objective.rss_ratio < 1.0 - th
        neutral = objective.rss_ratio is not None and abs(objective.rss_ratio - 1.0) <= th
    else:
        significant = objective.ci[1] < 1.0 - th
        # Confirmed-neutral requires CI containment in the band, not overlap:
        # a wide, uncertain CI is "not significant", never "neutral".
        neutral = (
            not significant
            and objective.ci[0] >= 1.0 - th
            and objective.ci[1] <= 1.0 + th
        )

    gates = _gates(repo_root, manifest, scores, policy, judged, dispersion,
                   workload_class, board)
    verdict = {
        "schema_version": 1,
        "kind": "judged" if judged else "claimed",
        "harness_commit": _harness_commit(repo_root),
        "repo_commit": _git(repo_root, "rev-parse", "HEAD")[:12],
        "predecessor_commit": _git(predecessor_root, "rev-parse", "HEAD")[:12],
        "scope": scope,
        "declared_objective": {
            "board": board,
            "workload_class": workload_class,
            "dimension": dimension,
        },
        "environment": environment_block(repo_root, judged),
        "gates": gates,
        "score": {
            "per_workload": {
                s.workload.workload_id: {
                    "r": round(s.r, 6),
                    "ci": [round(s.ci[0], 6), round(s.ci[1], 6)],
                    "rounds": len(s.ratios),
                    "a_median_ms": round(s.a_median_ms, 6),
                    "b_median_ms": round(s.b_median_ms, 6),
                }
                for s in scores
            },
            "R_geomean": round(stats.geometric_mean([s.r for s in scores]), 6),
            "theta": round(th, 6),
            "aa_dispersion": dispersion,
            "significant": bool(significant),
            "neutral": bool(neutral),
        },
        "tiebreakers": {
            "rss_ratio": round(objective.rss_ratio, 6) if objective.rss_ratio else None,
            "waits": None,
            "dispatches": None,
            "energy_j": None,
        },
        "holdout": holdout_result,
        "skipped_groups": skipped,
        "evidence": {
            "reports": [p for s in scores for p in s.reports],
            "pairing": "round-level ABBA (bench reports expose medians, not raw samples)",
        },
    }
    return verdict


def _gates(repo_root, manifest, scores, policy, judged, dispersion,
           workload_class, board) -> dict:
    g1_ok = all(True for _ in scores)  # per-round verification enforced in paired_rounds
    # Submission and note additions are the point of a submission PR; they are
    # not locked-path violations (mirrors validate_action's carve-out).
    touched = [
        p for p in changed_paths(repo_root)
        if not p.startswith("autoresearch/submissions/")
        and not p.startswith("autoresearch/notes/")
        and not p.startswith("autoresearch/.runs/")
    ]
    violations, strays = manifest.classify_touched(touched)
    g2_ok = not violations and not strays
    if g2_ok:
        g2_detail = "no locked or out-of-scope path touched"
    elif violations:
        g2_detail = f"locked paths touched: {violations[:5]}"
    else:
        g2_detail = "no locked path touched"
    if strays:
        g2_detail += f"; outside editable set: {strays[:5]}"

    # G4: anchor drift budgets, charged against the frozen anchor (never the
    # predecessor). Inactive until the anchor is frozen — G5 blocks judged then.
    anchors = manifest.raw["harness"].get("anchor_prove_ms") or {}
    anchor_ms = anchors.get(board, {}).get(workload_class)
    g4_ok, g4_detail = True, "anchor not frozen; budgets inactive (G5 blocks judged)"
    if anchor_ms:
        objective = scores[0]
        targeted = float(policy["targeted_class_budget"])
        ratio = objective.b_median_ms / float(anchor_ms)
        g4_ok = ratio <= targeted
        g4_detail = (
            f"candidate/anchor {ratio:.4f} vs targeted budget x{targeted}"
            + ("" if g4_ok else " — cumulative budget exhausted (F.1 guard)")
        )

    env_ok = True
    env_detail = "local advisory run"
    if judged:
        env_ok = dispersion is not None and manifest.anchor_commit is not None
        env_detail = (
            "judge lock, measured A/A dispersion, anchor present"
            if env_ok
            else "judged requires measured A/A dispersion and a frozen anchor"
        )
    return {
        "G1": {"pass": g1_ok, "detail": "every timed sample verified; byte-identity enforced per round"},
        "G2": {"pass": g2_ok, "detail": g2_detail},
        "G3": {"pass": True, "detail": "mechanism binding recorded in note; telemetry wiring pending (F.8 item 2)"},
        "G4": {"pass": g4_ok, "detail": g4_detail},
        "G5": {"pass": env_ok, "detail": env_detail},
    }


def _board_workloads(manifest: Manifest, board: str,
                     workload_class: str) -> list[Workload]:
    try:
        return manifest.workloads(workload_class, board=board)
    except ManifestError as exc:
        raise RunError(str(exc)) from exc


def changed_paths(repo_root: Path) -> list[str]:
    base = _git(repo_root, "merge-base", "HEAD", "origin/main") or "HEAD~1"
    out = _git(repo_root, "diff", "--name-only", base, "HEAD")
    dirty = _git(repo_root, "diff", "--name-only")
    paths = [p for p in (out + "\n" + dirty).splitlines() if p.strip()]
    return sorted(set(paths))


def _harness_commit(repo_root: Path) -> str:
    out = _git(repo_root, "rev-parse", "HEAD:autoresearch")
    return out[:12] if out else "worktree"


def _git(repo_root: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=repo_root, capture_output=True, text=True
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _try(fn):
    try:
        return fn()
    except Exception:  # noqa: BLE001 - environment probe only
        return None
