from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scripts.check_upstream_pins import PinLedgerError, parse_ledger, validate_repository


ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / "docs" / "conformance" / "upstream.md"


class UpstreamPinTests(unittest.TestCase):
    def test_repository_pin_carriers_match_ledger(self) -> None:
        self.assertEqual([], validate_repository(ROOT))

    def test_cairo_ledger_drift_reaches_every_carrier_class(self) -> None:
        drifted = LEDGER.read_text(encoding="utf-8").replace(
            "dcd5834565b7a26a27a614e353c9c60109ebc1d9",
            "0" * 40,
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "upstream.md"
            path.write_text(drifted, encoding="utf-8")
            errors = validate_repository(ROOT, path)

        joined = "\n".join(errors)
        for carrier in (
            "tools/stwo-cairo-verifier-rs/src/lib.rs",
            "tools/stwo-cairo-verifier-rs/Cargo.toml",
            "tools/stwo-cairo-verifier-rs/Cargo.lock",
            ".github/workflows/ci.yml",
            "scripts/generate_cairo_claim_registry.py",
            "scripts/sn_pie_metal_session.py",
            "src/tools/metal_prover_session/state.zig",
            "src/frontends/cairo/prover.zig",
            "src/frontends/cairo/claim_registry.zig",
        ):
            self.assertIn(carrier, joined)

    def test_native_ledger_drift_reaches_source_manifests_and_locks(self) -> None:
        drifted = LEDGER.read_text(encoding="utf-8").replace(
            "a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2",
            "f" * 40,
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "upstream.md"
            path.write_text(drifted, encoding="utf-8")
            errors = validate_repository(ROOT, path)

        joined = "\n".join(errors)
        self.assertIn("src/interop/examples_artifact.zig", joined)
        self.assertIn("scripts/e2e_interop.py", joined)
        self.assertIn("scripts/prove_checkpoints.py", joined)
        self.assertIn("tools/stwo-interop-rs/Cargo.toml", joined)
        self.assertIn("tools/stwo-vector-gen/Cargo.lock", joined)
        self.assertIn("tools/stwo-cf-vector-gen/Cargo.toml", joined)

    def test_cairo_repository_drift_reaches_manifest_lock_source_and_ci(self) -> None:
        drifted = LEDGER.read_text(encoding="utf-8").replace(
            "https://github.com/teddyjfpender/stwo-cairo",
            "https://example.invalid/stwo-cairo",
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "upstream.md"
            path.write_text(drifted, encoding="utf-8")
            errors = validate_repository(ROOT, path)

        joined = "\n".join(errors)
        self.assertIn("tools/stwo-cairo-verifier-rs/src/lib.rs", joined)
        self.assertIn("tools/stwo-cairo-verifier-rs/Cargo.toml", joined)
        self.assertIn("tools/stwo-cairo-verifier-rs/Cargo.lock", joined)
        self.assertIn(".github/workflows/ci.yml", joined)

    def test_standard_and_strict_release_gates_enforce_pin_ledger(self) -> None:
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        command = 'b.addSystemCommand(&.{ "python3", "scripts/check_upstream_pins.py" })'
        self.assertEqual(3, build.count(command))
        self.assertIn("rg_source_conformance.step.dependOn(&rg_upstream_pins.step);", build)
        self.assertIn("rgs_source_conformance.step.dependOn(&rgs_upstream_pins.step);", build)

    def test_ledger_rejects_ambiguous_native_pin(self) -> None:
        text = LEDGER.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "upstream.md"
            path.write_text(text + "\n- Pinned commit: `" + "1" * 40 + "`\n", encoding="utf-8")
            with self.assertRaisesRegex(PinLedgerError, "exactly one Native Stwo revision"):
                parse_ledger(path)


if __name__ == "__main__":
    unittest.main()
