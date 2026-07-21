from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BOT_ENTRYPOINTS = (
    "intake_action.py",
    "judge_action.py",
    "promote_action.py",
    "qualify_action.py",
    "queue_judge_action.py",
    "queue_promote_action.py",
    "record_action.py",
    "validate_action.py",
)
BACKEND_ENTRYPOINTS = ("server.py", "worker.py")


class BotEntrypointImportTests(unittest.TestCase):
    def assert_entrypoints_import(self, directory: str, names: tuple[str, ...]) -> None:
        script = (
            "import importlib.util, pathlib, sys; "
            "path = pathlib.Path(sys.argv[1]); "
            "spec = importlib.util.spec_from_file_location(path.stem, path); "
            "module = importlib.util.module_from_spec(spec); "
            "spec.loader.exec_module(module)"
        )
        with tempfile.TemporaryDirectory() as cwd:
            for name in names:
                with self.subTest(entrypoint=f"{directory}/{name}"):
                    environment = {key: value for key, value in os.environ.items()
                                   if key != "PYTHONPATH"}
                    completed = subprocess.run(
                        [sys.executable, "-I", "-c", script,
                         str(ROOT / "autoresearch" / directory / name)],
                        cwd=cwd,
                        capture_output=True,
                        text=True,
                        env=environment,
                    )
                    self.assertEqual(0, completed.returncode, completed.stderr)

    def test_bots_import_outside_repository(self) -> None:
        self.assert_entrypoints_import("bots", BOT_ENTRYPOINTS)

    def test_backend_processes_import_outside_repository(self) -> None:
        self.assert_entrypoints_import("backend", BACKEND_ENTRYPOINTS)


if __name__ == "__main__":
    unittest.main()
