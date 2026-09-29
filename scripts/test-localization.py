#!/usr/bin/env python3
"""Exercise the localization gate against isolated generated build artifacts."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class LocalizationTests(unittest.TestCase):
    def run_check(self, records):
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            derived = pathlib.Path(directory)
            for configuration, key in records:
                output = derived / "Build/Intermediates.noindex/Recortia.build" / configuration
                output = output / "Recortia.build/Objects-normal/arm64/Fixture.stringsdata"
                output.parent.mkdir(parents=True)
                output.write_text(json.dumps({
                    "source": str(ROOT / "RecortiaApp/Editor/EditorStrings.swift"),
                    "tables": {"Editor": [{"key": key}]},
                }))
            return subprocess.run(
                [sys.executable, str(ROOT / "scripts/check-localization.py"), str(derived), "Recortia"],
                capture_output=True, text=True, timeout=15,
            )

    def test_debug_does_not_consume_stale_release(self):
        result = self.run_check([
            ("Debug", "The image could not be copied."),
            ("Release", "Untranslated stale fixture"),
        ])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("1 extracted strings", result.stdout)

    def test_current_missing_translation_fails(self):
        result = self.run_check([("Debug", "Untranslated current fixture")])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Untranslated current fixture", result.stderr)

    def test_missing_debug_artifact_fails(self):
        result = self.run_check([("Release", "The image could not be copied.")])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("no .stringsdata", result.stderr)


if __name__ == "__main__":
    unittest.main()
