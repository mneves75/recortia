#!/usr/bin/env python3
"""REL-01: the test-only-marker gate must scan every Mach-O in the app bundle, with planted controls."""

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts/check-release-binary.sh"
MACH_O_MAGIC = bytes.fromhex("cffaedfe")  # 64-bit little-endian Mach-O header
MARKERS = ("RecortiaE2E", "RecortiaFixtures", "ChartFixture", "TextCorpus")


def mach_o(marker: str | None = None) -> bytes:
    body = b"\0" * 64 + b"Recortia production code\0"
    if marker is not None:
        body += b"\0" * 8 + marker.encode() + b"\0"
    return MACH_O_MAGIC + body


def make_app(root: pathlib.Path, *, main: bytes, extras: dict[str, bytes]) -> pathlib.Path:
    app = root / "Recortia.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/Recortia").write_bytes(main)
    for relative, data in extras.items():
        path = app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return app


def run_gate(target: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/bin/zsh", str(GATE), str(target)], capture_output=True, text=True)


class ReleaseBinaryGateTests(unittest.TestCase):
    def test_marker_in_sibling_dylib_is_rejected(self) -> None:
        for marker in MARKERS:
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                app = make_app(
                    pathlib.Path(directory),
                    main=mach_o(),
                    extras={"Contents/MacOS/Recortia.debug.dylib": mach_o(marker)},
                )
                result = run_gate(app)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn(marker, result.stderr)

    def test_marker_in_embedded_framework_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(
                pathlib.Path(directory),
                main=mach_o(),
                extras={"Contents/Frameworks/Helper.framework/Versions/A/Helper": mach_o("RecortiaE2E")},
            )
            self.assertEqual(1, run_gate(app).returncode)

    def test_marker_in_main_executable_is_rejected_by_app_and_by_executable_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(pathlib.Path(directory), main=mach_o("RecortiaE2E"), extras={})
            self.assertEqual(1, run_gate(app).returncode)
            self.assertEqual(1, run_gate(app / "Contents/MacOS/Recortia").returncode)

    def test_clean_bundle_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(
                pathlib.Path(directory),
                main=mach_o(),
                extras={
                    "Contents/MacOS/Recortia.debug.dylib": mach_o(),
                    # Not Mach-O: resources may mention a marker without shipping test code.
                    "Contents/Resources/notes.txt": b"RecortiaE2E is documented here\n",
                },
            )
            result = run_gate(app)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(0, run_gate(app / "Contents/MacOS/Recortia").returncode)

    def test_bundle_without_any_mach_o_fails_instead_of_passing_vacuously(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(pathlib.Path(directory), main=b"#!/bin/sh\n", extras={})
            self.assertNotEqual(0, run_gate(app).returncode)

    def test_missing_path_fails(self) -> None:
        self.assertNotEqual(0, run_gate(pathlib.Path("/nonexistent/Recortia.app")).returncode)

    def test_release_script_passes_the_bundle_not_only_the_executable(self) -> None:
        script = (ROOT / "scripts/release.sh").read_text()
        self.assertIn('scripts/check-release-binary.sh "$app"\n', script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
