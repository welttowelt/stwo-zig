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


def frontier_view(rows: list[ledger.Row], classes: list[str],
                  anchors: dict, budgets: tuple[float, float]) -> str:
    lines = [ansi.rule("promotions ledger · Pareto frontier")]
    if not rows:
        lines.append(ansi.style("  ledger is empty — no judged promotions yet", "dim"))
    for cls in classes:
        v = frontier.view(rows, cls)
        lines.append("")
        lines.append(ansi.style(f"  {cls}", "bold"))
        if not v.head:
            lines.append(ansi.style("    no promoted rows", "dim"))
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
        anchor_ms = anchors.get(cls)
        if anchor_ms:
            drift = frontier.drift_vs_anchor(rows, cls, float(anchor_ms), budgets[1], budgets[0])
            if drift["ratio"] is not None:
                mark = ansi.gate_mark(drift["within_matrix"])
                lines.append(
                    f"    anchor drift {ansi.ratio(drift['ratio'])} {mark} "
                    f"(budgets: targeted x{budgets[0]}, matrix x{budgets[1]})"
                )
    return "\n".join(lines)


def benchmark_summary(manifest_raw: dict) -> str:
    reg = manifest_raw["workload_registry"]
    rows = [
        [wid, spec["class"], spec["native_unit"], spec["args"].split(" --warmups")[0]]
        for wid, spec in reg["workloads"].items()
    ]
    parts = [
        ansi.rule("fixed benchmark · stwo-zig native proof matrix"),
        ansi.table(["workload", "class", "native unit", "invocation"], rows),
        "",
        ansi.style(f"  build: {reg['build_step']}", "dim"),
        ansi.style("  gates: G1 conformance · G2 identity · G3 mechanism · G4 budgets · G5 environment", "dim"),
    ]
    return "\n".join(parts)
