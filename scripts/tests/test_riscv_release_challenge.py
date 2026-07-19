import copy
import json
import os
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.riscv_release_challenge_lib import execution, model, program


def identity() -> dict[str, object]:
    return {
        "repository": {
            "full_name": "teddyjfpender/stwo-zig",
            "id": 1_152_389_958,
        },
        "candidate": {
            "commit": "a" * 40,
            "tree_oid": "b" * 40,
            "phase": "candidate",
            "executable_sha256": "c" * 64,
            "trace_executable_sha256": "d" * 64,
        },
        "workflow": {"commit": "e" * 40, "run_id": 12, "attempt": 3},
        "anchor": {
            "manifest_sha256": "f" * 64,
            "candidate_commit": "1" * 40,
            "tree_oid": "2" * 40,
            "producer_run_id": 9,
            "oracle_repository": "https://github.com/ClementWalter/stark-v",
            "oracle_commit": "3" * 40,
            "oracle_domain_sha256": "4" * 64,
            "oracle_executable_sha256": "5" * 64,
            "verifier_executable_sha256": "6" * 64,
        },
    }


class ProgramDerivationTests(unittest.TestCase):
    def test_golden_derivation_is_stable_fresh_and_cross_shard(self) -> None:
        derived = program.derive(bytes(range(32)), identity())
        self.assertEqual(
            "05dcf75ea2dbb77cad5abc2da21979d1b29b22e39644588ebf08ee061a076855",
            derived.seed_sha256,
        )
        self.assertEqual(65_536, derived.loop_iterations)
        self.assertEqual(
            "4fb6bd6b3ada83a3a1ea554df174b777dcfa5bacca6e1435648211ab00472c13",
            derived.elf_sha256,
        )
        self.assertEqual(b"", derived.input_bytes)
        self.assertEqual(
            (1_593_302_021, 2_092_424_098, 767_318_701, 3_514_374_562),
            derived.public_output_words,
        )
        self.assertNotEqual(
            derived.elf_sha256,
            program.derive(b"x" * 32, identity()).elf_sha256,
        )


class ChallengeContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = int(time.time())
        self.identity = identity()
        self.challenge = model.issue(self.identity, bytes(range(32)), self.now)

    def test_issue_binds_distinct_anchor_and_candidate(self) -> None:
        model.validate_challenge(
            self.challenge, expected_identity=self.identity, now=self.now,
        )
        self.assertNotEqual(
            self.challenge["identity"]["anchor"]["candidate_commit"],
            self.challenge["identity"]["candidate"]["commit"],
        )

    def test_wrong_bound_identity_or_derivation_fails_closed(self) -> None:
        mutations = (
            (lambda value: value["identity"]["candidate"].update(commit="7" * 40), "derivation"),
            (lambda value: value["identity"]["candidate"].update(tree_oid="7" * 40), "derivation"),
            (lambda value: value["identity"]["candidate"].update(executable_sha256="7" * 64), "derivation"),
            (lambda value: value["identity"]["anchor"].update(oracle_commit="7" * 40), "derivation"),
            (lambda value: value.update(nonce_hex="7" * 64), "derivation"),
            (lambda value: value["derivation"]["program"].update(input_sha256="7" * 64), "derivation"),
        )
        for mutate, diagnostic in mutations:
            drifted = copy.deepcopy(self.challenge)
            mutate(drifted)
            drifted["challenge_id_sha256"] = model.canonical_sha256(model.challenge_body(drifted))
            with self.subTest(diagnostic=diagnostic), self.assertRaisesRegex(
                model.ChallengeError, diagnostic,
            ):
                model.validate_challenge(drifted, now=self.now)

    def test_nonce_must_be_lowercase_and_challenge_expires(self) -> None:
        drifted = copy.deepcopy(self.challenge)
        drifted["nonce_hex"] = drifted["nonce_hex"].upper()
        drifted["challenge_id_sha256"] = model.canonical_sha256(model.challenge_body(drifted))
        with self.assertRaisesRegex(model.ChallengeError, "lowercase"):
            model.validate_challenge(drifted, now=self.now)
        with self.assertRaisesRegex(model.ChallengeError, "currently valid"):
            model.validate_challenge(
                self.challenge, now=self.challenge["expires_at_unix"] + 1,
            )

    def test_replay_ledger_is_atomic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ledger = Path(directory)
            model.claim_replay_slot(ledger, self.challenge["challenge_id_sha256"])
            with self.assertRaisesRegex(model.ChallengeError, "already"):
                model.claim_replay_slot(ledger, self.challenge["challenge_id_sha256"])

    def test_result_rehashes_proof_and_public_claim(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            names = {
                "challenge.json", "challenge.elf", "challenge.input", "proof.json",
                "prove-report.json", "verify-receipt.json", "oracle-public.json",
                "candidate-public.json", "oracle-relations.txt", "candidate-relations.txt",
            }
            for name in names:
                (evidence / name).write_text(name, encoding="utf-8")
            result = {
                "schema": model.RESULT_SCHEMA,
                "status": "PASS",
                "challenge_id_sha256": self.challenge["challenge_id_sha256"],
                "anchor": self.identity["anchor"],
                "candidate": self.identity["candidate"],
                "network_isolation": "linux-unshare-network-namespace-required",
                "comparisons": {
                    "independent_verify": "PASS",
                    "public_data_exact": "PASS",
                    "trace_terminal_state_exact": "PASS",
                    "relation_sums_exact": "PASS",
                },
                "files": {name: model.sha256_file(evidence / name) for name in names},
                "timing": {"wall_duration_ns": 1, "commands": [
                    {"name": name, "duration_ns": 1, "returncode": 0}
                    for name in (
                        "candidate-prove", "candidate-public", "candidate-relations",
                        "anchor-independent-verify", "pinned-oracle-public",
                        "pinned-oracle-relations",
                    )
                ]},
                "trust_limits": ["worker", "anchor verifier", "random sampling"],
            }
            model.validate_result(result, self.challenge, evidence)
            for name in ("proof.json", "candidate-public.json"):
                original = (evidence / name).read_bytes()
                (evidence / name).write_bytes(original + b"tamper")
                with self.subTest(name=name), self.assertRaisesRegex(
                    model.ChallengeError, "digest",
                ):
                    model.validate_result(result, self.challenge, evidence)
                (evidence / name).write_bytes(original)
            confused = copy.deepcopy(result)
            confused["anchor"]["candidate_commit"] = self.identity["candidate"]["commit"]
            with self.assertRaisesRegex(model.ChallengeError, "confuses"):
                model.validate_result(confused, self.challenge, evidence)


class SandboxContractTests(unittest.TestCase):
    @staticmethod
    def static_elf(interpreter: bool = False) -> bytes:
        raw = bytearray(128)
        raw[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<Q", raw, 32, 64)
        struct.pack_into("<HH", raw, 54, 56, 1)
        struct.pack_into("<I", raw, 64, 3 if interpreter else 1)
        return bytes(raw)

    def test_static_elf_contract_rejects_dynamic_interpreter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tool"
            path.write_bytes(self.static_elf())
            execution.require_static_elf(path)
            path.write_bytes(self.static_elf(interpreter=True))
            with self.assertRaisesRegex(model.ChallengeError, "dynamic interpreter"):
                execution.require_static_elf(path)

    @mock.patch("scripts.riscv_release_challenge_lib.execution.subprocess.run")
    def test_candidate_chroot_exposes_no_anchor_material(self, run: mock.Mock) -> None:
        run.return_value.returncode = 0
        run.return_value.stderr = ""
        run.return_value.stdout = ""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {}
            for name in ("prover", "trace", "elf", "input"):
                path = root / name
                path.write_bytes(name.encode())
                sources[name] = path
            sandbox = execution.CandidateSandbox(
                root / "sandbox",
                cli=sources["prover"],
                trace_cli=sources["trace"],
                elf=sources["elf"],
                input_path=sources["input"],
                deadline_ns=time.monotonic_ns() + 1_000_000_000,
            )
            try:
                exposed = {
                    str(path.relative_to(sandbox.root))
                    for path in sandbox.root.rglob("*") if path.is_file()
                }
                self.assertEqual(
                    {"bin/prover", "bin/trace", "work/challenge.elf", "work/challenge.input"},
                    exposed,
                )
                self.assertFalse(any("cp11" in path or "oracle" in path for path in exposed))
                prefix = sandbox.runner.prefix
                self.assertIn("--kill-child=SIGKILL", prefix)
                self.assertIn("--userspec=65534:65534", prefix)
                self.assertIn("--no-new-privs", prefix)
            finally:
                sandbox.close()


if __name__ == "__main__":
    unittest.main()
