import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_prof import scaffold, zigtools


class ScaffoldTest(unittest.TestCase):
    def test_isolate_zig_creates_contract_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            import os
            os.environ["STWO_PROF_SCRATCH"] = tmp
            try:
                dest = scaffold.isolate_zig("t1", None)
                for name in ("workload.zig", "main.zig", "build.zig"):
                    self.assertTrue((dest / name).exists(), name)
                # the fold-trap defence is part of the contract
                self.assertIn("run(seed: u64)", (dest / "workload.zig").read_text())
                self.assertIn("proc_pid_rusage", (dest / "main.zig").read_text())
            finally:
                del os.environ["STWO_PROF_SCRATCH"]

    def test_isolate_preserves_existing_workload(self):
        with tempfile.TemporaryDirectory() as tmp:
            import os
            os.environ["STWO_PROF_SCRATCH"] = tmp
            try:
                dest = scaffold.isolate_zig("t2", None)
                (dest / "workload.zig").write_text("// custom\n")
                scaffold.isolate_zig("t2", None)
                self.assertEqual((dest / "workload.zig").read_text(), "// custom\n")
            finally:
                del os.environ["STWO_PROF_SCRATCH"]


ASM_FIXTURE = """\t.section __TEXT,__text
_hot_kernel:
\tld1 { v0.4s }, [x0]
\tmul v1.4s, v0.4s, v0.4s
\tst1 { v1.4s }, [x1]
\tadd x2, x2, #1
\tcmp x2, x3
\tb.lo _hot_kernel
\tret
"_scalar.helper":
\tadd x0, x0, x1
\tret
lTmp0:
\t.long 0
"""


class AsmSummaryTest(unittest.TestCase):
    def test_summary_counts_neon_branches_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            bench = Path(tmp)
            (bench / "bench.s").write_text(ASM_FIXTURE)
            # bypass the build step: parse the fixture directly
            original = zigtools._run
            zigtools._run = lambda *a, **k: None
            try:
                summary = zigtools.asm_summary(bench)
            finally:
                zigtools._run = original
            hot = summary["symbols"]["_hot_kernel"]
            self.assertEqual(hot["instructions"], 7)
            self.assertEqual(hot["neon"], 3)
            self.assertEqual(hot["branches"], 2)  # b.lo + ret
            self.assertEqual(hot["memory"], 2)  # ld1 + st1
            self.assertIn("_scalar.helper", summary["symbols"])
            self.assertNotIn("lTmp0", summary["symbols"])


class ResolveTest(unittest.TestCase):
    def test_resolve_prefers_paths_then_scratch(self):
        self.assertEqual(scaffold.resolve("./x/y"), Path("./x/y"))
        resolved = scaffold.resolve("justaname")
        self.assertTrue(str(resolved).endswith("justaname"))


if __name__ == "__main__":
    unittest.main()
