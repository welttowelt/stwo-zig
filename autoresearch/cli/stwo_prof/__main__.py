"""stwo-prof command surface. Companion skills document the methodology."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from stwo_perf import ansi

from . import __version__, metaltools, scaffold, zigtools


def _fail(message: str) -> int:
    print(f"{ansi.style('error:', 'red', 'bold')} {message}", file=sys.stderr)
    return 1


def _panel(title: str, data: dict, keys: list[tuple[str, str]]) -> None:
    pairs = []
    for label, key in keys:
        value = data.get(key)
        if value is not None:
            pairs.append((label, f"{value:,.4g}" if isinstance(value, float) else str(value)))
    print(ansi.kv_panel(title, pairs))


def cmd_zig_isolate(args) -> int:
    source = Path(args.source) if args.source else None
    dest = scaffold.isolate_zig(args.name, source)
    print(f"{ansi.OK} scratch harness: {dest}")
    print(f"  edit {dest}/workload.zig (contract in the file header), then:")
    print(f"  stwo-prof zig run {args.name}")
    return 0


def cmd_zig_run(args) -> int:
    bench = scaffold.resolve(args.name)
    summary = zigtools.run_counters(bench, iters=args.iters, rounds=args.rounds,
                                    debug=args.debug)
    _panel(f"zig counters · {bench.name}", summary, [
        ("ns/op (median)", "ns_per_op"),
        ("ns/op (min)", "ns_per_op_min"),
        ("instructions/op", "instructions_per_op"),
        ("cycles/op", "cycles_per_op"),
        ("IPC", "ipc"),
        ("energy/round (nJ)", "energy_nj_median_round"),
        ("peak footprint (B)", "peak_footprint_bytes"),
    ])
    if "note" in summary:
        print(ansi.style(f"  {summary['note']}", "yellow"))
    if args.json:
        out = bench / "counters.json"
        out.write_text(json.dumps(summary, indent=1) + "\n")
        print(ansi.style(f"  written to {out}", "dim"))
    return 0


def cmd_zig_compare(args) -> int:
    result = zigtools.compare(scaffold.resolve(args.a), scaffold.resolve(args.b),
                              iters=args.iters, rounds=args.rounds)
    print(ansi.rule(f"A/B · {args.a} vs {args.b}"))
    ratio = result["wall_ratio_b_over_a"]
    lo, hi = result["wall_ratio_ci95"]
    print(f"  wall  B/A {ansi.ratio(ratio)}  CI95 [{lo}, {hi}]")
    if "instruction_ratio_b_over_a" in result:
        print(f"  instr B/A {ansi.ratio(result['instruction_ratio_b_over_a'])}"
              f"   cycles B/A {ansi.ratio(result['cycle_ratio_b_over_a'])}")
    print(ansi.style(
        f"  A {result['a_ns_per_op']:.3f} ns/op · B {result['b_ns_per_op']:.3f} ns/op", "dim"))
    return 0


def cmd_zig_asm(args) -> int:
    summary = zigtools.asm_summary(scaffold.resolve(args.name), args.symbol)
    rows = [
        [name, str(s["instructions"]), f"{s['neon_pct']}%", str(s["branches"]), str(s["memory"])]
        for name, s in sorted(summary["symbols"].items(),
                              key=lambda kv: -kv[1]["instructions"])
    ][:args.top]
    print(ansi.table(["symbol", "instrs", "neon", "branches", "mem"], rows, aligns="lrrrr"))
    print(ansi.style(f"  full listing: {summary['asm_file']}", "dim"))
    return 0


def cmd_zig_sample(args) -> int:
    report = zigtools.sample_stacks(scaffold.resolve(args.name),
                                    seconds=args.seconds, iters=args.iters)
    out = scaffold.resolve(args.name) / "sample.txt"
    out.write_text(report)
    for line in report.splitlines():
        if "bench" in line and ("workload" in line or "main" in line):
            print(line)
    print(f"{ansi.OK} full stack report: {out}")
    return 0


def cmd_metal_isolate(args) -> int:
    source = Path(args.source) if args.source else None
    dest = scaffold.isolate_metal(args.name, source)
    print(f"{ansi.OK} scratch kernel dir: {dest}")
    print(f"  edit {dest}/kernel.metal, then:")
    print(f"  stwo-prof metal run {args.name} --entry <kernel name>")
    return 0


def cmd_metal_run(args) -> int:
    bench = scaffold.resolve(args.name)
    kernel = bench / "kernel.metal" if bench.is_dir() else bench
    result = metaltools.run_kernel(kernel, args.entry, grid=args.grid, tg=args.tg,
                                   iters=args.iters, buffers=args.buffers)
    _panel(f"metal · {args.entry}", result, [
        ("GPU ms (median)", "gpu_ms_median"),
        ("GPU ms (min)", "gpu_ms_min"),
        ("~GB/s touched", "approx_gb_per_s"),
        ("grid", "grid"),
        ("threadgroup", "threadgroup"),
    ])
    pso = result.get("pipeline", {})
    print(ansi.style(
        f"  PSO: maxThreads {pso.get('max_total_threads_per_threadgroup')} · "
        f"width {pso.get('thread_execution_width')} · "
        f"tg-mem {pso.get('static_threadgroup_memory_bytes')} B", "dim"))
    if args.json:
        out = (bench if bench.is_dir() else bench.parent) / "metal.json"
        out.write_text(json.dumps(result, indent=1) + "\n")
        print(ansi.style(f"  written to {out}", "dim"))
    return 0


def cmd_metal_caps(_args) -> int:
    data = metaltools.caps()
    print(ansi.kv_panel("metal device", [(k, str(v)) for k, v in sorted(data.items())]))
    return 0


def cmd_metal_trace(args) -> int:
    output = Path(args.output)
    metaltools.trace(args.command, output)
    print(f"{ansi.OK} trace written: {output} (open in Instruments)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="stwo-prof",
        description="Isolation and profiling tools for autoresearch "
                    "(skills: autoresearch/skills/{zig,metal}-profiling).",
    )
    parser.add_argument("--version", action="version", version=f"stwo-prof {__version__}")
    sub = parser.add_subparsers(dest="lane", required=True)

    zig = sub.add_parser("zig", help="CPU profiling lane")
    zs = zig.add_subparsers(dest="cmd", required=True)
    p = zs.add_parser("isolate", help="create a scratch bench harness")
    p.add_argument("name")
    p.add_argument("--from", dest="source", help="seed workload.zig from a file")
    p = zs.add_parser("run", help="build + run with in-process hardware counters")
    p.add_argument("name")
    p.add_argument("--iters", type=int, default=2000)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--debug", action="store_true")
    p.add_argument("--json", action="store_true")
    p = zs.add_parser("compare", help="ABBA A/B of two harnesses")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--iters", type=int, default=2000)
    p.add_argument("--rounds", type=int, default=7)
    p = zs.add_parser("asm", help="codegen summary (instrs, NEON share, branches)")
    p.add_argument("name")
    p.add_argument("--symbol")
    p.add_argument("--top", type=int, default=12)
    p = zs.add_parser("sample", help="stack sampling via /usr/bin/sample")
    p.add_argument("name")
    p.add_argument("--seconds", type=int, default=5)
    p.add_argument("--iters", type=int, default=2_000_000)

    metal = sub.add_parser("metal", help="GPU profiling lane")
    ms = metal.add_subparsers(dest="cmd", required=True)
    p = ms.add_parser("isolate", help="create a scratch kernel dir")
    p.add_argument("name")
    p.add_argument("--from", dest="source")
    p = ms.add_parser("run", help="time a kernel via the generic runner")
    p.add_argument("name")
    p.add_argument("--entry", required=True)
    p.add_argument("--grid", type=int, default=1_048_576)
    p.add_argument("--tg", type=int, default=256)
    p.add_argument("--iters", type=int, default=50)
    p.add_argument("--buffers", default="f32:1048576,f32:1048576,f32:1048576")
    p.add_argument("--json", action="store_true")
    ms.add_parser("caps", help="device capabilities")
    p = ms.add_parser("trace", help="Metal System Trace around a command")
    p.add_argument("--output", default="stwo-prof.trace")
    p.add_argument("command", nargs=argparse.REMAINDER)
    return parser


HANDLERS = {
    ("zig", "isolate"): cmd_zig_isolate,
    ("zig", "run"): cmd_zig_run,
    ("zig", "compare"): cmd_zig_compare,
    ("zig", "asm"): cmd_zig_asm,
    ("zig", "sample"): cmd_zig_sample,
    ("metal", "isolate"): cmd_metal_isolate,
    ("metal", "run"): cmd_metal_run,
    ("metal", "caps"): cmd_metal_caps,
    ("metal", "trace"): cmd_metal_trace,
}


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return HANDLERS[(args.lane, args.cmd)](args)
    except KeyboardInterrupt:
        print()
        return 130
    except zigtools.ProfError as exc:
        return _fail(str(exc))
    except OSError as exc:
        return _fail(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
