import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/cairo_program_semantic_pack.py"
SPEC = importlib.util.spec_from_file_location("cairo_program_semantic_pack", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

FIB_ACTIVE = [
    "add_opcode",
    "add_opcode_small",
    "add_ap_opcode",
    "assert_eq_opcode",
    "assert_eq_opcode_imm",
    "call_opcode_rel_imm",
    "jnz_opcode_non_taken",
    "jnz_opcode_taken",
    "ret_opcode",
    "verify_instruction",
    "memory_address_to_id",
    "memory_id_to_big",
    "memory_id_to_small",
    "range_check_6",
    "range_check_8",
    "range_check_11",
    "range_check_12",
    "range_check_18",
    "range_check_20",
    "range_check_4_3",
    "range_check_4_4",
    "range_check_9_9",
    "range_check_7_2_5",
    "range_check_3_6_6_3",
    "range_check_4_4_4_4",
    "range_check_3_3_3_3_3",
    "verify_bitwise_xor_4",
    "verify_bitwise_xor_7",
    "verify_bitwise_xor_8",
    "verify_bitwise_xor_9",
]


def write_authority(
    path: Path,
    active: list[str] = FIB_ACTIVE,
    max_evaluation_log_size: int | None = 21,
) -> None:
    target = {
        "bundle_sha256": "ab" * 32,
        "plan_hash": "1234567890abcdef",
        "components": len(active),
        "preprocessed_variant": "canonical_without_pedersen",
        "tree_columns": [105, 396, 324, 8],
    }
    if max_evaluation_log_size is not None:
        target["max_evaluation_log_size"] = max_evaluation_log_size
    path.write_text(
        json.dumps(
            {
                "format": MODULE.COMPOSITION_MANIFEST_FORMAT,
                "version": MODULE.COMPOSITION_MANIFEST_VERSION,
                "bundle_version": 2,
                "source": {
                    "bundle_sha256": "cd" * 32,
                    "preprocessed_variant": "canonical",
                    "tree_columns": [161, 3449, 2268, 8],
                },
                "target": target,
                "components": [
                    {"label": label, "preprocessed": []} for label in active
                ],
            }
        )
    )


def write_small_preprocessed(path: Path, identities) -> None:
    with path.open("wb") as output:
        output.write(MODULE.PREPROCESSED_MAGIC)
        output.write(struct.pack("<II", 1, len(identities)))
        for ordinal, identity in enumerate(identities):
            encoded = identity.label.encode()
            output.write(struct.pack("<HHIQ", len(encoded), 0, 0, 1))
            output.write(encoded)
            output.write(struct.pack("<I", ordinal))


class CairoProgramSemanticPackTest(unittest.TestCase):
    def setUp(self):
        self.source_paths = {
            "witness_programs": ROOT / "vectors/cairo/sn_pie_2_witness_programs.bin",
            "multiplicity_feeds": ROOT / "vectors/cairo/sn_pie_2_multiplicity_feeds.bin",
            "relation_templates": ROOT / "vectors/cairo/cairo_relation_templates.bin",
            "fixed_tables": ROOT / "vectors/cairo/cairo_fixed_tables.bin",
        }
        self.source_fixed = MODULE.parse_fixed(self.source_paths["fixed_tables"].read_bytes())

    def test_fib_pack_filters_only_authorized_entries_and_preserves_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            authority = root / "composition.projection.json"
            write_authority(authority)
            preprocessed = root / "canonical.stwzppc"
            write_small_preprocessed(preprocessed, self.source_fixed.identities)
            sources = {**self.source_paths, "preprocessed_coefficients": preprocessed}
            outputs = {key: root / f"fib.{key}.bin" for key in MODULE.ARTIFACT_KEYS}
            manifest_path = root / "fib.semantic-pack.json"

            manifest = MODULE.build_program_pack(
                authority, sources, outputs, manifest_path
            )
            encoded_outputs = {key: path.read_bytes() for key, path in outputs.items()}

        self.assertEqual(
            {
                key: artifact["output_count"]
                for key, artifact in manifest["artifacts"].items()
            },
            {
                "witness_programs": 10,
                "multiplicity_feeds": 10,
                "relation_templates": 29,
                "fixed_tables": 17,
                "preprocessed_coefficients": 105,
            },
        )
        self.assertEqual(manifest["composition"]["plan_hash"], "1234567890abcdef")
        self.assertEqual(manifest["version"], 2)
        self.assertEqual(
            manifest["composition"]["verifier_max_log_degree_bound"], 20
        )
        self.assertIn("memory_id_to_big#small", manifest["dependencies"])

        source_witness = MODULE.parse_witness(
            self.source_paths["witness_programs"].read_bytes()
        )
        target_witness = MODULE.parse_witness(encoded_outputs["witness_programs"])
        source_feeds = MODULE.parse_feeds(
            self.source_paths["multiplicity_feeds"].read_bytes()
        )
        target_feeds = MODULE.parse_feeds(encoded_outputs["multiplicity_feeds"])
        source_relations = MODULE.parse_relations(
            self.source_paths["relation_templates"].read_bytes()
        )
        target_relations = MODULE.parse_relations(encoded_outputs["relation_templates"])
        target_fixed = MODULE.parse_fixed(encoded_outputs["fixed_tables"])
        for source, target in (
            (source_witness, target_witness),
            (source_feeds, target_feeds),
            (source_relations, target_relations),
        ):
            source_by_label = {entry.label: entry.encoded for entry in source.entries}
            for entry in target.entries:
                self.assertEqual(entry.encoded, source_by_label[entry.label])
        fixed_by_label = {
            entry.label: entry.encoded for entry in self.source_fixed.entries
        }
        for entry in target_fixed.entries:
            self.assertEqual(entry.encoded, fixed_by_label[entry.label])
        self.assertEqual(target_fixed.version, MODULE.FIXED_PROJECTED_VERSION)
        self.assertEqual(len(target_fixed.identities), 105)
        self.assertFalse(
            any(identity.label.startswith("pedersen_points_") for identity in target_fixed.identities)
        )

        preprocessed = encoded_outputs["preprocessed_coefficients"]
        self.assertEqual(preprocessed[:8], MODULE.PREPROCESSED_MAGIC)
        self.assertEqual(MODULE.u32(preprocessed, 12), 105)
        self.assertEqual(
            manifest["artifacts"]["preprocessed_coefficients"]["output_sha256"],
            MODULE.sha256_bytes(preprocessed),
        )

    def test_unauthorized_feed_dependency_fails_without_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            authority = root / "composition.projection.json"
            write_authority(
                authority,
                [label for label in FIB_ACTIVE if label != "memory_address_to_id"],
            )
            preprocessed = root / "canonical.stwzppc"
            write_small_preprocessed(preprocessed, self.source_fixed.identities)
            sources = {**self.source_paths, "preprocessed_coefficients": preprocessed}
            outputs = {key: root / f"fib.{key}.bin" for key in MODULE.ARTIFACT_KEYS}
            manifest = root / "fib.semantic-pack.json"

            with self.assertRaisesRegex(ValueError, "unauthorized dependency"):
                MODULE.build_program_pack(authority, sources, outputs, manifest)
            self.assertFalse(any(path.exists() for path in outputs.values()))
            self.assertFalse(manifest.exists())

    def test_projected_fixed_hash_rejects_mutation(self):
        identities = MODULE.projected_identities(
            self.source_fixed.identities,
            "canonical",
            "canonical_without_pedersen",
        )
        encoded, _ = MODULE.encode_projected_fixed(
            self.source_fixed,
            identities,
            [entry for entry in self.source_fixed.entries if entry.label in set(FIB_ACTIVE)],
        )
        corrupted = bytearray(encoded)
        corrupted[-1] ^= 1
        with self.assertRaisesRegex(ValueError, "invalid projected fixed-table plan hash"):
            MODULE.parse_fixed(corrupted)

    def test_projection_without_maximum_evaluation_log_size_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Path(directory) / "composition.projection.json"
            write_authority(authority, max_evaluation_log_size=None)
            with self.assertRaisesRegex(
                ValueError, "invalid target maximum evaluation log size"
            ):
                MODULE.parse_composition_authority(authority)

    def test_projection_maximum_evaluation_log_size_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Path(directory) / "composition.projection.json"
            for invalid in (True, 1, 33):
                with self.subTest(invalid=invalid):
                    write_authority(authority, max_evaluation_log_size=invalid)
                    with self.assertRaisesRegex(
                        ValueError, "invalid target maximum evaluation log size"
                    ):
                        MODULE.parse_composition_authority(authority)


if __name__ == "__main__":
    unittest.main()
