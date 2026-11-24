#!/usr/bin/env python3
"""Exercise the localization gate against generated build artifacts and format-specifier parity."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts/check-localization.py"


class LocalizationTests(unittest.TestCase):
    def run_check(self, records):
        (ROOT / ".scratch").mkdir(exist_ok=True)
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
                [sys.executable, str(CHECK), str(derived), "Recortia"],
                capture_output=True, text=True, timeout=15,
            )

    def run_catalog(self, strings: dict) -> subprocess.CompletedProcess[str]:
        (ROOT / ".scratch").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            catalog = pathlib.Path(directory) / "Localizable.xcstrings"
            catalog.write_text(json.dumps({"sourceLanguage": "en", "strings": strings}))
            return subprocess.run(
                [sys.executable, str(CHECK), "--catalogs", str(catalog)],
                capture_output=True, text=True, timeout=15,
            )

    @staticmethod
    def unit(value: str) -> dict:
        return {"stringUnit": {"state": "translated", "value": value}}

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

    def test_real_catalogs_pass_format_specifier_parity(self):
        result = subprocess.run(
            [sys.executable, str(CHECK), "--catalogs"], capture_output=True, text=True, timeout=15
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("pass format specifier parity", result.stdout)

    def test_valid_reordered_positional_and_escaped_percent_pass(self):
        result = self.run_catalog({
            "Saved %@ (%lld)": {
                "localizations": {
                    "en": self.unit("Saved %@ (%lld)"),
                    "pt-BR": self.unit("(%2$lld) Salvo: %1$@"),
                }
            },
            "Progress %%d %@ %.1f%%": {
                "localizations": {
                    "en": self.unit("Progress %%d %@ %.1f%%"),
                    "pt-BR": self.unit("Progresso %%d %1$@ %2$.1f%%"),
                }
            },
            "Page %lld of %lld": {
                "localizations": {
                    "pt-BR": self.unit("Página %2$lld de %1$lld"),
                }
            },
        })
        self.assertEqual(0, result.returncode, result.stderr)

    def test_planted_format_specifier_mismatches_fail(self):
        cases = {
            "type mismatch %@ vs %lld": {
                "Value %@": {"localizations": {"en": self.unit("Value %@"), "pt-BR": self.unit("Valor %lld")}}
            },
            "missing %2$@": {
                "Pair %@ / %@": {"localizations": {"en": self.unit("Pair %@ / %@"), "pt-BR": self.unit("Par %1$@")}}
            },
            "extra specifier": {
                "Item %@": {"localizations": {"en": self.unit("Item %@"), "pt-BR": self.unit("Item %@ %lld")}}
            },
            "unescaped percent vs specifier": {
                "Done 100%%": {"localizations": {"en": self.unit("Done 100%%"), "pt-BR": self.unit("Feito %d")}}
            },
            "mixed positional and sequential": {
                "%@ %lld": {"localizations": {"en": self.unit("%@ %lld"), "pt-BR": self.unit("%1$@ %lld")}}
            },
            "zero positional index": {
                "Item %@": {"localizations": {"en": self.unit("Item %@"), "pt-BR": self.unit("Item %0$@")}}
            },
            "plural variation mismatch": {
                "%lld items": {
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {
                                    "one": self.unit("%lld item"),
                                    "other": self.unit("%lld items"),
                                }
                            }
                        },
                        "pt-BR": {
                            "variations": {
                                "plural": {
                                    "one": self.unit("%@ item"),
                                    "other": self.unit("%lld itens"),
                                }
                            }
                        },
                    }
                }
            },
            "substitution formatSpecifier mismatch": {
                "%lld frames · %lld px": {
                    "localizations": {
                        "en": {
                            **self.unit("%#@frames@ · %2$lld px"),
                            "substitutions": {
                                "frames": {
                                    "argNum": 1,
                                    "formatSpecifier": "lld",
                                    "variations": {"plural": {"other": self.unit("%arg frames")}},
                                }
                            },
                        },
                        "pt-BR": {
                            **self.unit("%#@frames@ · %2$lld px"),
                            "substitutions": {
                                "frames": {
                                    "argNum": 1,
                                    "formatSpecifier": "@",
                                    "variations": {"plural": {"other": self.unit("%arg quadros")}},
                                }
                            },
                        },
                    }
                }
            },
        }
        for name, strings in cases.items():
            with self.subTest(name):
                result = self.run_catalog(strings)
                self.assertEqual(1, result.returncode, result.stdout)
                self.assertIn("format specifier", result.stderr)


if __name__ == "__main__":
    unittest.main()
