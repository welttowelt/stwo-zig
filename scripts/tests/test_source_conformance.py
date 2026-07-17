import json
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from scripts.check_source_conformance import ROOT_ALLOWLIST, Finding, load_baseline, main, scan, write_baseline


class SourceConformanceTests(unittest.TestCase):
    def test_detects_dependency_size_and_root_violations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "src/core").mkdir(parents=True)
            (repo / "src/backends/metal").mkdir(parents=True)
            (repo / "src/tool_cli.zig").write_text("pub fn main() void {}\n", encoding="utf-8")
            (repo / "src/core/bad.zig").write_text(
                'const metal = @import("../backends/metal/mod.zig");\n' + "\n" * 850,
                encoding="utf-8",
            )
            (repo / "src/backends/metal/mod.zig").write_text("", encoding="utf-8")
            keys = {finding.key for finding in scan(repo)}
            self.assertIn("root-source:tool_cli.zig", keys)
            self.assertIn("file-size:core/bad.zig", keys)
            self.assertIn("dependency:core/bad.zig->backends/metal/mod.zig", keys)

    def test_generated_file_requires_generator_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "src/core").mkdir(parents=True)
            (repo / "src/core/generated.zig").write_text(
                "// Generated file. Generator: tools/example.zig\n" + "\n" * 900,
                encoding="utf-8",
            )
            self.assertEqual([], scan(repo))

    def test_deliberate_module_roots_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "src").mkdir()
            for name in ROOT_ALLOWLIST:
                (repo / "src" / name).write_text("pub const marker = true;\n", encoding="utf-8")
            self.assertEqual([], scan(repo))

    def test_baseline_round_trip_requires_explanations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "baseline.json"
            write_baseline(path, [Finding("file-size:a.zig", "too large")])
            self.assertIn("file-size:a.zig", load_baseline(path))
            path.write_text(json.dumps({"version": 1, "findings": [{"key": "bad"}]}), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_baseline(path)
            path.write_text(json.dumps({
                "version": 1,
                "findings": [
                    {"key": "duplicate", "reason": "legacy", "plan": "plan.md"},
                    {"key": "duplicate", "reason": "legacy", "plan": "plan.md"},
                ],
            }), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_baseline(path)

    def test_update_accepts_baseline_outside_repo(self) -> None:
        with tempfile.TemporaryDirectory() as repo_temporary, tempfile.TemporaryDirectory() as output_temporary:
            repo = Path(repo_temporary)
            (repo / "src").mkdir()
            baseline = Path(output_temporary) / "baseline.json"
            output = io.StringIO()
            with redirect_stdout(output):
                result = main([
                    "--repo",
                    str(repo),
                    "--baseline",
                    str(baseline),
                    "--update-baseline",
                ])
            self.assertEqual(0, result)
            self.assertTrue(baseline.exists())
            self.assertIn(str(baseline), output.getvalue())

    def test_ratchet_rejects_new_and_stale_findings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "src").mkdir()
            source = repo / "src/tool.zig"
            source.write_text("pub fn main() void {}\n", encoding="utf-8")
            baseline = repo / "baseline.json"
            write_baseline(baseline, [])
            with redirect_stderr(io.StringIO()):
                self.assertEqual(1, main(["--repo", str(repo), "--baseline", str(baseline)]))

            write_baseline(baseline, scan(repo))
            with redirect_stdout(io.StringIO()):
                self.assertEqual(0, main(["--repo", str(repo), "--baseline", str(baseline)]))

            source.unlink()
            with redirect_stderr(io.StringIO()):
                self.assertEqual(1, main(["--repo", str(repo), "--baseline", str(baseline)]))


if __name__ == "__main__":
    unittest.main()
