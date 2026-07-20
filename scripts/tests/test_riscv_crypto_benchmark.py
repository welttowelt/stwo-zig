import unittest

from scripts.riscv_crypto_benchmark import METAL_CELL, input_for, is_proof_size


class ProofClassificationTests(unittest.TestCase):
    def test_provable_guest_proves_at_every_size(self) -> None:
        spec = {"eval": "provable", "kind": "input_sweep"}
        for label in ("128B", "512B", "2048B"):
            self.assertTrue(is_proof_size("sha2_input", spec, label))

    def test_single_block_guest_proves_only_at_128(self) -> None:
        spec = {"eval": "provable_single_block_only", "kind": "input_sweep"}
        self.assertTrue(is_proof_size("keccak_input", spec, "128B"))
        for label in ("256B", "512B", "1024B", "2048B"):
            self.assertFalse(is_proof_size("keccak_input", spec, label))

    def test_execution_only_guest_never_proves(self) -> None:
        for guest, spec in (
            ("ecdsa", {"eval": "execution_only", "kind": "fixed"}),
            ("poseidon2_m31", {"eval": "execution_only", "kind": "field_sweep"}),
        ):
            self.assertFalse(is_proof_size(guest, spec, "fixed"))
            self.assertFalse(is_proof_size(guest, spec, "16fe"))


class SweepShapeTests(unittest.TestCase):
    PROVENANCE = {"byte_input_sizes": [128, 256], "poseidon_field_widths": [2, 16]}

    def test_byte_sweep_labels_and_paths(self) -> None:
        pairs = input_for("sha2_input", {"kind": "input_sweep"}, self.PROVENANCE)
        self.assertEqual([label for label, _ in pairs], ["128B", "256B"])
        self.assertTrue(all(path is not None for _, path in pairs))

    def test_field_sweep_uses_field_inputs(self) -> None:
        pairs = input_for("poseidon2_m31", {"kind": "field_sweep"}, self.PROVENANCE)
        self.assertEqual([label for label, _ in pairs], ["2fe", "16fe"])
        self.assertTrue(all("field_" in path.name for _, path in pairs))

    def test_fixed_guest_has_no_input(self) -> None:
        pairs = input_for("ecdsa", {"kind": "fixed"}, self.PROVENANCE)
        self.assertEqual(pairs, [("fixed", None)])


class MetalColumnTests(unittest.TestCase):
    def test_riscv_metal_cell_is_gated(self) -> None:
        # The RISC-V adapter is CPU-only; no lane has a RISC-V Metal prover.
        self.assertEqual(METAL_CELL, "gated")
