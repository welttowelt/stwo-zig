#!/usr/bin/env python3
"""Unit tests for bidirectional prove checkpoint normalization."""

from __future__ import annotations

import json
import unittest

from scripts import prove_checkpoints


def artifact_for(proof_wire: dict[str, object]) -> dict[str, object]:
    encoded = json.dumps(proof_wire, separators=(",", ":")).encode("utf-8")
    return {"proof_bytes_hex": encoded.hex()}


class CanonicalProofWireTests(unittest.TestCase):
    def test_normalizes_only_backward_compatible_config_defaults(self) -> None:
        rust_wire = {
            "config": {
                "pow_bits": 0,
                "fri_config": {
                    "log_blowup_factor": 1,
                    "log_last_layer_degree_bound": 0,
                    "n_queries": 3,
                },
            },
            "commitments": [[1, 2, 3]],
        }
        zig_wire = {
            "config": {
                "pow_bits": 0,
                "fri_config": {
                    "log_blowup_factor": 1,
                    "log_last_layer_degree_bound": 0,
                    "n_queries": 3,
                    "fold_step": 1,
                },
                "lifting_log_size": None,
            },
            "commitments": [[1, 2, 3]],
        }

        self.assertEqual(
            prove_checkpoints.canonical_proof_wire(artifact_for(rust_wire)),
            prove_checkpoints.canonical_proof_wire(artifact_for(zig_wire)),
        )

    def test_preserves_non_default_semantic_differences(self) -> None:
        left = artifact_for(
            {"config": {"fri_config": {"fold_step": 1}}, "commitments": [[1]]}
        )
        right = artifact_for(
            {"config": {"fri_config": {"fold_step": 2}}, "commitments": [[1]]}
        )

        self.assertNotEqual(
            prove_checkpoints.canonical_proof_wire(left),
            prove_checkpoints.canonical_proof_wire(right),
        )


if __name__ == "__main__":
    unittest.main()
