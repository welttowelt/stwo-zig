import unittest
from unittest import mock
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import runner


class QuietHostPreflightTest(unittest.TestCase):
    def test_darwin_busy_host_fails_before_measurement(self):
        with (
            mock.patch.object(runner.platform, "system", return_value="Darwin"),
            mock.patch.object(runner.os, "cpu_count", return_value=8),
            mock.patch.object(
                runner, "_preflight", return_value={"load_ok": False, "load1": 7.25},
            ),
        ):
            with self.assertRaisesRegex(
                runner.RunError, r"Apple timing refused before measurement",
            ):
                runner.require_quiet_preflight()

    def test_darwin_quiet_host_returns_admission_snapshot(self):
        snapshot = {"load_ok": True, "load1": 1.5}
        with (
            mock.patch.object(runner.platform, "system", return_value="Darwin"),
            mock.patch.object(runner, "_preflight", return_value=snapshot),
        ):
            self.assertEqual(runner.require_quiet_preflight(), snapshot)

    def test_linux_keeps_telemetry_only_behavior(self):
        snapshot = {"load_ok": False, "load1": 12.0}
        with (
            mock.patch.object(runner.platform, "system", return_value="Linux"),
            mock.patch.object(runner, "_preflight", return_value=snapshot),
        ):
            self.assertEqual(runner.require_quiet_preflight(), snapshot)


if __name__ == "__main__":
    unittest.main()
