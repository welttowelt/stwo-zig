from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "sn_pie_adapter.py"
SPEC = importlib.util.spec_from_file_location("sn_pie_adapter", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SnPieAdapterTests(unittest.TestCase):
    def test_directory_archive_is_flat_and_cached(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "SN_PIE"
            source.mkdir()
            (source / "metadata.json").write_text("{}")
            (source / "memory.bin").write_bytes(b"memory")

            first, first_hit = MODULE.pie_archive(source, root / "cache")
            second, second_hit = MODULE.pie_archive(source, root / "cache")

            self.assertFalse(first_hit)
            self.assertTrue(second_hit)
            self.assertEqual(first, second)
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(archive.namelist(), ["memory.bin", "metadata.json"])

    def test_directory_cache_identity_ignores_member_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "SN_PIE"
            source.mkdir()
            member = source / "metadata.json"
            member.write_text('{"version": 1}')

            first, first_hit = MODULE.pie_archive(source, root / "cache")
            stat = member.stat()
            os.utime(member, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
            second, second_hit = MODULE.pie_archive(source, root / "cache")

            self.assertFalse(first_hit)
            self.assertTrue(second_hit)
            self.assertEqual(first, second)

    def test_same_size_mutation_with_restored_mtime_invalidates_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "SN_PIE"
            source.mkdir()
            member = source / "memory.bin"
            member.write_bytes(b"memory")
            original_stat = member.stat()

            first, first_hit = MODULE.pie_archive(source, root / "cache")
            member.write_bytes(b"MEMORY")
            os.utime(member, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
            second, second_hit = MODULE.pie_archive(source, root / "cache")

            self.assertFalse(first_hit)
            self.assertFalse(second_hit)
            self.assertNotEqual(first, second)
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(archive.read("memory.bin"), b"memory")
            with zipfile.ZipFile(second) as archive:
                self.assertEqual(archive.read("memory.bin"), b"MEMORY")

    def test_directory_archive_bytes_are_independent_of_source_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = [root / "first" / "SN_PIE", root / "second" / "SN_PIE"]
            for index, source in enumerate(sources):
                source.mkdir(parents=True)
                member = source / "metadata.json"
                member.write_text('{"version": 1}')
                os.chmod(member, 0o600 if index == 0 else 0o644)
                os.utime(member, ns=(1_000_000_000, (index + 1) * 1_000_000_000))

            first, _ = MODULE.pie_archive(sources[0], root / "cache-a")
            second, _ = MODULE.pie_archive(sources[1], root / "cache-b")

            self.assertEqual(
                MODULE.directory_fingerprint(sources[0]),
                MODULE.directory_fingerprint(sources[1]),
            )
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_file_archive_is_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "pie.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("metadata.json", "{}")
            actual, hit = MODULE.pie_archive(archive_path, Path(directory) / "cache")
            self.assertEqual(actual, archive_path.resolve())
            self.assertTrue(hit)

    def test_execute_publishes_only_valid_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "pie.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("metadata.json", "{}")
            gpu_bench = root / "gpu_bench"
            gpu_bench.write_text("")
            destination = root / "adapted.stwzcpi"

            def fake_run(command, *, env, check, timeout):
                self.assertTrue(check)
                self.assertEqual(timeout, 10.0)
                self.assertEqual(command[0], str(gpu_bench.resolve()))
                Path(env["STWO_DUMP_STWZCPI"]).write_bytes(
                    MODULE.MAGIC + MODULE.VERSION.to_bytes(4, "little")
                )

            with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                used_archive, hit = MODULE.execute(
                    gpu_bench, archive_path, destination, root / "cache", None, 10.0
                )
            self.assertEqual(used_archive, archive_path.resolve())
            self.assertTrue(hit)
            MODULE.validate_adapted_input(destination)

    def test_invalid_output_is_not_published(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "pie.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("metadata.json", "{}")
            gpu_bench = root / "gpu_bench"
            gpu_bench.write_text("")
            destination = root / "adapted.stwzcpi"

            def fake_run(command, *, env, check, timeout):
                Path(env["STWO_DUMP_STWZCPI"]).write_bytes(b"wrong")

            with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                with self.assertRaises(ValueError):
                    MODULE.execute(
                        gpu_bench, archive_path, destination, root / "cache", None, 10.0
                    )
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
