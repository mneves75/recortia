#!/usr/bin/env python3
"""Prove the gate inventory can fail.

Each test builds a throwaway tree that satisfies the inventory, then removes exactly one thing the
inventory claims — a test file, a caller's reference to that test, or the test's presence in the
inventory — and requires a non-zero exit naming the break. A pass here means tests.json cannot go
quietly wrong in the three ways that matter: a gate without its test, a test nothing runs, and a
status written from an evidence file that shows a failure.
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "tests-report.py"


class TestsReportTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "Packages/RecortiaKit").mkdir(parents=True)
        (self.root / "RecortiaApp/E2E").mkdir(parents=True)
        (self.root / ".scratch/logs").mkdir(parents=True)
        shutil.copy(SCRIPT, self.root / "scripts" / SCRIPT.name)
        (self.root / "Packages/RecortiaKit/Package.swift").write_text("// package\n")
        (self.root / "RecortiaApp/E2E/E2EScenarios.swift").write_text("// scenarios\n")
        (self.root / "TOOLCHAIN.json").write_text(
            json.dumps(
                {
                    "actual_xcode_version": "27.2",
                    "actual_xcode_build": "27B48",
                    "actual_xcode_release_channel": "release_candidate",
                    "stable_xcode_baseline": {"version": "27.0", "build": "27A266a"},
                }
            )
        )
        inventory = json.loads(
            subprocess.run(
                [sys.executable, str(SCRIPT), "--print"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        )
        self.gates = inventory["gates"]
        # Everything the inventory names exists and is invoked.
        for gate in self.gates:
            for relative in [gate["protected_file"], *gate["tests"]]:
                path = self.root / relative
                if path.exists():
                    # tests-report.py itself is copied above; never overwrite it with a stub.
                    continue
                if path.suffix or "scripts/" in relative:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("// fixture\n")
        for caller in {c for gate in self.gates for c in gate["invoked_by"]}:
            names = [pathlib.Path(t).name for gate in self.gates if caller in gate["invoked_by"] for t in gate["tests"]]
            path = self.root / caller
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\n" + "".join(f"python3 scripts/{n}\n" for n in names))

    def run_report(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.root / "scripts" / SCRIPT.name), *arguments],
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_clean_inventory_passes(self) -> None:
        result = self.run_report("--check")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_missing_test_file_is_reported(self) -> None:
        (self.root / "scripts/test-doctor.py").unlink()
        result = self.run_report("--check")
        self.assertEqual(1, result.returncode)
        self.assertIn("test-doctor.py is missing", result.stderr)

    def test_uninvoked_test_is_reported(self) -> None:
        (self.root / "scripts/test-orphan.py").write_text("// never runs\n")
        result = self.run_report("--check")
        self.assertEqual(1, result.returncode)
        self.assertIn("test-orphan.py is not named by any gate", result.stderr)

    def test_caller_that_never_names_the_test_is_reported(self) -> None:
        check = self.root / "scripts/check.sh"
        check.write_text(check.read_text().replace("python3 scripts/test-doctor.py\n", ""))
        result = self.run_report("--check")
        self.assertEqual(1, result.returncode)
        self.assertIn("scripts/check.sh never invokes scripts/test-doctor.py", result.stderr)

    def test_status_comes_from_the_evidence_marker(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text("== package tests\ncheck: all gates passed\n")
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / "tests.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("passed", by_id["check"]["status"])
        self.assertEqual(".scratch/logs/check-1.log", by_id["check"]["evidence"])
        self.assertEqual("not_run", by_id["e2e"]["status"])
        log.write_text("FAILED (failures=1)\n")
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / "tests.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("failed", by_id["check"]["status"], "a failed log must not read as passed")

    def test_unfinished_log_is_incomplete_not_failed_or_passed(self) -> None:
        import os
        import time

        log = self.root / ".scratch/logs/check-1.log"
        log.write_text("== package tests\n")
        os.utime(log, (time.time() - 3600, time.time() - 3600))
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / "tests.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("incomplete", by_id["check"]["status"],
                         "a log with no verdict must not be reported as a result")


if __name__ == "__main__":
    unittest.main(verbosity=2)
