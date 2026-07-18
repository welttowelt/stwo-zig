"""stwo-perf command surface (playbook F.3). Thin root: parse, dispatch, exit."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import __version__, ansi, config, ledger, manifest as manifest_mod, notes, render
from .github_auth import AuthError, device_login, whoami


def _fail(message: str) -> int:
    print(f"{ansi.style('error:', 'red', 'bold')} {message}", file=sys.stderr)
    return 1


def cmd_benchmark(_args) -> int:
    m = manifest_mod.load()
    print(render.benchmark_summary(m.raw))
    rows = ledger.load(m.root)
    print()
    print(f"  {len(rows)} judged promotion(s) in the ledger · epoch {ledger.current_epoch(m.root)['epoch']}")
    return 0


def cmd_frontier(_args) -> int:
    m = manifest_mod.load()
    rows = ledger.load(m.root)
    gates = m.gates
    anchors = m.raw["harness"].get("anchor_prove_ms") or {}
    print(render.frontier_view(rows, list(ledger.BOARDS), ["small", "wide", "deep"], anchors,
                               (gates["targeted_class_budget"], gates["matrix_row_budget"])))
    if m.anchor_commit is None:
        print()
        print(ansi.style("  anchor not frozen — drift budgets inactive, judged promotion disabled", "yellow"))
    return 0


def cmd_clone(args) -> int:
    from . import workspace
    m = manifest_mod.load()
    dest = workspace.clone(m.root, Path(args.dest))
    print(f"{ansi.OK} workspace created at {dest}")
    print(f"  next: cd {dest} && stwo-perf setup")
    return 0


def cmd_setup(_args) -> int:
    from . import workspace
    m = manifest_mod.load()
    built = workspace.setup(m.root, m)
    print(f"{ansi.OK} toolchain verified; bench targets built for group(s): "
          + ", ".join(built))
    return 0


def cmd_run(args) -> int:
    from . import runner
    m = manifest_mod.load()
    out_dir = m.root / "autoresearch" / ".runs" / "latest"
    if args.aa:
        try:
            result = runner.evaluate_aa(
                m.root, m, args.workload_class, out_dir, board=args.board,
            )
        except runner.RunError as exc:
            return _fail(str(exc))
        print(ansi.kv_panel("A/A dispersion", [
            ("class", result["workload_class"]),
            ("board", result["board"]),
            ("workload", result["workload"]),
            ("rounds", str(result["rounds"])),
            ("A/A r", f"{result['aa_r']}"),
            ("CI half-width", ansi.style(f"{result['half_width']}", "bold")),
        ]))
        print()
        print("  record it: set aa_dispersion." + result["board"] + "."
              + result["workload_class"]
              + f" = {result['half_width']} in ledger/epochs.json via a reviewed PR")
        return 0
    if args.scope == "s2":
        return _fail("s2 is diagnostic-only; run s1 for kernels or s3+ for acceptance")
    predecessor = Path(args.predecessor).resolve() if args.predecessor else None
    if predecessor is None:
        return _fail(
            "--predecessor <worktree> is required: scoring is paired two-arm by "
            "contract (frozen reports are provenance, never a denominator)"
        )
    try:
        # The public CLI only ever evaluates claimed verdicts; judged runs are
        # minted exclusively by the judge bot, which signs them (signing.py).
        verdict = runner.evaluate(
            m.root, predecessor, m, args.workload_class, args.dimension,
            args.scope, judged=False, out_dir=out_dir, board=args.board,
        )
    except runner.RunError as exc:
        return _fail(str(exc))
    out = Path(args.out) if args.out else out_dir / "verdict.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(verdict, indent=2) + "\n")
    print(render.verdict(verdict))
    print()
    print(ansi.style(f"  verdict written to {out}", "dim"))
    return 0


def cmd_submit(args) -> int:
    from . import submitter
    m = manifest_mod.load()
    try:
        sub_dir = submitter.package(
            m.root, m, args.slug, Path(args.note_file), Path(args.verdict),
            Path(args.transcripts) if args.transcripts else None, args.model,
        )
    except submitter.SubmitError as exc:
        return _fail(str(exc))
    print(f"{ansi.OK} submission packaged: {sub_dir.relative_to(m.root)}")
    print("  next: commit the submission directory and your editable-path diff on a")
    print("  branch, then open a PR labeled 'submission'. The judge re-runs before")
    print("  anything lands; your claimed verdict is advisory.")
    return 0


def cmd_submissions(_args) -> int:
    m = manifest_mod.load()
    subs = sorted(
        (p for p in (m.root / "autoresearch" / "submissions").iterdir() if p.is_dir()),
        reverse=True,
    )
    styles = {"promoted": "iris", "neutral": "yellow", "rejected": "red"}
    rows = []
    ledger_by_sub = {r.submission_id: r for r in ledger.load(m.root)}
    for sub in subs:
        row = ledger_by_sub.get(sub.name)
        if row:
            outcome = str(row.values.get("outcome", "rejected"))
            state = ansi.style(outcome, styles.get(outcome, "red"))
        else:
            state = ansi.style("pending", "yellow")
        rows.append([sub.name, state, f"{row.judged_r:.4f}" if row else "—"])
    if not rows:
        print(ansi.style("no submissions yet", "dim"))
        return 0
    print(ansi.table(["submission", "state", "judged r"], rows))
    return 0


def cmd_submission_note(args) -> int:
    m = manifest_mod.load()
    matches = [
        p for p in (m.root / "autoresearch" / "submissions").iterdir()
        if p.is_dir() and p.name.startswith(args.prefix)
    ]
    if len(matches) != 1:
        return _fail(f"prefix matches {len(matches)} submissions; be more specific")
    print((matches[0] / "note.md").read_text())
    return 0


def cmd_notes(args) -> int:
    m = manifest_mod.load()
    if args.notes_cmd == "add":
        body = Path(args.note_file).read_text() if args.note_file else (args.note or "")
        if not body:
            return _fail("provide --note-file or --note")
        try:
            path = notes.add(m.root, args.title, body)
        except notes.NoteError as exc:
            return _fail(str(exc))
        print(f"{ansi.OK} note written: {path.relative_to(m.root)}")
        print("  commit it (or include it in your next PR) to share it")
        return 0
    found = (
        notes.search(m.root, args.query, args.author)
        if args.notes_cmd == "search"
        else notes.list_notes(m.root, args.author)
    )
    if not found:
        print(ansi.style("no notes found", "dim"))
        return 0
    for n in found[: args.limit]:
        print(ansi.rule(n.title))
        print(ansi.style(f"  {n.author} · {n.created_utc}", "dim"))
        print()
        print(n.body.strip())
        print()
    return 0


def cmd_sync(args) -> int:
    from . import frontier as frontier_mod, workspace
    m = manifest_mod.load()
    rows = ledger.load(m.root)
    heads = [
        frontier_mod.view(rows, cls).head
        for cls in ("small", "wide", "deep")
    ]
    heads = [h for h in heads if h is not None]
    promoted = max(heads, key=lambda h: str(h.judged_at_utc)).commit if heads else None
    try:
        restored = workspace.sync(m.root, m, promoted, force=args.force)
    except workspace.WorkspaceError as exc:
        return _fail(str(exc))
    source = promoted or "default-branch tip (ledger empty)"
    print(f"{ansi.OK} harness at tip; editable sets restored from {source}:")
    for spec in restored:
        print(f"   {ansi.ARROW} {spec}")
    return 0


def cmd_reset(args) -> int:
    from . import workspace
    m = manifest_mod.load()
    try:
        workspace.restore_editable_from(m.root, m, args.commit, force=args.force)
    except workspace.WorkspaceError as exc:
        return _fail(str(exc))
    print(f"{ansi.OK} editable paths restored from {args.commit}; harness stays at tip")
    return 0


def cmd_login(args) -> int:
    client_id = args.client_id or config.get("github_client_id")
    if not client_id:
        return _fail("pass --client-id once (stored) or set github_client_id in config")
    try:
        token = device_login(client_id)
        user = whoami(token)
    except AuthError as exc:
        return _fail(str(exc))
    config.set_value("github_client_id", client_id)
    config.set_value("github_token", token)
    print(f"{ansi.OK} logged in as {ansi.style(user, 'bold')} (token stored, chmod 600)")
    return 0


def cmd_apikey(_args) -> int:
    import urllib.request
    token = config.github_token()
    if not token:
        return _fail("login first: stwo-perf login")
    req = urllib.request.Request(
        f"{config.api_url()}/v1/keys",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except OSError as exc:
        return _fail(f"backend unreachable at {config.api_url()}: {exc}")
    config.set_value("api_key", data["key"])
    print(f"{ansi.OK} API key issued for {data['login']} and stored")
    return 0


def cmd_config(args) -> int:
    if args.set:
        key, _, value = args.set.partition("=")
        if not value:
            return _fail("use --set key=value")
        config.set_value(key.strip(), value.strip())
        print(f"{ansi.OK} {key.strip()} updated")
        return 0
    data = config.load()
    redacted = {
        k: (v[:6] + "…" if isinstance(v, str) and ("token" in k or "key" in k) else v)
        for k, v in data.items()
    }
    print(ansi.kv_panel("config", [(k, str(v)) for k, v in sorted(redacted.items())] or [("(empty)", "")]))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="stwo-perf",
        description="Autoresearch harness for stwo-zig: judged scoring under "
                    "oracle-parity gates, submissions, and the promotions ledger.",
    )
    parser.add_argument("--version", action="version", version=f"stwo-perf {__version__}")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("benchmark", help="show the fixed suite, gates, and ledger state")
    sub.add_parser("frontier", help="print the promotions ledger and Pareto frontier")

    p = sub.add_parser("clone", help="create a searcher workspace (git worktree)")
    p.add_argument("dest")

    sub.add_parser("setup", help="verify toolchain and build the bench target")

    p = sub.add_parser("run", help="paired reward evaluation; emits a claimed verdict")
    p.add_argument("--scope", choices=["s1", "s2", "s3", "s4", "s5"], default="s3")
    p.add_argument("--class", dest="workload_class", choices=["small", "wide", "deep"],
                   default="small")
    p.add_argument("--dimension", choices=["time", "rss", "energy"], default="time")
    p.add_argument("--board", default="core_cpu",
                   choices=["core_cpu", "core_hybrid", "core_metal",
                            "heavy_native", "heavy_cairo", "stream", "riscv"],
                   help="scoring board (schema/scoring.md); kernels are never boards")
    p.add_argument("--predecessor", help="worktree of the paired A arm (required)")
    p.add_argument("--aa", action="store_true",
                   help="A/A dispersion measurement (both arms = this tree)")
    p.add_argument("--out", help="verdict output path")

    p = sub.add_parser("submit", help="package a submission directory")
    p.add_argument("--slug", required=True)
    p.add_argument("--note-file", required=True)
    p.add_argument("--verdict", required=True, help="claimed verdict.json from `run`")
    p.add_argument("--transcripts", help="directory of redacted session transcripts")
    p.add_argument("--model", required=True, help='e.g. "Claude Fable 5"')

    sub.add_parser("submissions", help="list submissions and their judged state")

    p = sub.add_parser("submission-note", help="print a submission's note")
    p.add_argument("prefix")

    p = sub.add_parser("notes", help="standalone working notes")
    ns = p.add_subparsers(dest="notes_cmd", required=True)
    pa = ns.add_parser("add")
    pa.add_argument("--title", required=True)
    pa.add_argument("--note-file")
    pa.add_argument("--note")
    for name in ("list", "search"):
        pl = ns.add_parser(name)
        if name == "search":
            pl.add_argument("query")
        pl.add_argument("--author")
        pl.add_argument("--limit", type=int, default=5)

    p = sub.add_parser("sync", help="fast-forward workspace to the promoted frontier")
    p.add_argument("--force", action="store_true")
    p = sub.add_parser("reset", help="restore editable paths from a promoted commit")
    p.add_argument("commit")
    p.add_argument("--force", action="store_true")

    p = sub.add_parser("login", help="GitHub device-flow login")
    p.add_argument("--client-id")
    sub.add_parser("apikey", help="issue an API key from the backend")
    p = sub.add_parser("config", help="show or set CLI configuration")
    p.add_argument("--set", metavar="KEY=VALUE")
    sub.add_parser("install-workflows",
                   help="copy autoresearch/workflows/*.yml into .github/workflows/")
    p = sub.add_parser("feed", help="compile the deterministic site feed (repo->website contract)")
    p.add_argument("--out", help="output path (default autoresearch/site/feed.json)")
    p.add_argument("--allow-dirty", action="store_true",
                   help="permit uncommitted input changes (feed is marked dirty; never publish)")
    return parser


def cmd_feed(args) -> int:
    from . import feed
    m = manifest_mod.load()
    try:
        out = feed.write_feed(m, Path(args.out) if args.out else None,
                              allow_dirty=args.allow_dirty)
    except feed.FeedError as exc:
        return _fail(str(exc))
    if args.allow_dirty:
        print(ansi.style("  ⚠ dirty inputs allowed — feed is marked dirty and "
                         "must not be published", "yellow"))
    data = json.loads(out.read_text())
    latest = data.get("latest_matrix") or {}
    print(f"{ansi.OK} feed written: {out.relative_to(m.root)}")
    print(ansi.kv_panel("feed", [
        ("schema", str(data["feed_schema_version"])),
        ("commit", str(data["provenance"]["repo_commit"])),
        ("boards", str(sum(1 for b in data["boards"].values() if b["entries"]))
                   + f"/{len(data['boards'])} populated"),
        ("latest matrix", str(latest.get("run_id", "none"))),
        ("matrix rows", str(len(latest.get("rows", [])))),
        ("submissions", str(len(data["submissions"]))),
    ]))
    return 0


def cmd_install_workflows(_args) -> int:
    import shutil
    m = manifest_mod.load()
    dest = m.root / ".github" / "workflows"
    dest.mkdir(parents=True, exist_ok=True)
    copied = []
    for src in sorted((m.root / "autoresearch" / "workflows").glob("*.yml")):
        shutil.copy2(src, dest / src.name)
        copied.append(src.name)
    print(f"{ansi.OK} copied into .github/workflows/: {', '.join(copied)}")
    print("  commit via normal review; require 'autoresearch-validate' AND")
    print("  'autoresearch-judge' as branch-protection checks on main")
    return 0


HANDLERS = {
    "benchmark": cmd_benchmark, "frontier": cmd_frontier, "clone": cmd_clone,
    "setup": cmd_setup, "run": cmd_run, "submit": cmd_submit,
    "submissions": cmd_submissions, "submission-note": cmd_submission_note,
    "notes": cmd_notes, "sync": cmd_sync, "reset": cmd_reset,
    "login": cmd_login, "apikey": cmd_apikey, "config": cmd_config,
    "install-workflows": cmd_install_workflows, "feed": cmd_feed,
}


def main(argv: list[str] | None = None) -> int:
    from . import workspace
    args = build_parser().parse_args(argv)
    try:
        return HANDLERS[args.cmd](args)
    except KeyboardInterrupt:
        print()
        return 130
    except manifest_mod.ManifestError as exc:
        return _fail(str(exc))
    except ledger.LedgerError as exc:
        return _fail(str(exc))
    except workspace.WorkspaceError as exc:
        return _fail(str(exc))
    except json.JSONDecodeError as exc:
        return _fail(f"invalid JSON: {exc}")
    except OSError as exc:
        return _fail(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
