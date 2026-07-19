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

    def test_every_scope_has_owned_steps(self) -> None:
        for scope, steps in MODULE.SCOPES.items():
            with self.subTest(scope=scope):
                self.assertTrue(steps)
                self.assertFalse(steps & MODULE.BUILTINS)

    def test_focused_product_steps_do_not_overlap(self) -> None:
        scopes = ("native_cpu", "native_metal", "riscv_cpu")
        for index, left in enumerate(scopes):
            for right in scopes[index + 1 :]:
                self.assertFalse(MODULE.SCOPES[left] & MODULE.SCOPES[right])


if __name__ == "__main__":
    unittest.main()
