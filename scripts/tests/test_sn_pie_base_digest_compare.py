import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sn_pie_base_digest_compare.py"
SPEC = importlib.util.spec_from_file_location("sn_pie_base_digest_compare", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SnPieBaseDigestCompareTest(unittest.TestCase):
    def write_schedule(
        self,
        root: Path,
        components=("alpha", "alpha", "beta"),
        purpose="BaseCoefficients",
        ordinals_override=None,
    ) -> Path:
        entries = []
        ordinals = {}
        for index, component in enumerate(components):
            ordinal = (
                ordinals_override[index]
                if ordinals_override is not None
                else ordinals.get(component, 0)
            )
            ordinals[component] = ordinal + 1
            entries.append(
                {
                    "purpose": purpose,
                    "id": 100 + index,
                    "component": component,
                    "ordinal": ordinal,
                    "len_words": 8 if component == "alpha" else 4,
                }
            )
        path = root / "schedule.json"
        path.write_text(json.dumps({"arena": {"logical_buffer_schedule": entries}}))
        return path

    def write_rust(self, root: Path) -> Path:
        path = root / "rust.jsonl"
        lines = []
        for index, (log_size, first, last, fnv) in enumerate(
            ((3, 10, 11, "aa"), (3, 12, 13, "bb"), (2, 14, 15, "cc"))
        ):
            lines.append(
                "rust stderr: "
                + json.dumps(
                    {
                        "index": index,
                        "log_size": log_size,
                        "first": 999,
                        "last": 999,
                        "fnv64": "dead",
                        "coefficients_first": first,
                        "coefficients_last": last,
                        "coefficients_raw_fnv64": "beef",
                        "coefficients_fnv64": fnv,
                    }
                )
            )
        path.write_text("ignored prefix\n" + "\n".join(lines) + "\n")
        return path

    def write_zig(self, root: Path, overrides=None, count=3) -> Path:
        overrides = overrides or {}
        values = ((3, 10, 11, "aa"), (3, 12, 13, "bb"), (2, 14, 15, "cc"))
        components = (("alpha", 0), ("alpha", 1), ("beta", 0))
        lines = ["unrelated stderr output"]
        for index, ((log_size, first, last, fnv), (component, ordinal)) in enumerate(
            zip(values[:count], components[:count])
        ):
            fnv = overrides.get(index, fnv)
            words = 1 << log_size
            lines.append(
                f"[zig stderr] base_digest index={index} id={100 + index} "
                f"component={component} ordinal={ordinal} words={words} "
                f"first={first:08x} last={last:08x} fnv64={fnv:0>16}"
            )
        path = root / "zig.log"
        path.write_text("\n".join(lines) + "\n")
        return path

    def test_prefixed_logs_match_canonical_coefficients(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = MODULE.compare(
                self.write_schedule(root),
                self.write_rust(root),
                self.write_zig(root),
            )
        self.assertEqual(result["status"], "match")
        self.assertTrue(result["summary"]["all_columns_match"])
        self.assertEqual(result["summary"]["matched_columns"], 3)
        self.assertIsNone(result["first_mismatch"])
        self.assertEqual(
            [(item["component"], item["cumulative_columns"]) for item in result["components"]],
            [("alpha", 2), ("beta", 3)],
        )
        self.assertEqual(result["domain"], "canonical_base_coefficients")

    def test_eval_only_rust_export_selects_base_trace_schedule(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = self.write_schedule(root, components=("alpha",), purpose="BaseTrace")
            rust = root / "rust.jsonl"
            rust.write_text(
                'rust: {"index":0,"log_size":3,"first":10,"last":11,"fnv64":"aa"}\n'
            )
            zig = root / "zig.log"
            zig.write_text(
                "zig: base_digest index=0 id=100 component=alpha ordinal=0 words=8 "
                "first=0000000a last=0000000b fnv64=00000000000000aa\n"
            )
            result = MODULE.compare(schedule, rust, zig)
        self.assertEqual(result["status"], "match")
        self.assertEqual(result["domain"], "canonical_base_evaluations")
        self.assertEqual(result["schedule_purpose"], "BaseTrace")

    def test_first_mismatch_reports_cumulative_component_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = MODULE.compare(
                self.write_schedule(root),
                self.write_rust(root),
                self.write_zig(root, {2: "dd"}),
            )
        mismatch = result["first_mismatch"]
        self.assertEqual(result["status"], "mismatch")
        self.assertEqual(mismatch["index"], 2)
        self.assertEqual(mismatch["component"], "beta")
        self.assertEqual(mismatch["differences"]["fnv64"], {"rust": "00000000000000cc", "zig": "00000000000000dd"})
        self.assertEqual(mismatch["fully_matched_components_before"], 1)
        self.assertEqual(mismatch["component_boundary"]["cumulative_columns"], 3)
        self.assertEqual(result["last_fully_matched_component_boundary"]["component"], "alpha")

    def test_missing_zig_column_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = MODULE.compare(
                self.write_schedule(root),
                self.write_rust(root),
                self.write_zig(root, count=2),
            )
        self.assertEqual(result["status"], "mismatch")
        self.assertEqual(result["first_mismatch"]["index"], 2)
        self.assertEqual(result["first_mismatch"]["differences"]["zig"], "missing")
        self.assertFalse(result["summary"]["all_columns_match"])

    def test_schedule_log_size_and_zig_metadata_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            zig = self.write_zig(root)
            text = zig.read_text().replace("id=100", "id=999", 1).replace("words=8", "words=4", 1)
            zig.write_text(text)
            result = MODULE.compare(self.write_schedule(root), self.write_rust(root), zig)
        differences = result["first_mismatch"]["differences"]
        self.assertEqual(differences["logical_id"], {"schedule": 100, "zig": 999})
        self.assertEqual(differences["log_size"], {"schedule": 3, "rust": 3, "zig": 2})

    def test_component_ordinal_digest_without_index_maps_through_schedule(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = self.write_schedule(root, components=("add_opcode",))
            zig = root / "zig.log"
            zig.write_text(
                "prefix native_add_opcode_coeff_digest stage=post ordinal=0 "
                "first=0000000a last=0000000b fnv64=00000000000000aa\n"
            )
            digest = MODULE.load_zig_digests(zig, MODULE.load_schedule(schedule))[0]
        self.assertEqual(digest.index, 0)
        self.assertEqual(digest.log_size, 2)
        self.assertEqual(digest.component, "add_opcode")

    def test_base_eval_digest_maps_through_logical_id(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = self.write_schedule(root, purpose="BaseTrace")
            zig = root / "zig.log"
            zig.write_text(
                "base_eval_digest component=alpha local_index=0 logical_id=100 "
                "ordinal=0 log_size=3 first=10 last=11 fnv64=00000000000000aa\n"
            )
            digest = MODULE.load_zig_digests(
                zig,
                MODULE.load_schedule(schedule, MODULE.BASE_EVALUATIONS),
                "evaluations",
            )[0]
        self.assertEqual(digest.index, 0)
        self.assertEqual(digest.logical_id, 100)
        self.assertEqual(digest.component, "alpha")

    def test_repeated_component_ordinals_are_distinct_schedule_instances(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = self.write_schedule(
                root,
                components=("alpha", "alpha", "alpha"),
                ordinals_override=(0, 1, 0),
            )
            layouts = MODULE.load_schedule(schedule)
            columns = [
                {"status": "match"},
                {"status": "match"},
                {"status": "mismatch"},
            ]
            runs = MODULE._component_runs(layouts, columns)
        self.assertEqual(len(runs), 2)
        self.assertEqual(runs[0]["component_instance"], 0)
        self.assertEqual(runs[0]["end_index"], 1)
        self.assertEqual(runs[1]["component_instance"], 1)
        self.assertEqual(runs[1]["start_index"], 2)

    def test_ambiguous_component_ordinal_requires_explicit_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = self.write_schedule(
                root,
                components=("add_opcode", "add_opcode"),
                ordinals_override=(0, 0),
            )
            zig = root / "zig.log"
            zig.write_text(
                "native_add_opcode_coeff_digest stage=post ordinal=0 "
                "first=0000000a last=0000000b fnv64=00000000000000aa\n"
            )
            with self.assertRaisesRegex(MODULE.ComparisonError, "ambiguous component/ordinal"):
                MODULE.load_zig_digests(zig, MODULE.load_schedule(schedule))

    def test_duplicate_zig_index_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = self.write_schedule(root)
            zig = self.write_zig(root)
            zig.write_text(zig.read_text() + zig.read_text().splitlines()[1] + "\n")
            with self.assertRaisesRegex(MODULE.ComparisonError, "duplicate Zig digest index 0"):
                MODULE.load_zig_digests(zig, MODULE.load_schedule(schedule))


if __name__ == "__main__":
    unittest.main()
