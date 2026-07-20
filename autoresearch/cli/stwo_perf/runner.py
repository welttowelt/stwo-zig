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
    proof_digest: str | None = None
    request_ms: float | None = None


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
    proof_digest: str | None = None
    request_ratio: float | None = None
    report_sha256s: list[str] = field(default_factory=list)


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
    samples_meta = proof.get("samples") or []
    digest = samples_meta[0].get("sha256") if samples_meta else None
    request = report["timing"].get("request_seconds")
    request_ms = (
        float(request["median"]) * 1000.0
        if isinstance(request, dict) and request.get("median") is not None
        else None
    )
    return ArmResult(
        prove_ms=float(timing["median"]) * 1000.0,
        proof_verified=int(proof.get("verified_samples", 0)),
        byte_identical=bool(proof.get("all_samples_byte_identical", False)),
        peak_rss_mib=rss,
        report_path=str(out_path),
        proof_digest=digest,
        request_ms=request_ms,
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
    request_ratios: list[float] = []
    cross_digest: str | None = None

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
        # G1 conformance is CROSS-ARM: the candidate's proof bytes must equal
        # the predecessor's, per round, not merely be self-consistent per arm.
        if a.proof_digest and b.proof_digest and a.proof_digest != b.proof_digest:
            raise RunError(
                f"{workload.workload_id}: cross-arm proof digest mismatch in round "
                f"{round_no} (predecessor {a.proof_digest[:12]} vs candidate "
                f"{b.proof_digest[:12]}) — conformance failure"
            )
        if cross_digest is None:
            cross_digest = b.proof_digest
        elif b.proof_digest and b.proof_digest != cross_digest:
            raise RunError(
                f"{workload.workload_id}: proof digest changed between rounds — "
                f"nondeterministic proof bytes"
            )
        if a.request_ms and b.request_ms:
            request_ratios.append(b.request_ms / a.request_ms)
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
    request_ratio = (
        sorted(request_ratios)[len(request_ratios) // 2] if request_ratios else None
    )
    return WorkloadScore(
        workload=workload,
        ratios=ratios,
        r=r,
        ci=ci,
        a_median_ms=sorted(a_meds)[len(a_meds) // 2],
        b_median_ms=sorted(b_meds)[len(b_meds) // 2],
        rss_ratio=rss_ratio,
        reports=reports,
        proof_digest=cross_digest,
        request_ratio=request_ratio,
        report_sha256s=[
            hashlib.sha256(Path(rp).read_bytes()).hexdigest() for rp in reports
        ],
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


RUST_ORACLE_RELPATH = "tools/stwo-interop-rs/target/release/stwo-interop-rs"
RUST_ORACLE_TOOLCHAIN = "nightly-2025-07-14"


def rust_oracle_check(candidate_root: Path, manifest: Manifest,
                      workload: Workload, out_dir: Path) -> dict:
    """One pinned-Rust verification per scored workload: the candidate emits a
    proof artifact and the parity oracle must accept it. Fail-closed when the
    policy requires the oracle and it cannot run."""
    oracle = candidate_root / RUST_ORACLE_RELPATH
    if not oracle.is_file():
        _run(
            f"cargo +{RUST_ORACLE_TOOLCHAIN} build --release --locked "
            f"--manifest-path tools/stwo-interop-rs/Cargo.toml",
            candidate_root, timeout=1200,
        )
    group = manifest.group(workload.group_id)
    binary = candidate_root / group.binary
    artifact = out_dir / f"{workload.workload_id}.oracle-artifact.json"
    args = workload.args.format(warmups=0, samples=1)
    _run(f"{binary} {args} --proof-artifact-out {artifact}", candidate_root,
         timeout=600)
    if not artifact.is_file():
        raise RunError(
            f"{workload.workload_id}: bench did not write the oracle artifact"
        )
    _run(f"{oracle} --mode verify --artifact {artifact}", candidate_root,
         timeout=600)
    return {
        "workload": workload.workload_id,
        "verified": True,
        "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
    }


def guard_registry(manifest: Manifest) -> dict:
    return manifest.raw.get("workload_registry", {}).get("guards", {}) or {}


def select_guards(manifest: Manifest, touched: list[str],
                  objective_group: WorkloadGroup) -> list[Workload]:
    """Impact-mapped guard selection: generic prover/PCS/FFT/accumulation
    paths exercise every native AIR; an unmatched editable source path fails
    closed to every guard."""
    registry = guard_registry(manifest)
    workloads = registry.get("workloads", {})
    if not workloads:
        return []
    rules = registry.get("impact_map", {}).get("rules", [])
    selected: set[str] = set()
    source_paths = [p for p in touched if p.startswith("src/")]
    for path in source_paths:
        matched = False
        for rule in rules:
            if any(path.startswith(prefix) for prefix in rule.get("prefixes", [])):
                matched = True
                guards = rule.get("guards")
                if guards == "all":
                    selected.update(workloads)
                else:
                    selected.update(guards or [])
        if not matched:
            selected.update(workloads)  # unknown impact: run everything
    return [
        Workload(gid, "guard", spec["args"], spec.get("native_unit", ""),
                 objective_group.group_id)
        for gid, spec in sorted(workloads.items())
        if gid in selected
    ]


def run_guards(a_root: Path, b_root: Path, manifest: Manifest,
               guards: list[Workload], out_dir: Path) -> dict:
    """Paired ABBA regression guards: pass = upper CI bound <= budget; a guard
    straddling its budget after the base rounds resamples with extra rounds,
    then fails closed."""
    registry = guard_registry(manifest)
    policy = registry.get("policy", {})
    budget = float(policy.get("budget_upper", 1.05))
    guard_policy = {
        "warmups": int(policy.get("warmups", 5)),
        "samples_per_round": int(policy.get("samples_per_round", 2)),
        "min_rounds": int(policy.get("min_rounds", 3)),
        "max_rounds": int(policy.get("max_rounds", 8)),
        "theta_floor": max(budget - 1.0, 0.01),
        "wall_clock_cap_seconds": {"guard": 300},
    }
    extra = int(policy.get("inconclusive_extra_rounds", 4))
    results: dict[str, dict] = {}
    for guard in guards:
        score = paired_rounds(a_root, b_root, manifest, guard, guard_policy, out_dir)
        if score.ci[0] <= budget <= score.ci[1]:
            # Inconclusive vs the budget: continue sampling once, then decide.
            score = paired_rounds(
                a_root, b_root, manifest, guard, guard_policy, out_dir,
                round_budget=guard_policy["max_rounds"] + extra,
            )
        results[guard.workload_id] = {
            "r": round(score.r, 6),
            "ci": [round(score.ci[0], 6), round(score.ci[1], 6)],
            "rounds": len(score.ratios),
            "budget_upper": budget,
            "pass": score.ci[1] <= budget,
            "proof_digest": score.proof_digest,
        }
    return results


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
    holdout_seed: int | None = None,
    guards_mode: str = "auto",
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

    touched = changed_paths(repo_root)
    guard_results: dict = {}
    if guards_mode != "none":
        objective_group = manifest.group(workloads[0].group_id)
        if guards_mode == "all":
            registry = guard_registry(manifest).get("workloads", {})
            selected = [
                Workload(gid, "guard", spec["args"], spec.get("native_unit", ""),
                         objective_group.group_id)
                for gid, spec in sorted(registry.items())
            ]
        else:
            selected = select_guards(manifest, touched, objective_group)
        if selected:
            print(f"running {len(selected)} regression guard(s): "
                  + ", ".join(g.workload_id for g in selected))
            guard_results = run_guards(predecessor_root, repo_root, manifest,
                                       selected, out_dir)

    oracle_results: list[dict] = []
    if bool(policy.get("require_rust_oracle", False)):
        for w in workloads:
            oracle_results.append(rust_oracle_check(repo_root, manifest, w, out_dir))

    holdout_result = None
    if judged:
        seed = (
            holdout_seed
            if holdout_seed is not None
            else _seed(_git(repo_root, "rev-parse", "HEAD") or "head", 0)
        )
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
                   workload_class, board, guard_results, oracle_results)
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
        "guards": guard_results,
        "rust_oracle": oracle_results,
        "skipped_groups": skipped,
        "evidence": {
            "pairing": "round-level ABBA (bench reports expose medians, not raw samples)",
            "per_workload": {
                s.workload.workload_id: {
                    "round_ratios": [round(x, 6) for x in s.ratios],
                    "proof_digest": s.proof_digest,
                    "request_ratio": round(s.request_ratio, 6) if s.request_ratio else None,
                    "report_sha256s": s.report_sha256s,
                }
                for s in scores
            },
            "reports": [p for s in scores for p in s.reports],
        },
    }
    return verdict


def _gates(repo_root, manifest, scores, policy, judged, dispersion,
           workload_class, board, guard_results=None, oracle_results=None) -> dict:
    guard_results = guard_results or {}
    oracle_results = oracle_results or []
    # Per-round verification, per-round CROSS-ARM digest equality, and digest
    # constancy are enforced in paired_rounds (a violation raises, so reaching
    # here means they held); the pinned-Rust oracle results land in the detail.
    g1_ok = True
    if bool(policy.get("require_rust_oracle", False)):
        g1_ok = len(oracle_results) == len(scores) and all(
            o.get("verified") for o in oracle_results
        )
    oracle_note = (
        f"; pinned Rust oracle verified {sum(1 for o in oracle_results if o.get('verified'))}/{len(scores)} workloads"
        if policy.get("require_rust_oracle", False)
        else "; rust oracle not required by policy"
    )
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
    g4_ok, g4_details = True, []
    if anchor_ms and scores:
        objective = scores[0]
        targeted = float(policy["targeted_class_budget"])
        ratio = objective.b_median_ms / float(anchor_ms)
        anchor_ok = ratio <= targeted
        g4_ok = g4_ok and anchor_ok
        g4_details.append(
            f"candidate/anchor {ratio:.4f} vs targeted budget x{targeted}"
            + ("" if anchor_ok else " — cumulative budget exhausted (F.1 guard)")
        )
    else:
        g4_details.append("anchor not frozen; drift budget inactive")
    guards_failed = [g for g, res in guard_results.items() if not res.get("pass")]
    if guard_results:
        g4_ok = g4_ok and not guards_failed
        g4_details.append(
            f"regression guards {len(guard_results) - len(guards_failed)}/{len(guard_results)} within budget"
            + (f" — FAILED: {guards_failed[:4]}" if guards_failed else "")
        )
    objective = scores[0] if scores else None
    request_budget = float(policy.get("request_budget", 0) or 0)
    if objective and request_budget and objective.request_ratio is not None:
        request_ok = objective.request_ratio <= request_budget
        g4_ok = g4_ok and request_ok
        g4_details.append(
            f"request ratio {objective.request_ratio:.4f} vs budget x{request_budget}"
            + ("" if request_ok else " — request-time regression")
        )
    rss_budget = float(policy.get("rss_budget", 0) or 0)
    if objective and rss_budget and objective.rss_ratio is not None:
        rss_ok = objective.rss_ratio <= rss_budget
        g4_ok = g4_ok and rss_ok
        g4_details.append(
            f"rss ratio {objective.rss_ratio:.4f} vs budget x{rss_budget}"
            + ("" if rss_ok else " — memory regression")
        )
    g4_detail = "; ".join(g4_details)

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
        "G1": {"pass": g1_ok, "detail": "every timed sample verified; cross-arm proof digests byte-identical per round" + oracle_note},
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
