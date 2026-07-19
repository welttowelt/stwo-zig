"""Fail-closed tests for the persistent Stark-V CP-11 helper cache."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from riscv_release_oracle_lib import build_cache  # noqa: E402
from riscv_release_oracle_lib import oracle_build  # noqa: E402


def identity(**changes: object) -> dict[str, object]:
    value: dict[str, object] = {
        "schema": "riscv-stark-v-oracle-build-identity-v1",
        "oracle": {
            "repository": "https://github.com/ClementWalter/stark-v",
            "commit": "d478f783055aa0d73a93768a433a3c6c31c91d1c",
            "tree_digest_sha256": "11" * 32,
            "submodules": [{"path": "external/stwo", "commit": "2" * 40}],
            "lockfile_sha256": "33" * 32,
        },
        "adapter_overlay_sha256": "44" * 32,
        "rust": {
            "rustc_verbose": "rustc pinned",
            "cargo_verbose": "cargo pinned",
            "target": "aarch64-apple-darwin",
            "cargo_config_sha256": "55" * 32,
            "build_environment": {},
        },
        "build_command": ["cargo", "build", "--locked"],
        "platform": {"machine": "arm64", "system": "Darwin"},
    }
    value.update(changes)
    return value


class OracleBuildCacheTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.binary = self.root / "built-cp11_dump"
        self.binary.write_bytes(b"integrity-checked Rust oracle")
        self.binary.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_round_trip_is_content_addressed_and_deterministic(self) -> None:
        expected_identity = identity()
        first = build_cache.store(self.root / "cache", expected_identity, self.binary)
        second = build_cache.load(self.root / "cache", expected_identity)
        self.assertEqual(first, second)
        self.assertEqual(build_cache.cache_key(expected_identity), first.key_sha256)
        self.assertEqual(hashlib.sha256(self.binary.read_bytes()).hexdigest(), first.executable_sha256)
        self.assertNotEqual(self.binary, first.executable)

    def test_identity_change_is_a_miss_even_when_binary_matches(self) -> None:
        cache_dir = self.root / "cache"
        build_cache.store(cache_dir, identity(), self.binary)
        changed = identity(adapter_overlay_sha256="99" * 32)
        self.assertIsNone(build_cache.load(cache_dir, changed))

    def test_actions_key_covers_full_inner_identity_and_schema(self) -> None:
        expected_identity = identity()
        outer = build_cache.actions_cache_identity(expected_identity)
        self.assertEqual(build_cache.CACHE_SCHEMA, outer["inner_cache_schema"])
        self.assertEqual(expected_identity, outer["inner_build_identity"])
        self.assertEqual(
            build_cache.cache_key(expected_identity),
            outer["inner_cache_key_sha256"],
        )

        original = build_cache.actions_cache_key(expected_identity)
        changed = identity(adapter_overlay_sha256="99" * 32)
        self.assertNotEqual(original, build_cache.actions_cache_key(changed))
        with mock.patch.object(build_cache, "CACHE_SCHEMA", "cache-schema-v2"):
            self.assertNotEqual(original, build_cache.actions_cache_key(expected_identity))

    def test_actions_key_covers_inner_entry_contract(self) -> None:
        original = build_cache.actions_cache_key(identity())
        with mock.patch.object(build_cache, "EXECUTABLE_NAME", "cp11_dump-v2"):
            self.assertNotEqual(original, build_cache.actions_cache_key(identity()))

    def test_cache_policy_names_the_trusted_writer_boundary(self) -> None:
        policy = (ROOT / "conformance/riscv-oracle-build-cache.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("integrity-checked, trusted-writer-scoped cache", policy)
        self.assertIn("GitHub currently reports `main` as `.protected=false`", policy)
        self.assertIn("repository-owner dispatch check is the fail-closed trust root", policy)
        self.assertNotIn("authenticated cache", policy.lower())

    def test_binary_tampering_is_a_miss(self) -> None:
        cache_dir = self.root / "cache"
        hit = build_cache.store(cache_dir, identity(), self.binary)
        hit.executable.write_bytes(b"tampered")
        hit.executable.chmod(0o755)
        self.assertIsNone(build_cache.load(cache_dir, identity()))

    def test_manifest_tampering_and_duplicate_fields_are_misses(self) -> None:
        cache_dir = self.root / "cache"
        hit = build_cache.store(cache_dir, identity(), self.binary)
        manifest = hit.executable.parent / build_cache.MANIFEST_NAME
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["artifact"]["sha256"] = "00" * 32
        manifest.write_text(json.dumps(payload), encoding="utf-8")
        self.assertIsNone(build_cache.load(cache_dir, identity()))

        manifest.write_text('{"schema":"a","schema":"b"}', encoding="utf-8")
        self.assertIsNone(build_cache.load(cache_dir, identity()))

    def test_non_executable_artifact_is_a_miss(self) -> None:
        cache_dir = self.root / "cache"
        hit = build_cache.store(cache_dir, identity(), self.binary)
        hit.executable.chmod(0o644)
        self.assertIsNone(build_cache.load(cache_dir, identity()))

    def test_corrupt_entry_is_replaced_by_a_verified_build(self) -> None:
        cache_dir = self.root / "cache"
        hit = build_cache.store(cache_dir, identity(), self.binary)
        hit.executable.write_bytes(b"corrupt")
        replacement = self.root / "replacement"
        replacement.write_bytes(b"fresh build")
        replacement.chmod(0o755)
        repaired = build_cache.store(cache_dir, identity(), replacement)
        self.assertEqual(b"fresh build", repaired.executable.read_bytes())
        self.assertEqual(repaired, build_cache.load(cache_dir, identity()))

    def test_default_path_honors_explicit_and_xdg_cache_roots(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"STWO_ZIG_RISCV_ORACLE_CACHE_DIR": str(self.root / "explicit")},
            clear=False,
        ):
            self.assertEqual(self.root / "explicit", build_cache.default_cache_dir())
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.root / "xdg")}, clear=True):
            self.assertEqual(
                self.root / "xdg" / "stwo-zig" / "riscv-oracle",
                build_cache.default_cache_dir(),
            )

    def test_store_rejects_a_symlinked_build_output(self) -> None:
        linked = self.root / "linked"
        linked.symlink_to(self.binary)
        with self.assertRaisesRegex(ValueError, "regular file"):
            build_cache.store(self.root / "cache", identity(), linked)

    def test_submodule_identity_rejects_uninitialized_or_drifted_entries(self) -> None:
        commit = "2" * 40
        self.assertEqual(
            [{"path": "external/stwo", "commit": commit}],
            oracle_build._normalized_submodules(f" {commit} external/stwo (pinned)\n"),
        )
        for prefix in ("-", "+", "U"):
            with self.subTest(prefix=prefix), self.assertRaisesRegex(
                SystemExit,
                "not initialized",
            ):
                oracle_build._normalized_submodules(
                    f"{prefix}{commit} external/stwo (not exact)\n"
                )


if __name__ == "__main__":
    unittest.main()
