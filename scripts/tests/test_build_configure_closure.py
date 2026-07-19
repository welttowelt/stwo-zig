import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "check_build_configure_closure.py"
SPEC = importlib.util.spec_from_file_location("configure_closure", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ConfigureClosureTests(unittest.TestCase):
    def test_parse_steps_ignores_options(self) -> None:
        help_text = """Usage: zig build\n\nSteps:\n  install (default) Copy\n  focused  Build it\n\nGeneral Options:\n  -h Help\n"""
        self.assertEqual({"install", "focused"}, MODULE.parse_steps(help_text))

    def test_python_checker_has_no_parallel_scope_authority(self) -> None:
        self.assertFalse(hasattr(MODULE, "SCOPES"))
        self.assertFalse(hasattr(MODULE, "MANIFESTS"))


if __name__ == "__main__":
    unittest.main()
