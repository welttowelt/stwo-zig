import json
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from scripts.check_source_conformance import (
    BASELINE_VERSION,
    ROOT_ALLOWLIST,
    Finding,
    inventory,
    load_baseline,
    main,
    scan,
    write_baseline,
)


class SourceConformanceTests(unittest.TestCase):
    @staticmethod
    def baseline_entry(key: str, **overrides: object) -> dict[str, object]:
        entry: dict[str, object] = {
            "key": key,
            "owner": "test-owner",
            "reason": "legacy test debt",
            "plan": "plan.md",
            "next_extraction": "Extract the test responsibility.",
        }
        entry.update(overrides)
        return entry

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
                "// Generated file. Generator: tools/example.zig\n"
                "// Regenerate: zig build generate-example\n"
                + "\n" * 900,
                encoding="utf-8",
            )
            self.assertEqual([], scan(repo))

            (repo / "src/core/generated.zig").write_text(
                "// Generated file. Generator: tools/example.zig\n" + "\n" * 900,
                encoding="utf-8",
            )
            self.assertIn("file-size:core/generated.zig", {finding.key for finding in scan(repo)})

    def test_inventories_owned_source_outside_src_and_excludes_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            sources = {
                "build.zig": "build",
                "build_support/options.py": "build",
                "scripts/report.py": "python",
                "tools/oracle/src/main.rs": "rust-tool",
            }
            for relative, _ in sources.items():
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("\n" * 851, encoding="utf-8")

            excluded = (
                "scripts/__pycache__/cached.py",
                "scripts/generated/schema.py",
                "scripts/vendor/library.py",
                "tools/oracle/target/debug/build.rs",
                "tools/oracle/vendor/dependency.rs",
                "ethereum-guest/src/main.rs",
            )
            for relative in excluded:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("\n" * 851, encoding="utf-8")

            owned = {source.display_path.as_posix(): source.category for source in inventory(repo)}
            self.assertEqual(sources, owned)
            keys = {finding.key for finding in scan(repo)}
            self.assertEqual({f"file-size:{relative}" for relative in sources}, keys)

    def test_dependency_enforcement_is_limited_to_src(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "src/core").mkdir(parents=True)
            (repo / "src/backends/metal").mkdir(parents=True)
            (repo / "src/backends/metal/mod.zig").write_text("", encoding="utf-8")
            (repo / "build.zig").write_text(
                'const metal = @import("src/backends/metal/mod.zig");\n',
                encoding="utf-8",
            )
            (repo / "src/core/bad.zig").write_text(
                'const metal = @import("../backends/metal/mod.zig");\n',
                encoding="utf-8",
            )
            dependencies = {
                finding.key for finding in scan(repo) if finding.key.startswith("dependency:")
            }
            self.assertEqual(
                {"dependency:core/bad.zig->backends/metal/mod.zig"},
                dependencies,
            )

    def test_objective_c_manual_source_uses_the_same_size_ceiling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "src/backends/metal").mkdir(parents=True)
            (repo / "src/backends/metal/runtime.m").write_text("\n" * 851, encoding="utf-8")
            self.assertIn(
                "file-size:backends/metal/runtime.m",
                {finding.key for finding in scan(repo)},
            )

    def test_metal_size_and_repository_include_rules_are_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            shader_root = repo / "src/backends/metal/shaders"
            include_root = shader_root / "include"
            include_root.mkdir(parents=True)
            (include_root / "m31.metal").write_text("inline uint m31_add(uint a, uint b);\n", encoding="utf-8")
            (shader_root / "valid.metal").write_text(
                '#include <metal_stdlib>\n#include "stwo_zig/m31.metal"\n',
                encoding="utf-8",
            )
            (shader_root / "oversized.metal").write_text("\n" * 851, encoding="utf-8")
            (shader_root / "escape.metal").write_text(
                '#include "../../outside.metal"\n',
                encoding="utf-8",
            )
            keys = {finding.key for finding in scan(repo)}
            self.assertIn("file-size:backends/metal/shaders/oversized.metal", keys)
            self.assertIn(
                "shader-include:backends/metal/shaders/escape.metal->../../outside.metal",
                keys,
            )
            self.assertNotIn(
                "shader-include:backends/metal/shaders/valid.metal->stwo_zig/m31.metal",
                keys,
            )

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
            write_baseline(path, [Finding("file-size:a.zig", "too large", 900)])
            loaded = load_baseline(path)
            self.assertIn("file-size:a.zig", loaded)
            self.assertEqual("source-conformance", loaded["file-size:a.zig"]["owner"])
            self.assertIn("next_extraction", loaded["file-size:a.zig"])
            path.write_text(json.dumps({
                "version": BASELINE_VERSION,
                "findings": [
                    self.baseline_entry("file-size:a.zig"),
                ],
            }), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_baseline(path)
            path.write_text(
                json.dumps({"version": BASELINE_VERSION, "findings": [{"key": "bad"}]}),
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                load_baseline(path)
            path.write_text(json.dumps({
                "version": BASELINE_VERSION,
                "findings": [
                    self.baseline_entry("duplicate"),
                    self.baseline_entry("duplicate"),
                ],
            }), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_baseline(path)

    def test_baseline_requires_owner_next_extraction_and_applicable_cap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "baseline.json"
            invalid_entries = (
                self.baseline_entry("dependency:a->b", owner="Team Name"),
                self.baseline_entry("dependency:a->b", next_extraction=""),
                self.baseline_entry("dependency:a->b", max_lines=900),
            )
            for entry in invalid_entries:
                path.write_text(
                    json.dumps({"version": BASELINE_VERSION, "findings": [entry]}),
                    encoding="utf-8",
                )
                with self.assertRaises(ValueError):
                    load_baseline(path)

    def test_checked_in_schema_matches_enforced_baseline_contract(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        schema = json.loads(
            (repo / "docs/conformance/source-baseline.schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(BASELINE_VERSION, schema["properties"]["version"]["const"])
        finding = schema["$defs"]["finding"]
        self.assertEqual(
            {"key", "owner", "reason", "next_extraction", "plan"},
            set(finding["required"]),
        )
        self.assertEqual(850, finding["properties"]["max_lines"]["exclusiveMinimum"])
        self.assertFalse(finding["additionalProperties"])

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
            plan = repo / "docs/design/2026-07-17-source-conformance.md"
            plan.parent.mkdir(parents=True)
            plan.write_text("# Plan\n", encoding="utf-8")
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

    def test_ratchet_rejects_oversized_file_growth_and_missing_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            source = repo / "src/core/legacy.zig"
            source.parent.mkdir(parents=True)
            source.write_text("\n" * 900, encoding="utf-8")
            baseline = repo / "baseline.json"
            write_baseline(baseline, scan(repo))

            with redirect_stderr(io.StringIO()):
                self.assertEqual(1, main(["--repo", str(repo), "--baseline", str(baseline)]))

            plan = repo / "docs/design/2026-07-17-source-conformance.md"
            plan.parent.mkdir(parents=True)
            plan.write_text("# Plan\n", encoding="utf-8")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(0, main(["--repo", str(repo), "--baseline", str(baseline)]))

            source.write_text("\n" * 901, encoding="utf-8")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(1, main(["--repo", str(repo), "--baseline", str(baseline)]))


if __name__ == "__main__":
    unittest.main()
