import unittest

from scripts.sn_pie_composition_digest_compare import (
    compare,
    compare_coefficients,
    compare_final,
    parse_metal,
    parse_metal_coefficients,
    parse_metal_final,
    parse_rust,
    parse_rust_coefficients,
    parse_rust_final,
)


def rust_csv(rows):
    header = (
        "component_index,log_size,coordinate,words,"
        "remaining_random_coefficients,first,last,fnv64,blake2s"
    )
    return [header, *rows]


def metal_line(component, log_size, coordinate, digest, first=1, last=2):
    return (
        "composition_accumulator_digest "
        f"component_index={component} log_size={log_size} coordinate={coordinate} "
        f"words={1 << log_size} first={first} last={last} fnv64={digest}"
    )


class CompositionDigestCompareTest(unittest.TestCase):
    def test_matches_active_log_checkpoint_from_cumulative_rust_csv(self):
        rust = rust_csv(
            [
                "0,5,0,32,4,1,2,0000000000000000,x",
                "0,5,1,32,4,1,2,0000000000000001,x",
                "0,5,2,32,4,1,2,0000000000000002,x",
                "0,5,3,32,4,1,2,0000000000000003,x",
                # Rust emits every live log after each component. Metal emits only
                # the log updated by this component, so this row is intentionally extra.
                "1,5,0,32,0,9,9,ffffffffffffffff,x",
                "1,6,0,64,0,1,2,0000000000000010,x",
                "1,6,1,64,0,1,2,0000000000000011,x",
                "1,6,2,64,0,1,2,0000000000000012,x",
                "1,6,3,64,0,1,2,0000000000000013,x",
            ]
        )
        metal = [
            metal_line(0, 5, coordinate, f"{coordinate:016x}")
            for coordinate in range(4)
        ] + [
            metal_line(1, 6, coordinate, f"{0x10 + coordinate:016x}")
            for coordinate in range(4)
        ]
        report = compare(parse_rust(rust), parse_metal(metal))
        self.assertEqual("match", report["status"])
        self.assertEqual(8, report["checked_coordinates"])

    def test_reports_first_component_coordinate_difference(self):
        rust = rust_csv(
            [
                f"0,5,{coordinate},32,0,1,2,{coordinate:016x},x"
                for coordinate in range(4)
            ]
        )
        metal = [
            metal_line(0, 5, coordinate, "000000000000dead" if coordinate == 2 else f"{coordinate:016x}")
            for coordinate in range(4)
        ]
        report = compare(parse_rust(rust), parse_metal(metal))
        self.assertEqual("mismatch", report["status"])
        self.assertEqual(2, report["first_mismatch"]["coordinate"])
        self.assertIn("fnv64", report["first_mismatch"]["differences"])

    def test_rejects_incomplete_metal_checkpoint(self):
        rust = rust_csv([])
        metal = [metal_line(0, 5, 0, "0000000000000000")]
        with self.assertRaisesRegex(ValueError, "four-coordinate"):
            compare(parse_rust(rust), parse_metal(metal))

    def test_matches_final_lifted_accumulator(self):
        rust = [
            "coordinate,log_size,words,first,last,fnv64,blake2s",
            *[f"{coordinate},24,16777216,1,2,{coordinate:016x},x" for coordinate in range(4)],
        ]
        metal = [
            "composition_lifted_accumulator_digest "
            f"coordinate={coordinate} log_size=24 words=16777216 "
            f"first=1 last=2 fnv64={coordinate:016x}"
            for coordinate in range(4)
        ]
        report = compare_final(parse_rust_final(rust), parse_metal_final(metal))
        self.assertEqual("match", report["status"])
        self.assertEqual(4, report["checked_records"])

    def test_compares_metal_coefficients_to_canonical_rust_layout(self):
        rust = [
            "index,half,coordinate,log_size,words,random0,random1,random2,random3,"
            "raw_first,raw_last,raw_fnv64,raw_blake2s,canonical_first,canonical_last,"
            "canonical_fnv64,canonical_blake2s",
            *[
                f"{index},left,0,23,8388608,0,0,0,0,9,9,ffffffffffffffff,x,"
                f"1,2,{index:016x},x"
                for index in range(8)
            ],
        ]
        metal = [
            "composition_coefficient_digest "
            f"index={index} log_size=23 words=8388608 "
            f"first=1 last=2 fnv64={index:016x}"
            for index in range(8)
        ]
        report = compare_coefficients(
            parse_rust_coefficients(rust), parse_metal_coefficients(metal)
        )
        self.assertEqual("match", report["status"])
        self.assertEqual(8, report["checked_records"])

        metal[5] = metal[5].replace("0000000000000005", "000000000000dead")
        report = compare_coefficients(
            parse_rust_coefficients(rust), parse_metal_coefficients(metal)
        )
        self.assertEqual("mismatch", report["status"])
        self.assertEqual(5, report["first_mismatch"]["index"])


if __name__ == "__main__":
    unittest.main()
