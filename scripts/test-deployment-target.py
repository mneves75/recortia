#!/usr/bin/env python3
"""Prove the deployment-target check passes on this tree and fails on each planted mismatch."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
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
        result = self.planted("TOOLCHAIN.json", '"minimum_deployment_target": "26.0"',
                              '"minimum_deployment_target": "27.0"')
        self.assertNotEqual(0, result.returncode)
        self.assertIn("TOOLCHAIN.json minimum_deployment_target: 27.0", result.stderr)

    def test_project_deployment_target_mismatch_fails(self):
        result = self.planted("project.yml", 'macOS: "26.0"', 'macOS: "15.0"')
        self.assertNotEqual(0, result.returncode)
        self.assertIn("project.yml deploymentTarget.macOS: 15.0", result.stderr)

    def test_project_setting_mismatch_fails(self):
        result = self.planted("project.yml", 'MACOSX_DEPLOYMENT_TARGET: "26.0"', 'MACOSX_DEPLOYMENT_TARGET: "26.1"')
        self.assertNotEqual(0, result.returncode)
        self.assertIn("project.yml MACOSX_DEPLOYMENT_TARGET: 26.1", result.stderr)

    def test_generated_project_mismatch_fails(self):
        result = self.planted("Recortia.xcodeproj/project.pbxproj", "MACOSX_DEPLOYMENT_TARGET = 26.0;",
                              "MACOSX_DEPLOYMENT_TARGET = 15.0;", count=2)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("project.pbxproj MACOSX_DEPLOYMENT_TARGET: 15.0, 26.0", result.stderr)

    def test_package_mismatch_fails(self):
        result = self.planted("Packages/RecortiaKit/Package.swift", ".macOS(.v26)", ".macOS(.v15)")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Package.swift platforms .macOS: 15.0", result.stderr)

    def test_missing_value_fails(self):
        result = self.planted("Packages/RecortiaKit/Package.swift", ".macOS(.v26)", ".iOS(.v26)")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Package.swift platforms .macOS: no value found", result.stderr)


if __name__ == "__main__":
    unittest.main()
