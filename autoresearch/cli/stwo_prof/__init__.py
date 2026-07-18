"""stwo-prof: isolation and profiling tools for autoresearch.

Two lanes, two skills:
  zig   — isolate a workload into a scratch harness, measure instructions/
          cycles/IPC/energy in-process (proc_pid_rusage), sample stacks,
          summarize codegen, and A/B-compare candidates.
  metal — run an isolated kernel through the generic runner, read GPU time
          and pipeline reflection, and wrap Metal System Trace captures.

Companion skills: autoresearch/skills/{zig,metal}-profiling/SKILL.md.
"""

__version__ = "0.1.0"
