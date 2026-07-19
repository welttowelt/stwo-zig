"""Tests for the trusted-main RISC-V release policy domain."""

from __future__ import annotations

import json
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts import riscv_release_policy as policy


class ReleasePolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments], cwd=self.root, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def commit(self, path: str, content: str) -> str:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")
        self.git("add", path)
        self.git("commit", "-qm", path)
        return self.git("rev-parse", "HEAD")

    def repository(self) -> None:
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")

    def test_domain_binds_path_mode_and_content(self) -> None:
        self.repository()
        self.commit("policy/a", "one")
        first = policy.policy_domain(self.root, ("policy",))
        self.commit("policy/a", "two")
        second = policy.policy_domain(self.root, ("policy",))
        self.assertNotEqual(first["sha256"], second["sha256"])
        self.assertEqual(["policy"], first["paths"])

    def test_capture_compare_rejects_policy_drift(self) -> None:
        self.repository()
        trusted = self.commit("policy/a", "one")
        baseline = self.root.parent / f"{self.root.name}-baseline.json"
        output = self.root.parent / f"{self.root.name}-match.json"
        try:
            original_paths = policy.POLICY_PATHS
            policy.POLICY_PATHS = ("policy",)
            self.assertEqual(0, policy.main([
                "capture", "--root", str(self.root), "--trusted-commit", trusted,
                "--output", str(baseline),
            ]))
            self.assertEqual(0, policy.main([
                "compare", "--root", str(self.root), "--candidate", trusted,
                "--baseline", str(baseline), "--output", str(output),
            ]))
            self.assertEqual(policy.MATCH_SCHEMA, json.loads(output.read_text())["schema"])
            changed = self.commit("policy/a", "two")
            self.assertEqual(1, policy.main([
                "compare", "--root", str(self.root), "--candidate", changed,
                "--baseline", str(baseline), "--output", str(output),
            ]))
        finally:
            policy.POLICY_PATHS = original_paths
            baseline.unlink(missing_ok=True)
            output.unlink(missing_ok=True)

    def test_extract_rejects_traversal_and_symlinks(self) -> None:
        archive = self.root / "artifact.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("../escape", "bad")
        self.assertEqual(1, policy.main([
            "extract", "--archive", str(archive), "--output", str(self.root / "out"),
        ]))
        self.assertFalse((self.root.parent / "escape").exists())
        link = zipfile.ZipInfo("link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr(link, "manifest.json")
        self.assertEqual(1, policy.main([
            "extract", "--archive", str(archive), "--output", str(self.root / "out"),
        ]))

    def test_extract_accepts_regular_bundle_files(self) -> None:
        archive = self.root / "artifact.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("manifest.json", "{}")
            bundle.writestr("bin/stwo-zig", "binary")
        output = self.root / "out"
        self.assertEqual(0, policy.main([
            "extract", "--archive", str(archive), "--output", str(output),
        ]))
        self.assertEqual("binary", (output / "bin/stwo-zig").read_text())


if __name__ == "__main__":
    unittest.main()
