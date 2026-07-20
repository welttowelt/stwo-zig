import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import ledger, promotion  # noqa: E402

HEADER = "\t".join(ledger.COLUMNS)


def claimed_verdict(**overrides) -> dict:
    verdict = {
        "schema_version": 1,
        "kind": "claimed",
        "harness_commit": "abc123",
        "repo_commit": "31a3132ef2e6",
        "predecessor_commit": "31a3132ef2e6",
        "scope": "s3",
        "declared_objective": {"board": "core_cpu", "workload_class": "wide",
                               "dimension": "time"},
        "gates": {g: {"pass": True} for g in ("G1", "G2", "G3", "G4", "G5")},
        "holdout": None,
        "score": {
            "R_geomean": 0.9631,
            "significant": True,
            "neutral": False,
            "per_workload": {"wf_log14x32": {"b_median_ms": 95.1, "ci": [0.955, 0.972]}},
        },
    }
    verdict.update(overrides)
    return verdict


class PromoteClaimedTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "test@example.invalid")
        self._git("config", "user.name", "test")
        (self.repo / "autoresearch" / "ledger").mkdir(parents=True)
        (self.repo / "autoresearch" / "ledger" / "promotions.tsv").write_text(HEADER + "\n")
        (self.repo / "autoresearch" / "ledger" / "epochs.json").write_text(
            json.dumps({"epochs": [{"epoch": 1}]})
        )
        self._commit("Harness scaffolding")

    def _git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def _commit(self, message):
        self._git("add", "-A")
        self._git("commit", "-q", "-m", message)

    def _land_submission(self, name, verdict):
        sub = self.repo / "autoresearch" / "submissions" / name
        sub.mkdir(parents=True)
        (sub / "verdict.json").write_text(json.dumps(verdict))
        (sub / "note.md").write_text("# note\n")
        self._commit(f"Merge submission {name}")

    def test_records_claimed_row_with_landing_commit(self):
        self._land_submission("2026-07-20-packed", claimed_verdict())
        row = promotion.promote_claimed(self.repo, "2026-07-20-packed")
        self.assertEqual(row["verdict_kind"], "claimed")
        self.assertEqual(row["outcome"], "promoted")
        rows = ledger.load(self.repo)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].verdict_kind, "claimed")
        landing = subprocess.run(
            ["git", "log", "--reverse", "--format=%H", "--",
             "autoresearch/submissions/2026-07-20-packed"],
            cwd=self.repo, capture_output=True, text=True, check=True,
        ).stdout.strip().splitlines()[0]
        self.assertEqual(rows[0].commit, landing)
        head_message = subprocess.run(
            ["git", "log", "-1", "--format=%s"], cwd=self.repo,
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        self.assertIn("claimed", head_message)

    def test_refuses_double_record(self):
        self._land_submission("2026-07-20-packed", claimed_verdict())
        promotion.promote_claimed(self.repo, "2026-07-20-packed")
        with self.assertRaises(promotion.PromotionError):
            promotion.promote_claimed(self.repo, "2026-07-20-packed")

    def test_refuses_judged_verdict(self):
        self._land_submission("2026-07-20-packed", claimed_verdict(kind="judged"))
        with self.assertRaises(promotion.PromotionError):
            promotion.promote_claimed(self.repo, "2026-07-20-packed")

    def test_refuses_dirty_tree(self):
        self._land_submission("2026-07-20-packed", claimed_verdict())
        (self.repo / "loose.txt").write_text("dirty")
        with self.assertRaises(promotion.PromotionError):
            promotion.promote_claimed(self.repo, "2026-07-20-packed")

    def test_insignificant_result_records_neutral(self):
        verdict = claimed_verdict()
        verdict["score"]["significant"] = False
        verdict["score"]["neutral"] = True
        self._land_submission("2026-07-20-neutral", verdict)
        row = promotion.promote_claimed(self.repo, "2026-07-20-neutral")
        self.assertEqual(row["outcome"], "neutral")


if __name__ == "__main__":
    unittest.main()
