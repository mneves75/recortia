#!/usr/bin/env python3
"""Prove the deployment-target check passes on this tree and fails on each planted mismatch."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Derive every pin from TOOLCHAIN.json rather than copying the floor into the test.
RECORD = json.loads((ROOT / "TOOLCHAIN.json").read_text())
TARGET = str(RECORD["minimum_deployment_target"])
MAJOR, MINOR = (TARGET.split(".") + ["0"])[:2]
PACKAGE_VERSION = f".v{MAJOR}" if MINOR == "0" else f".v{MAJOR}_{MINOR}"
NEXT_MAJOR = f"{int(MAJOR) + 1}.0"
PREV_MAJOR = f"{max(1, int(MAJOR) - 1)}.0"
PREV_PACKAGE_VERSION = f".v{max(1, int(MAJOR) - 1)}"
NEXT_MINOR = f"{MAJOR}.{int(MINOR) + 1}"
FILES = (
    "TOOLCHAIN.json",
    "project.yml",
    "Recortia.xcodeproj/project.pbxproj",
    "Packages/RecortiaKit/Package.swift",
)


class DeploymentTargetTests(unittest.TestCase):
    def run_check(self, root: pathlib.Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/check-deployment-target.py"), str(root)],
            capture_output=True, text=True, timeout=15,
        )

    def planted(self, path: str, old: str, new: str, count: int = 1) -> subprocess.CompletedProcess:
        """Copies the four files, replaces `old` with `new` in one of them, and runs the check."""
        (ROOT / ".scratch").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            copy = pathlib.Path(directory)
            for name in FILES:
                (copy / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, copy / name)
            text = (copy / path).read_text()
            self.assertEqual(count, text.count(old), f"{path} no longer contains {old!r}")
            (copy / path).write_text(text.replace(old, new, 1))
            return self.run_check(copy)

    def test_this_tree_agrees(self):
        result = self.run_check(ROOT)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("in all 5 places", result.stdout)

    def test_unchanged_copy_passes(self):
        result = self.planted("TOOLCHAIN.json", '"minimum_deployment_target"', '"minimum_deployment_target"')
        self.assertEqual(0, result.returncode, result.stderr)

    def test_toolchain_mismatch_fails(self):
        result = self.planted("TOOLCHAIN.json", f'"minimum_deployment_target": "{TARGET}"',
                              f'"minimum_deployment_target": "{NEXT_MAJOR}"')
        self.assertNotEqual(0, result.returncode)
        self.assertIn(f"TOOLCHAIN.json minimum_deployment_target: {NEXT_MAJOR}", result.stderr)

    def test_project_deployment_target_mismatch_fails(self):
        result = self.planted("project.yml", f'macOS: "{TARGET}"', f'macOS: "{PREV_MAJOR}"')
        self.assertNotEqual(0, result.returncode)
        self.assertIn(f"project.yml deploymentTarget.macOS: {PREV_MAJOR}", result.stderr)

    def test_project_setting_mismatch_fails(self):
        result = self.planted("project.yml", f'MACOSX_DEPLOYMENT_TARGET: "{TARGET}"',
                              f'MACOSX_DEPLOYMENT_TARGET: "{NEXT_MINOR}"')
        self.assertNotEqual(0, result.returncode)
        self.assertIn(f"project.yml MACOSX_DEPLOYMENT_TARGET: {NEXT_MINOR}", result.stderr)

    def test_generated_project_mismatch_fails(self):
        result = self.planted("Recortia.xcodeproj/project.pbxproj", f"MACOSX_DEPLOYMENT_TARGET = {TARGET};",
                              f"MACOSX_DEPLOYMENT_TARGET = {PREV_MAJOR};", count=2)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(f"project.pbxproj MACOSX_DEPLOYMENT_TARGET: {PREV_MAJOR}, {TARGET}", result.stderr)

    def test_package_mismatch_fails(self):
        result = self.planted("Packages/RecortiaKit/Package.swift", f".macOS({PACKAGE_VERSION})",
                              f".macOS({PREV_PACKAGE_VERSION})")
        self.assertNotEqual(0, result.returncode)
        self.assertIn(f"Package.swift platforms .macOS: {PREV_MAJOR}", result.stderr)

    def test_missing_value_fails(self):
        result = self.planted("Packages/RecortiaKit/Package.swift", f".macOS({PACKAGE_VERSION})",
                              f".iOS({PACKAGE_VERSION})")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Package.swift platforms .macOS: no value found", result.stderr)


if __name__ == "__main__":
    unittest.main()
