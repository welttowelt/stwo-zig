from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CLI_BOTS = (
    "judge_action.py",
    "promote_action.py",
    "qualify_action.py",
    "record_action.py",
    "validate_action.py",
)


class BotEntrypointImportTests(unittest.TestCase):
    def test_cli_bots_import_outside_repository(self) -> None:
        script = (
            "import importlib.util, pathlib, sys; "
            "path = pathlib.Path(sys.argv[1]); "
            "spec = importlib.util.spec_from_file_location(path.stem, path); "
            "module = importlib.util.module_from_spec(spec); "
            "spec.loader.exec_module(module)"
        )
        with tempfile.TemporaryDirectory() as cwd:
            for name in CLI_BOTS:
                with self.subTest(bot=name):
                    completed = subprocess.run(
                        [sys.executable, "-c", script, str(ROOT / "autoresearch" / "bots" / name)],
                        cwd=cwd,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(0, completed.returncode, completed.stderr)


if __name__ == "__main__":
    unittest.main()
