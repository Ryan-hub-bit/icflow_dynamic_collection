from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from llm_test_generation.compare_icall_pairs import compare_pair_sets, load_pairs


class PairComparisonTests(unittest.TestCase):
    def test_counts_new_unique_pairs(self) -> None:
        baseline = {("demo_icall.json", 0x401000, 0x402000)}
        candidate = baseline | {
            ("demo_icall.json", 0x401000, 0x402100),
            ("demo_icall.json", 0x401000, 0x402200),
        }

        summary = compare_pair_sets(baseline, candidate)

        self.assertEqual(summary["baseline_pair_count"], 1)
        self.assertEqual(summary["candidate_pair_count"], 3)
        self.assertEqual(summary["new_pair_count"], 2)
        self.assertEqual(summary["union_pair_count"], 3)

    def test_loads_and_deduplicates_mypintool_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = {
                "0x401000": ["0x402000", "0x402000", "0x402100"],
            }
            (root / "demo_icall.json").write_text(
                json.dumps(payload), encoding="utf-8"
            )

            pairs, files = load_pairs(root)

            self.assertEqual(files, ["demo_icall.json"])
            self.assertEqual(len(pairs), 2)

    def test_rejects_wrong_json_shape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "demo_icall.json"
            path.write_text("[]", encoding="utf-8")

            with self.assertRaises(ValueError):
                load_pairs(path)


if __name__ == "__main__":
    unittest.main()
