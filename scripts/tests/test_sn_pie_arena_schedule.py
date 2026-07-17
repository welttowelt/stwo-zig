from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "sn_pie_arena_schedule", ROOT / "scripts" / "sn_pie_arena_schedule.py"
)
assert SPEC is not None and SPEC.loader is not None
schedule_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(schedule_tool)


def entry(
    logical_id: int,
    purpose: str,
    words: int,
    component: str | None = None,
    ordinal: int = 0,
) -> dict[str, object]:
    result: dict[str, object] = {
        "id": logical_id,
        "purpose": purpose,
        "ordinal": ordinal,
        "len_words": words,
        "first": "Witness",
        "last": "Interaction",
    }
    if component is not None:
        result["component"] = component
    return result


class ArenaScheduleTests(unittest.TestCase):
    def test_adapted_input_derives_exact_compact_and_raw_geometry(self) -> None:
        address_ids = list(range(64))
        pedersen_begin = 1
        pedersen_triples = [(7, 8, 9), (7, 8, 9), (10, 11, 12), (13, 14, 15)]
        for row, values in enumerate(pedersen_triples):
            address_ids[pedersen_begin + row * 3 : pedersen_begin + (row + 1) * 3] = values
        poseidon_begin = 20
        poseidon_tuples = [
            (1, 2, 3, 4, 5, 6),
            (1, 2, 3, 4, 5, 6),
            (7, 8, 9, 10, 11, 12),
            (13, 14, 15, 16, 17, 18),
        ]
        for row, values in enumerate(poseidon_tuples):
            address_ids[poseidon_begin + row * 6 : poseidon_begin + (row + 1) * 6] = values

        data = bytearray(schedule_tool.ADAPTED_INPUT_MAGIC)
        data.extend(struct.pack("<II", schedule_tool.ADAPTED_INPUT_VERSION, 0))
        data.extend(bytes(2 * 3 * 4))
        data.extend(struct.pack("<QHHIII", 17, 0, 0, 0, schedule_tool.OPCODE_COUNT, 0))
        for _ in range(schedule_tool.OPCODE_COUNT):
            data.extend(struct.pack("<Q", 0))
        data.extend(struct.pack("<QQII", 0, 0, 24, 0))
        data.extend(struct.pack("<QQQ", len(address_ids), 1, 1))
        data.extend(struct.pack("<" + "I" * len(address_ids), *address_ids))
        data.extend(bytes(8 * 4))
        data.extend(bytes(2 * 8))
        data.extend(struct.pack("<Q", 0))
        for segment_index in range(schedule_tool.BUILTIN_SEGMENT_COUNT):
            if segment_index == schedule_tool.PEDERSEN_SEGMENT_INDEX:
                data.extend(struct.pack("<B7xQQ", 1, pedersen_begin, pedersen_begin + 12))
            elif segment_index == schedule_tool.POSEIDON_SEGMENT_INDEX:
                data.extend(struct.pack("<B7xQQ", 1, poseidon_begin, poseidon_begin + 24))
            else:
                data.extend(struct.pack("<B7xQQ", 0, 0, 0))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.stwzcpi"
            path.write_bytes(data)
            metadata = schedule_tool.adapted_input_metadata(path, 4, 4)
            metadata_without_builtins = schedule_tool.adapted_input_metadata(
                path, None, None
            )
        self.assertEqual(metadata["pc_count"], 17)
        self.assertEqual(metadata["address_count"], 64)
        self.assertEqual(metadata["f252_count"], 1)
        self.assertEqual(metadata["small_count"], 1)
        self.assertEqual(metadata["pedersen_compact_rows"], 3)
        self.assertEqual(metadata["poseidon_compact_rows"], 3)
        self.assertEqual(metadata_without_builtins["pedersen_compact_rows"], 0)
        self.assertEqual(metadata_without_builtins["poseidon_compact_rows"], 0)

    def test_component_projection_filters_tagged_and_indexed_entries(self) -> None:
        schedule = [
            entry(0, "BaseTrace", 8, "add_opcode"),
            entry(1, "BaseTrace", 8, "pedersen_builtin"),
            entry(2, "BaseTrace", 8, "memory_id_to_big"),
            entry(3, "CompositionExtParams", 4, ordinal=0),
            entry(4, "CompositionExtParams", 4, ordinal=1),
            entry(5, "CompositionExtParams", 4, ordinal=2),
            entry(6, "RelationClaimedSum", 4, ordinal=0),
            entry(7, "RelationClaimedSum", 4, ordinal=1),
            entry(8, "RelationClaimedSum", 4, ordinal=2),
        ]
        projected, removed = schedule_tool.project_component_geometry(
            schedule,
            ["add_opcode", "pedersen_builtin", "memory_id_to_small"],
            ["add_opcode", "memory_id_to_small"],
        )
        self.assertEqual(removed, 3)
        self.assertEqual([int(value["id"]) for value in projected], list(range(6)))
        self.assertEqual(
            [
                int(value["ordinal"])
                for value in projected
                if value["purpose"] == "CompositionExtParams"
            ],
            [0, 1],
        )
        self.assertTrue(
            any(value.get("component") == "memory_id_to_big" for value in projected)
        )
        self.assertFalse(
            any(value.get("component") == "pedersen_builtin" for value in projected)
        )

    def test_preprocessed_projection_remaps_identity_ordinals(self) -> None:
        schedule = [
            entry(0, "PreprocessedCoefficients", 8, ordinal=0),
            entry(1, "PreprocessedCoefficients", 8, ordinal=1),
            entry(2, "PreprocessedCoefficients", 8, ordinal=2),
            entry(3, "PreprocessedEvaluations", 8, ordinal=1),
            entry(4, "PreprocessedEvaluations", 8, ordinal=2),
        ]
        projected, changed = schedule_tool.project_preprocessed_geometry(
            schedule,
            ["seq_4", "pedersen_points_0", "seq_5"],
            ["seq_4", "seq_5"],
        )
        self.assertEqual(changed, 4)
        self.assertEqual(
            [
                int(value["ordinal"])
                for value in projected
                if value["purpose"] == "PreprocessedCoefficients"
            ],
            [0, 1],
        )
        self.assertEqual(
            [
                int(value["ordinal"])
                for value in projected
                if value["purpose"] == "PreprocessedEvaluations"
            ],
            [1],
        )

    def test_trace_groups_rebuild_from_runtime_tree_widths(self) -> None:
        schedule = [
            entry(0, "CommitColumnLogSizes", 16),
            entry(1, "CommitColumnPointers", 32),
            entry(2, "CommitCoefficientPointers", 32),
            entry(3, "CommitCoefficientSizes", 16),
            entry(4, "CommitOutputPointers", 32),
            entry(5, "DecommitTraceEvaluationPointers", 32),
            entry(6, "DecommitTraceEvaluationLogs", 16),
            entry(7, "DecommitTraceCoefficientPointers", 32),
            entry(8, "DecommitTraceCoefficientSizes", 16),
            entry(9, "DecommitTraceLdeOutputPointers", 32),
        ]
        rebuilt, _changes = schedule_tool.rebuild_trace_group_geometry(
            schedule, (17, 1, 16, 8)
        )
        self.assertFalse(
            any(
                value["purpose"] in schedule_tool.OBSOLETE_COMMIT_GROUP_PURPOSES
                for value in rebuilt
            )
        )
        self.assertEqual(
            [
                int(value["len_words"])
                for value in rebuilt
                if value["purpose"] == "CommitColumnLogSizes"
            ],
            [16, 1, 1, 16, 8],
        )
        self.assertEqual(
            [
                int(value["len_words"])
                for value in rebuilt
                if value["purpose"] == "DecommitTraceEvaluationPointers"
            ],
            [32, 2, 2, 32, 16],
        )

    def test_proof_rows_includes_memory_small_as_second_memory_group(self) -> None:
        proof = {
            "claim": {
                "public_data": {},
                "add_opcode": {"log_size": 7},
                "memory_id_to_big": {"big_log_sizes": [5]},
                "memory_id_to_small": {"log_size": 9},
                "generic_opcode": None,
            }
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "proof.json"
            path.write_text(json.dumps(proof))
            self.assertEqual(
                schedule_tool.proof_rows(path),
                {"add_opcode": [128], "memory_id_to_big": [32, 512], "memory_id_to_small": [512]},
            )

    def test_grouped_memory_rows_and_runtime_multiplicities_retarget(self) -> None:
        schedule = [
            entry(0, "BaseTrace", 32, "memory_id_to_big", 0),
            entry(1, "BaseTrace", 32, "memory_id_to_big", 1),
            entry(2, "BaseCoefficients", 32, "memory_id_to_big", 0),
            entry(3, "BaseCoefficients", 32, "memory_id_to_big", 1),
            entry(4, "BaseTrace", 256, "memory_id_to_big", 0),
            entry(5, "BaseCoefficients", 256, "memory_id_to_big", 0),
            entry(6, "RuntimeMultiplicity", 32, "memory_id_to_big", 22),
            entry(7, "RuntimeMultiplicity", 256, "memory_id_to_big", 23),
        ]
        pairs = schedule_tool.source_target_rows(
            schedule, {"memory_id_to_big": [64, 1024]}
        )
        schedule_tool.scale_component_entries(schedule, pairs)
        self.assertEqual(
            [int(value["len_words"]) for value in schedule],
            [64, 64, 64, 64, 1024, 1024, 64, 1024],
        )

    def test_execution_table_geometry_comes_from_adapted_input(self) -> None:
        schedule = [
            entry(0, "ExecutionTableRawAddressToId", 10),
            entry(1, "ExecutionTableRawF252Words", 10),
            entry(2, "ExecutionTableRawSmallWords", 10),
            entry(3, "ExecutionTableBigLimb", 10, ordinal=0),
            entry(4, "ExecutionTableSmallLimb", 10, ordinal=0),
            entry(5, "RuntimeMultiplicity", 10, "memory_address_to_id", 21),
        ]
        pairs = {"memory_id_to_big": [(16, 32), (64, 128)]}
        metadata = {"address_count": 65, "f252_count": 3, "small_count": 5}
        schedule_tool.update_execution_table_geometry(schedule, pairs, metadata)
        self.assertEqual(
            [int(value["len_words"]) for value in schedule],
            [65, 24, 20, 32, 128, 128],
        )

    def test_composition_geometry_uses_unique_evaluation_logs(self) -> None:
        label = b"component"
        header = bytearray(40)
        header[:8] = schedule_tool.COMPOSITION_MAGIC
        struct.pack_into("<I", header, 8, 1)
        struct.pack_into("<Q", header, 16, 3)
        struct.pack_into("<I", header, 28, 2)
        components = bytearray()
        for evaluation_log in (7, 9):
            component = bytearray(44)
            struct.pack_into("<H", component, 0, len(label))
            struct.pack_into("<I", component, 12, evaluation_log)
            struct.pack_into("<IIIII", component, 24, 0, 1, 0, 0, 0)
            components.extend(component)
            components.extend(label)
            components.extend(struct.pack("<I", 0))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "composition.bin"
            path.write_bytes(header + components)
            schedule = [
                entry(0, "CompositionAccumulators", 1),
                entry(1, "CompositionCoefficients", 1),
                entry(2, "InverseTwiddles", 1),
                entry(3, "ForwardTwiddles", 4096),
                entry(4, "CompositionLdeTile", 1),
                entry(5, "CompositionRandomCoefficientPowers", 1),
            ]
            schedule_tool.update_composition_geometry(schedule, path)
        self.assertEqual(int(schedule[0]["len_words"]), (4 << 7) + (4 << 9))
        self.assertEqual(int(schedule[1]["len_words"]), 1 << 8)
        self.assertEqual(int(schedule[2]["len_words"]), 1 << 8)
        self.assertEqual(int(schedule[3]["len_words"]), 4096)
        self.assertEqual(int(schedule[4]["len_words"]), 1 << 9)
        self.assertEqual(int(schedule[5]["len_words"]), 12)

    def test_projected_composition_geometry_rejects_plan_hash_mismatch(self) -> None:
        data = bytearray(40)
        data[:8] = schedule_tool.COMPOSITION_MAGIC
        struct.pack_into("<I", data, 8, 2)
        plan_hash = 0xCBF29CE484222325
        for index, byte in enumerate(data):
            plan_hash ^= 0 if 32 <= index < 40 else byte
            plan_hash = (plan_hash * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        struct.pack_into("<Q", data, 32, plan_hash)
        schedule_tool.validate_composition_encoding(data)

        data[12] ^= 1
        with self.assertRaisesRegex(ValueError, "invalid projected composition plan hash"):
            schedule_tool.validate_composition_encoding(data)

    def test_fri_geometry_covers_log_24_and_log_25(self) -> None:
        evaluations, folds, leaves = schedule_tool.fri_geometry(24)
        self.assertEqual(evaluations, [24, 21, 18, 15, 12, 9, 6, 3])
        self.assertEqual(folds, [3, 3, 3, 3, 3, 3, 3, 2])
        self.assertEqual(sum(log_size + 1 for log_size in leaves), 100)

        evaluations, folds, leaves = schedule_tool.fri_geometry(25)
        self.assertEqual(evaluations, [25, 22, 19, 16, 13, 10, 7, 4])
        self.assertEqual(folds, [3] * 8)
        self.assertEqual(sum(log_size + 1 for log_size in leaves), 108)

        evaluations, folds, leaves = schedule_tool.fri_geometry(21)
        self.assertEqual(evaluations, [21, 18, 15, 12, 9, 6, 3])
        self.assertEqual(folds, [3, 3, 3, 3, 3, 3, 2])
        self.assertEqual(len(leaves), 7)

    def test_domain_geometry_removes_fri_rounds_above_target_degree(self) -> None:
        schedule: list[dict[str, object]] = []

        def add(purpose: str, words: int, ordinal: int = 0) -> None:
            schedule.append(entry(len(schedule), purpose, words, ordinal=ordinal))

        add("QuotientTile", 1)
        for tree in range(4):
            add("CommitLdeTile", 1, tree << 20)
            add("DecommitTraceRetainedPointers", 1, tree << 16)
        add("DecommitTraceLdeTile", 1)
        for round_index in range(8):
            if round_index > 0:
                add("FriRetainedEvaluation", 1, round_index)
                add("FriRetainedCoordinatePointers", 1, round_index)
            add("FriFoldingChallenge", 4, round_index)
            add("FriMerkleLayer", 8, round_index << 16)
            add("DecommitFriCoordinatePointers", 8, (4 + round_index) << 16)
            add("DecommitFriRetainedPointers", 1, (4 + round_index) << 16)
            add(
                "TranscriptInput",
                8,
                schedule_tool.FRI_TRANSCRIPT_ORDINAL_BASE
                + round_index * schedule_tool.FRI_TRANSCRIPT_ORDINAL_STRIDE,
            )
            add(
                "TranscriptOutput",
                4,
                schedule_tool.FRI_TRANSCRIPT_ORDINAL_BASE
                + 1
                + round_index * schedule_tool.FRI_TRANSCRIPT_ORDINAL_STRIDE,
            )

        rebuilt, _changed = schedule_tool.update_domain_geometry(schedule, 21)
        self.assertEqual(
            {
                int(value["ordinal"])
                for value in rebuilt
                if value["purpose"] == "FriFoldingChallenge"
            },
            set(range(7)),
        )
        self.assertEqual(
            {
                (int(value["ordinal"]) >> 16) - 4
                for value in rebuilt
                if value["purpose"] == "DecommitFriRetainedPointers"
            },
            set(range(7)),
        )
        self.assertFalse(
            any(
                int(value["ordinal"])
                == schedule_tool.FRI_TRANSCRIPT_ORDINAL_BASE
                + 7 * schedule_tool.FRI_TRANSCRIPT_ORDINAL_STRIDE
                for value in rebuilt
                if value["purpose"] == "TranscriptInput"
            )
        )

    def test_quotient_geometry_reads_fixture_header_and_partial_logs(self) -> None:
        partial_logs = [4, 6]
        data = bytearray(b"STWZQI01")
        data.extend(struct.pack("<IIII", 1, len(partial_logs), 6, 7))
        data.extend(bytes(32))
        for partial_log in partial_logs:
            data.extend(struct.pack("<I", partial_log))
            data.extend(bytes(48 + (16 << partial_log)))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "quotient.bin"
            path.write_bytes(data)
            self.assertEqual(schedule_tool.quotient_geometry(path), (6, 7, partial_logs))

    def test_transcript_geometry_uses_fixture_input_lengths(self) -> None:
        schedule = [
            entry(0, "TranscriptInput", 4392, ordinal=14),
            entry(1, "TranscriptInput", 24440, ordinal=25),
            entry(2, "TranscriptInput", 8, ordinal=65536),
        ]
        fixture = {
            "inputs": {
                "14": [0] * 5548,
                "25": [0] * 24436,
            }
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "transcript.json"
            path.write_text(json.dumps(fixture))
            changed = schedule_tool.update_transcript_geometry(schedule, path)
        self.assertEqual(changed, 2)
        self.assertEqual(
            [int(value["len_words"]) for value in schedule],
            [5548, 24436, 8],
        )

    def test_proof_geometry_tracks_transcript_input_size(self) -> None:
        schedule = [
            entry(index, "TranscriptInput", 8, ordinal=ordinal)
            for index, ordinal in enumerate(
                (
                    *schedule_tool.PROOF_FIXED_TRANSCRIPT_INPUT_ORDINALS,
                    *(
                        schedule_tool.FRI_TRANSCRIPT_ORDINAL_BASE
                        + round_index * schedule_tool.FRI_TRANSCRIPT_ORDINAL_STRIDE
                        for round_index in range(7)
                    ),
                )
            )
        ]
        schedule.extend(
            [
                entry(len(schedule), "DecommitAssembly", 100),
                entry(len(schedule) + 1, "ProofBytes", 240),
            ]
        )
        changed = schedule_tool.update_proof_geometry(schedule)
        self.assertEqual(changed, 1)
        proof = next(value for value in schedule if value["purpose"] == "ProofBytes")
        self.assertEqual(
            int(proof["len_words"]),
            100 + 8 * (len(schedule_tool.PROOF_FIXED_TRANSCRIPT_INPUT_ORDINALS) + 7),
        )

    def test_generic_relation_bundle_parser_preserves_canonical_order(self) -> None:
        components = schedule_tool.read_relation_components(
            ROOT / "vectors" / "cairo" / "cairo_relation_templates.bin"
        )
        self.assertEqual(len(components), 67)
        self.assertEqual(components[0][0], "add_ap_opcode")
        self.assertEqual(components[0][1][0], (0, 0, 55, 4))

    def test_relation_geometry_is_rebuilt_from_projected_bundle(self) -> None:
        schedule: list[dict[str, object]] = []

        def add(
            purpose: str,
            words: int,
            component: str | None = None,
            ordinal: int = 0,
        ) -> None:
            schedule.append(
                entry(len(schedule), purpose, words, component, ordinal)
            )

        for ordinal in range(12):
            add("InteractionTrace", 16, "alpha", ordinal)
        for ordinal in range(8):
            add("InteractionTrace", 32, "memory_id_to_big", ordinal)
        for ordinal in range(12):
            add("InteractionTrace", 64, "memory_id_to_big", ordinal)
        for purpose in (
            "RelationSourcePointers",
            "RelationOutputPointers",
            "RelationDenominators",
            "RelationClaimedSum",
        ):
            add(purpose, 999)

        relation = bytearray(schedule_tool.RELATION_MAGIC)
        relation.extend(struct.pack("<IQI", 1, 0x73963831C53DF4A2, 2))

        def add_component(
            name: str, traces: list[tuple[int, int, int, int]]
        ) -> None:
            encoded = name.encode()
            relation.extend(
                struct.pack("<HHI", len(encoded), len(traces), 0xFFFFFFFF)
            )
            relation.extend(encoded)
            for part, layout, layout_arg, output_columns in traces:
                relation.extend(
                    struct.pack(
                        "<IIII", part, layout, layout_arg, output_columns
                    )
                )
                relation.extend(bytes(output_columns * 16 * 4))

        add_component("alpha", [(0, 0, 9, 3)])
        add_component("memory_id_to_big", [(1, 2, 7, 2), (2, 3, 11, 3)])

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "relations.bin"
            path.write_bytes(relation)
            rebuilt, _changed, instances = schedule_tool.rebuild_relation_geometry(
                schedule,
                path,
                ["alpha", "memory_id_to_big", "memory_id_to_small"],
            )

        self.assertEqual(instances, 3)
        expected_words = {
            "RelationSourcePointers": [2, 16, 24],
            "RelationOutputPointers": [24, 16, 24],
            "RelationDenominators": [192, 256, 768],
            "RelationClaimedSum": [4, 4, 4],
        }
        for purpose, words in expected_words.items():
            entries = [value for value in rebuilt if value["purpose"] == purpose]
            self.assertEqual([value["len_words"] for value in entries], words)
            self.assertEqual([value["ordinal"] for value in entries], [0, 1, 2])

    def test_retention_sources_are_materialized_in_coefficient_order(self) -> None:
        schedule: list[dict[str, object]] = []
        for index in range(16):
            schedule.append(entry(index, "BaseCoefficients", 2, "large", index))
        for index in range(16):
            schedule.append(entry(16 + index, "BaseCoefficients", 1, "small", index))
        selected = schedule_tool.retention_sources(schedule)[0]
        self.assertEqual([int(value["len_words"]) for value in selected[:16]], [1] * 16)
        self.assertEqual([int(value["len_words"]) for value in selected[16:]], [2] * 16)

    def test_zero_retention_adds_workspace_for_every_decommit_group(self) -> None:
        schedule: list[dict[str, object]] = []

        def add(purpose: str, words: int, ordinal: int = 0) -> None:
            schedule.append(entry(len(schedule), purpose, words, ordinal=ordinal))

        # One coefficient column per trace column is enough to preserve the
        # exact 11/216/142/1 decommit grouping geometry.
        for purpose, columns in zip(
            schedule_tool.COEFFICIENT_PURPOSES,
            (161, 3449, 2268),
            strict=True,
        ):
            for ordinal in range(columns):
                add(purpose, 8, ordinal)
        for ordinal in range(8):
            add("CompositionCoefficients", 8, ordinal)

        for tree in range(1, 4):
            add("CommitRetainedEvaluation", 16, tree << 20)
            add("MerkleLeafState", 128, tree << 20)
            add("MerkleLayerScratch", 64, tree << 20)
            add("RetainedMerkleLayers", 8, tree << 20)

        group_counts = (11, 216, 142, 1)
        column_counts = (161, 3449, 2268, 8)
        for tree, (group_count, column_count) in enumerate(
            zip(group_counts, column_counts, strict=True)
        ):
            remaining = column_count
            for group in range(group_count):
                columns = min(remaining, 16)
                remaining -= columns
                ordinal = (tree << 16) | group
                add("DecommitTraceEvaluationPointers", columns * 2, ordinal)
                add("DecommitTraceEvaluationLogs", columns, ordinal)
            self.assertEqual(remaining, 0)

        rebuilt, removed, added = schedule_tool.rebuild_retention(schedule, 0)
        self.assertEqual(removed, 3)
        self.assertEqual(added, 370)
        self.assertFalse(
            any(value["purpose"] == "CommitRetainedEvaluation" for value in rebuilt)
        )
        expected_ordinals = {
            (tree << 16) | group
            for tree, group_count in enumerate(group_counts)
            for group in range(group_count)
        }
        for purpose in (
            "DecommitTraceCoefficientPointers",
            "DecommitTraceCoefficientSizes",
            "DecommitTraceLdeOutputPointers",
        ):
            self.assertEqual(
                {
                    int(value["ordinal"])
                    for value in rebuilt
                    if value["purpose"] == purpose
                },
                expected_ordinals,
            )


if __name__ == "__main__":
    unittest.main()
