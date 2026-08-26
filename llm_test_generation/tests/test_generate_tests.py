from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from llm_test_generation.generate_tests import (
    materialize_suite,
    response_output_text,
    safe_generated_path,
    select_project_files,
    validate_generated_suite,
)


class SelectionTests(unittest.TestCase):
    def test_selection_prioritizes_tests_and_excludes_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "tests").mkdir()
            (root / "node_modules").mkdir()
            (root / "src" / "main.c").write_text("int main(void) { return 0; }", encoding="utf-8")
            (root / "tests" / "test_main.c").write_text("void test_main(void) {}", encoding="utf-8")
            (root / "CMakeLists.txt").write_text("project(example)", encoding="utf-8")
            (root / ".env").write_text("OPENAI_API_KEY=not-a-real-key", encoding="utf-8")
            (root / "node_modules" / "ignored.js").write_text("ignored", encoding="utf-8")

            selected = select_project_files(
                root,
                output_dir=None,
                max_files=10,
                max_file_bytes=10_000,
                max_context_chars=50_000,
            )
            paths = [item.path for item in selected]
            self.assertIn("tests/test_main.c", paths)
            self.assertIn("CMakeLists.txt", paths)
            self.assertIn("src/main.c", paths)
            self.assertNotIn(".env", paths)
            self.assertNotIn("node_modules/ignored.js", paths)
            self.assertLess(paths.index("tests/test_main.c"), paths.index("src/main.c"))

    def test_selection_balances_tests_with_production_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "tests").mkdir()
            (root / "src" / "library.c").write_text("void library(void) {}", encoding="utf-8")
            for index in range(10):
                (root / "tests" / f"test_{index}.c").write_text(
                    f"void test_{index}(void) {{}}", encoding="utf-8"
                )

            selected = select_project_files(
                root,
                output_dir=None,
                max_files=4,
                max_file_bytes=10_000,
                max_context_chars=50_000,
            )
            self.assertIn("src/library.c", [item.path for item in selected])


class ResponseTests(unittest.TestCase):
    def test_extracts_output_text_from_raw_response(self) -> None:
        payload = {"files": []}
        response = {
            "output": [
                {
                    "type": "message",
                    "content": [
                        {"type": "output_text", "text": json.dumps(payload)}
                    ],
                }
            ]
        }
        self.assertEqual(json.loads(response_output_text(response)), payload)


class MaterializationTests(unittest.TestCase):
    def test_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                safe_generated_path(root, "../outside.c")
            with self.assertRaises(ValueError):
                safe_generated_path(root, "/tmp/outside.c")
            with self.assertRaises(ValueError):
                safe_generated_path(root, "tests\\outside.c")
            with self.assertRaises(ValueError):
                safe_generated_path(root, "generation.json")

    def test_rejects_incomplete_structured_output(self) -> None:
        with self.assertRaises(ValueError):
            validate_generated_suite({"files": []})

    def test_rejects_duplicate_generated_paths_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "generated"
            entry = {
                "path": "tests/test_example.c",
                "purpose": "Exercise callback dispatch",
                "content": "int main(void) { return 0; }\n",
            }
            suite = {
                "summary": "Duplicate test",
                "detected_build_system": "CMake",
                "recommended_test_command": "ctest --test-dir build",
                "files": [entry, dict(entry)],
                "integration_notes": [],
            }
            with self.assertRaises(ValueError):
                materialize_suite(root, suite, force=False)
            self.assertFalse((root / "tests" / "test_example.c").exists())

    def test_materializes_relative_test_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "generated"
            suite = {
                "summary": "One test",
                "detected_build_system": "CMake",
                "recommended_test_command": "ctest --test-dir build",
                "files": [
                    {
                        "path": "tests/test_example.c",
                        "purpose": "Exercise callback dispatch",
                        "content": "int main(void) { return 0; }\n",
                    }
                ],
                "integration_notes": [],
            }
            written = materialize_suite(root, suite, force=False)
            self.assertEqual(len(written), 1)
            self.assertEqual(
                (root / "tests" / "test_example.c").read_text(encoding="utf-8"),
                "int main(void) { return 0; }\n",
            )


if __name__ == "__main__":
    unittest.main()
