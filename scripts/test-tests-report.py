#!/usr/bin/env python3
"""Prove the gate inventory can fail.

Each test builds a throwaway tree that satisfies the inventory, then removes exactly one thing the
inventory claims — a test file, a caller's reference to that test, or the test's presence in the
inventory — and requires a non-zero exit naming the break. A pass here means tests.json cannot go
quietly wrong in the three ways that matter: a gate without its test, a test nothing runs, and a
committed inventory that no longer matches. Run statuses are checked in the uncommitted report.
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
        # The fixture is its own repository, so evidence binds to a commit this test controls.
        for arguments in (("init", "-q"), ("add", "-A"), ("-c", "user.name=fixture", "-c",
                          "user.email=fixture@example.invalid", "commit", "-qm", "fixture")):
            subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)
        self.head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.root, check=True,
                                   capture_output=True, text=True).stdout.strip()

    def suites(self) -> dict[str, dict[str, object]]:
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / ".scratch/tests-report.json").read_text())
        return {suite["id"]: suite for suite in document["suites"]}

    def run_report(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.root / "scripts" / SCRIPT.name), *arguments],
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_clean_inventory_passes(self) -> None:
        # --check compares the committed file with the tree, so it needs one to compare.
        self.assertEqual(0, self.run_report().returncode)
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

    def test_commented_or_echoed_mention_is_not_an_invocation(self) -> None:
        check = self.root / "scripts/check.sh"
        for mention in ("# python3 scripts/test-doctor.py\n", 'echo "skipped test-doctor.py"\n',
                        ": python3 scripts/test-doctor.py\n"):
            with self.subTest(mention=mention):
                original = check.read_text()
                check.write_text(original.replace("python3 scripts/test-doctor.py\n", mention))
                result = self.run_report("--check")
                check.write_text(original)
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertIn("scripts/check.sh never invokes scripts/test-doctor.py", result.stderr)

    def test_a_pass_from_another_commit_is_stale_not_passed(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {'b' * 40} tree clean\ncheck: end tree clean\ncheck: all gates passed\n")
        suite = self.suites()["check"]
        self.assertEqual("stale", suite["status"])
        self.assertEqual("b" * 40, suite["evidence_commit"])
        log.write_text("check: end tree clean\ncheck: all gates passed\n")
        self.assertEqual("stale", self.suites()["check"]["status"], "an unbound log proves no commit")

    def test_a_dirty_tree_does_not_qualify_the_commit(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        for start, end in (("dirty", "clean"), ("clean", "dirty"), ("dirty", "dirty")):
            with self.subTest(start=start, end=end):
                log.write_text(f"check: commit {self.head} tree {start}\ncheck: end tree {end}\n"
                               "check: all gates passed\n")
                self.assertEqual("dirty", self.suites()["check"]["status"])
        log.write_text(f"check: commit {self.head} tree clean\ncheck: all gates passed\n")
        self.assertEqual("dirty", self.suites()["check"]["status"], "a pass without its end state proves nothing")

    def test_release_verdicts_count_only_for_a_dry_run_record(self) -> None:
        log = self.root / ".scratch/logs/release-1.log"
        identity = f"release: commit {self.head} tree clean\n"
        log.write_text("release: run mode dry-run\n" + identity + "release: end tree clean\n"
                       "release: dry run complete (0.1-dev, manifest m)\n")
        self.assertEqual("passed", self.suites()["release-dry-run"]["status"])
        log.write_text("release: run mode dry-run\nrelease: failed (exit 1)\n")
        self.assertEqual("failed", self.suites()["release-dry-run"]["status"],
                         "a preflight failure is a failed run, not a stale one")
        log.write_text("release: run mode release\n" + identity + "release: failed (exit 1)\n")
        self.assertEqual("not_dry_run", self.suites()["release-dry-run"]["status"])
        log.write_text("release: run mode dry-run\n" + identity + "release: end tree clean\n"
                       "release: dry run complete (0.1-dev, manifest m)\nrelease: run mode dry-run\n")
        self.assertIn(self.suites()["release-dry-run"]["status"], ("running", "incomplete"))

    def test_only_the_latest_run_in_a_log_counts(self) -> None:
        import os
        import time

        # Review §2: a pass at commit A, then only the header of a run at HEAD.
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {'a' * 40} tree clean\ncheck: end tree clean\ncheck: all gates passed\ncheck: commit {self.head} tree clean\n")
        os.utime(log, (time.time() - 3600, time.time() - 3600))
        self.assertEqual("incomplete", self.suites()["check"]["status"])
        # Older E2E summaries cannot supply the language the latest run lacks.
        english = "e2e[en]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
        portuguese = "e2e[pt-BR]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
        header = f"e2e: commit {self.head} tree clean lang all only -\n"
        (self.root / ".scratch/logs/e2e-1.log").write_text(
            header + english + portuguese + "e2e: end tree clean\ne2e: output in /tmp/a\n" + header + english + "e2e: end tree clean\ne2e: output in /tmp/b\n"
        )
        self.assertEqual("partial", self.suites()["e2e"]["status"])

    def test_a_partial_e2e_run_is_not_the_bilingual_suite(self) -> None:
        log = self.root / ".scratch/logs/e2e-1.log"
        english = "e2e[en]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
        portuguese = "e2e[pt-BR]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
        for header, body in (
            (f"e2e: commit {self.head} tree clean lang en only -\n", english),
            (f"e2e: commit {self.head} tree clean lang all only canvas-focus\n", english + portuguese),
            (f"e2e: commit {self.head} tree clean lang all only -\n", english),
        ):
            with self.subTest(header=header, body=body):
                log.write_text(header + body + "e2e: end tree clean\ne2e: output in /tmp/run\n")
                self.assertEqual("partial", self.suites()["e2e"]["status"])
        log.write_text(f"e2e: commit {self.head} tree clean lang all only -\n" + english + portuguese
                       + "e2e: end tree clean\ne2e: output in /tmp/run\n")
        self.assertEqual("passed", self.suites()["e2e"]["status"])

    def test_every_suite_script_prints_the_commit_header_the_report_reads(self) -> None:
        headers = {
            "scripts/check.sh": r'(?m)^echo "check: commit \$\(git rev-parse HEAD\) tree \$\(tree_state\)"$',
            "scripts/e2e.sh": r'(?m)^echo "e2e: commit \$\(git rev-parse HEAD\) tree \$\(tree_state\) lang \$lang only \$\{only:--\}"$',
            "scripts/release.sh": r'(?m)^echo "release: commit \$source_commit tree \$\(tree_state\)"$',
        }
        ends = {"scripts/check.sh": "check", "scripts/e2e.sh": "e2e", "scripts/release.sh": "release"}
        for script, prefix in ends.items():
            with self.subTest(script=script, end=True):
                text = (ROOT / script).read_text()
                self.assertIn(f'echo "{prefix}: end tree $(tree_state)"', text)
                self.assertIn('tree_state() { local s; s=$(git status --porcelain --untracked-files=all) || { echo unknown; return; }; [[ -z $s ]] && echo clean || echo dirty; }', text)
        for script, header in headers.items():
            with self.subTest(script=script):
                self.assertRegex((ROOT / script).read_text(), header)

    def test_status_comes_from_the_evidence_marker(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\n== package tests\ncheck: end tree clean\ncheck: all gates passed\n")
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / ".scratch/tests-report.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("passed", by_id["check"]["status"])
        self.assertEqual(".scratch/logs/check-1.log", by_id["check"]["evidence"])
        self.assertEqual("not_run", by_id["e2e"]["status"])
        log.write_text(f"check: commit {self.head} tree clean\nFAILED (failures=1)\n")
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / ".scratch/tests-report.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("failed", by_id["check"]["status"], "a failed log must not read as passed")

    def test_unfinished_log_is_incomplete_not_failed_or_passed(self) -> None:
        import os
        import time

        log = self.root / ".scratch/logs/check-1.log"
        log.write_text("== package tests\n")
        os.utime(log, (time.time() - 3600, time.time() - 3600))
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / ".scratch/tests-report.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("incomplete", by_id["check"]["status"],
                         "a log with no verdict must not be reported as a result")


    def test_committed_inventory_carries_no_run_status(self) -> None:
        # A status committed at commit X can never be true for X, so only the report holds runs.
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\ncheck: end tree clean\ncheck: all gates passed\n")
        self.assertEqual(0, self.run_report().returncode)
        inventory = json.loads((self.root / "tests.json").read_text())
        self.assertEqual({"schema_version", "suites", "gates"}, set(inventory))
        for suite in inventory["suites"]:
            self.assertEqual({"id", "command", "evidence"}, set(suite))
        self.assertEqual("passed", self.suites()["check"]["status"])

    def test_check_validates_the_inventory_not_the_runs(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\ncheck: end tree clean\ncheck: all gates passed\n")
        self.assertEqual(0, self.run_report().returncode)
        log.write_text(f"check: commit {self.head} tree clean\nFAILED (failures=1)\n")
        result = self.run_report("--check")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_a_recorded_suite_inventory_that_drifted_is_reported(self) -> None:
        self.assertEqual(0, self.run_report().returncode)
        path = self.root / "tests.json"
        document = json.loads(path.read_text())
        document["suites"][0]["command"] = "./init.sh check"
        path.write_text(json.dumps(document))
        result = self.run_report("--check")
        self.assertEqual(1, result.returncode)
        self.assertIn("different suite inventory", result.stderr)

    def test_a_later_failure_is_not_hidden_by_an_earlier_pass(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\ncheck: end tree clean\ncheck: all gates passed\nFAILED (failures=1)\n")
        self.assertEqual(0, self.run_report().returncode)
        document = json.loads((self.root / ".scratch/tests-report.json").read_text())
        by_id = {suite["id"]: suite for suite in document["suites"]}
        self.assertEqual("failed", by_id["check"]["status"])

    def test_a_recorded_gate_inventory_that_drifted_is_reported(self) -> None:
        self.assertEqual(0, self.run_report().returncode)
        path = self.root / "tests.json"
        document = json.loads(path.read_text())
        document["gates"] = document["gates"][:-1]
        path.write_text(json.dumps(document))
        result = self.run_report("--check")
        self.assertEqual(1, result.returncode)
        self.assertIn("different gate inventory", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
