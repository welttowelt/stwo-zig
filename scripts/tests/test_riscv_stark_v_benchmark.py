import unittest

from scripts.riscv_stark_v_benchmark import (
    MIN_RUST_PARALLELISM,
    PHASE_MARKERS,
    parse_phase_seconds,
)

FIXTURE = """\
\x1b[2m2026-07-19T23:06:20.000000Z\x1b[0m \x1b[32m INFO\x1b[0m \x1b[2mstark_v_bench\x1b[0m\x1b[2m:\x1b[0m Running guest program...
2026-07-19T23:06:20.100000Z  INFO stark_v_bench: Guest program completed with 144 cycles
2026-07-19T23:06:20.150000Z  INFO stark_v_bench: Preprocessing...
2026-07-19T23:06:20.200000Z  INFO stark_v_bench: Generating proof...
2026-07-19T23:06:22.700000Z  INFO stark_v_bench: Verifying proof...
2026-07-19T23:06:22.800000Z  INFO stark_v_bench: Proof verified successfully
"""


class PhaseParsingTests(unittest.TestCase):
    def test_durations_come_from_tracing_timestamps(self) -> None:
        phases = parse_phase_seconds(FIXTURE)
        self.assertAlmostEqual(phases["execution_seconds"], 0.2)
        self.assertAlmostEqual(phases["prove_seconds"], 2.5)
        self.assertAlmostEqual(phases["verify_seconds"], 0.1)

    def test_missing_markers_fail_closed(self) -> None:
        truncated = "\n".join(FIXTURE.splitlines()[:4])
        with self.assertRaisesRegex(ValueError, "phase markers"):
            parse_phase_seconds(truncated)

    def test_first_marker_occurrence_wins(self) -> None:
        # A second prove line (e.g. from a nested span) must not shift phases.
        doubled = FIXTURE.replace(
            "2026-07-19T23:06:22.700000Z  INFO stark_v_bench: Verifying proof...",
            "2026-07-19T23:06:22.600000Z  INFO stark_v_bench: Generating proof...\n"
            "2026-07-19T23:06:22.700000Z  INFO stark_v_bench: Verifying proof...",
        )
        phases = parse_phase_seconds(doubled)
        self.assertAlmostEqual(phases["prove_seconds"], 2.5)

    def test_marker_set_is_complete(self) -> None:
        self.assertEqual(
            set(PHASE_MARKERS), {"run_start", "prove_start", "verify_start", "verify_done"}
        )

    def test_parallelism_floor_rejects_serial_rust(self) -> None:
        # The floor must sit above a single core so a non-parallel Rust build
        # (cpu/wall ~ 1.0) fails, while a genuinely threaded one clears it.
        self.assertGreater(MIN_RUST_PARALLELISM, 1.0)
