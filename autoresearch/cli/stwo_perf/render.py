"""Human rendering of verdicts, frontier views, and submissions lists."""

from __future__ import annotations

from . import ansi, frontier, ledger


def verdict(v: dict) -> str:
    lines = [ansi.rule(f"stwo-perf verdict · {v['kind'].upper()}")]
    obj = v["declared_objective"]
    lines.append(
        ansi.kv_panel(
            "run",
            [
                ("candidate", v["repo_commit"]),
                ("predecessor", v["predecessor_commit"]),
                ("scope", v["scope"]),
                ("objective", f"{obj['workload_class']} / {obj['dimension']}"),
                ("harness", v["harness_commit"]),
            ],
        )
    )
    gate_rows = [
        [gid, ansi.gate_mark(g["pass"]), g["detail"]]
        for gid, g in v["gates"].items()
    ]
    lines.append("")
    lines.append(ansi.table(["gate", "", "detail"], gate_rows))
    score = v["score"]
    wl_rows = [
        [
            wid,
            ansi.ratio(s["r"]),
            f"[{s['ci'][0]:.4f}, {s['ci'][1]:.4f}]",
            str(s["rounds"]),
            f"{s['a_median_ms']:.3f}",
            f"{s['b_median_ms']:.3f}",
        ]
        for wid, s in score["per_workload"].items()
    ]
    lines.append("")
    lines.append(
        ansi.table(
            ["workload", "r", "95% CI", "rounds", "A ms", "B ms"],
            wl_rows,
            aligns="lrrrrr",
        )
    )
    lines.append("")
    outcome = (
        ansi.style("significant improvement", "iris", "bold")
        if score["significant"]
        else ansi.style("confirmed-neutral", "yellow")
        if score["neutral"]
        else ansi.style("not significant", "red")
    )
    lines.append(
        f"  R {ansi.ratio(score['R_geomean'])} · theta {score['theta']:.4f} · {outcome}"
    )
    if v["kind"] == "claimed":
        lines.append(ansi.style("  claimed verdict — advisory; only the judge's re-run counts", "dim"))
    return "\n".join(lines)


def frontier_view(
    rows: list[ledger.Row],
    boards: list[str],
    classes_by_board: dict[str, list[str]],
    anchors: dict,
    budgets: tuple[float, float],
) -> str:
    lines = [ansi.rule("promotions ledger · Pareto frontier")]
    if not rows:
        lines.append(ansi.style("  ledger is empty — no judged promotions yet", "dim"))
    for board in boards:
        lines.append("")
        lines.append(ansi.style(f"  board {board}", "bold"))
        for cls in classes_by_board.get(board, []):
            v = frontier.view(rows, board, cls)
            lines.append(ansi.style(f"    {cls}", "bold"))
            if not v.head:
                lines.append(ansi.style("      no promoted rows", "dim"))
                continue
            table_rows = [
                [
                    r.commit,
                    f"{r.prove_ms:.3f}",
                    f"{r.peak_rss_mib:.1f}",
                    f"{r.energy_j:.2f}" if r.energy_j is not None else "—",
                    ansi.style("frontier", "iris") if r in v.frontier else ansi.style("superseded", "dim"),
                    str(r.judged_at_utc)[:10],
                ]
                for r in (v.frontier + v.superseded)
            ]
            lines.append(
                ansi.table(
                    ["commit", "prove ms", "RSS MiB", "J", "state", "judged"],
                    table_rows,
                    aligns="lrrrll",
                )
            )
            anchor_ms = anchors.get(board, {}).get(cls)
            if anchor_ms:
                drift = frontier.drift_vs_anchor(
                    rows, board, cls, float(anchor_ms), budgets[1], budgets[0],
                )
                if drift["ratio"] is not None:
                    mark = ansi.gate_mark(drift["within_matrix"])
                    lines.append(
                        f"      anchor drift {ansi.ratio(drift['ratio'])} {mark} "
                        f"(budgets: targeted x{budgets[0]}, matrix x{budgets[1]})"
                    )
    return "\n".join(lines)


def benchmark_summary(manifest_raw: dict) -> str:
    reg = manifest_raw["workload_registry"]
    parts = [ansi.rule("fixed benchmark · stwo-zig proof matrix")]
    for gid, group in reg["groups"].items():
        enabled = bool(group.get("enabled"))
        header = f"  group {gid} · report schema {group.get('report_schema')}"
        parts.append("")
        if enabled:
            parts.append(ansi.style(header, "bold"))
        else:
            reason = group.get("disabled_reason") or "no reason recorded"
            parts.append(ansi.style(header + " · disabled", "yellow"))
            parts.append(ansi.style(f"  skipped group {gid}: {reason}", "yellow"))
        rows = [
            [wid, spec["class"], spec["native_unit"], spec["args"].split(" --warmups")[0]]
            for wid, spec in group["workloads"].items()
        ]
        parts.append(ansi.table(["workload", "class", "native unit", "invocation"], rows))
        parts.append(ansi.style(f"  build: {group['build_step']}", "dim"))
    parts.append("")
    parts.append(ansi.style("  gates: G1 conformance · G2 identity · G3 mechanism · G4 budgets · G5 environment", "dim"))
    return "\n".join(parts)
