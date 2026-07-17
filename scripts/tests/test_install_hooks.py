import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.install_hooks import HOOK_NAMES, install


class InstallHooksTests(unittest.TestCase):
    def test_install_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            hooks = repo / ".githooks"
            hooks.mkdir()
            for name in HOOK_NAMES:
                hook = hooks / name
                hook.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                hook.chmod(0o755)

            install(repo)
            install(repo)
            configured = subprocess.run(
                ["git", "config", "--local", "--get", "core.hooksPath"],
                cwd=repo,
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertEqual(".githooks", configured.stdout.strip())
            resolved = subprocess.run(
                ["git", "rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-commit"],
                cwd=repo,
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                (repo / ".githooks/pre-commit").resolve(),
                Path(resolved.stdout.strip()).resolve(),
            )


if __name__ == "__main__":
    unittest.main()
