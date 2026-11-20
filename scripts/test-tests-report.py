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
                    # A gate test stub records that it ran; other protected files are never run.
                    path.write_text(f"open('ran.txt', 'a').write('{relative}\\n')\n"
                                    if relative in gate["tests"] else "// fixture\n")
        self.tests = [t for gate in self.gates for t in gate["tests"]]
        self.ran = f"tests-report: ran {len(self.tests)} gate tests\n"
        for caller in {c for gate in self.gates for c in gate["invoked_by"]}:
            runs = any(caller in gate["invoked_by"] and gate["tests"] for gate in self.gates)
            path = self.root / caller
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\n" + ("python3 scripts/tests-report.py --run-tests\n" if runs else ""))
        # The fixture is its own repository, so evidence binds to a commit this test controls.
        for arguments in (("init", "-q"), ("add", "-A"), ("-c", "user.name=fixture", "-c",
                          "user.email=fixture@example.invalid", "commit", "-qm", "fixture")):
            subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)
        self.head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.root, check=True,
                                   capture_output=True, text=True).stdout.strip()

    def e2e_output(self, *, provenance_sha: str | None = "", languages: tuple[str, ...] = ("en", "pt-BR"),
                   report: list[dict[str, object]] | None = None) -> pathlib.Path:
        """An E2E output directory as e2e.sh leaves it: provenance names HEAD unless told otherwise,
        and each report.json holds one passing scenario unless `report` replaces it."""
        run = pathlib.Path(tempfile.mkdtemp(dir=self.root / ".scratch"))
        scenarios = [{"id": "editor", "passed": True, "screenshots": [], "assertions": []}] if report is None else report
        for language in languages:
            (run / language).mkdir()
            (run / language / "report.json").write_text(json.dumps(scenarios))
            if provenance_sha is not None:
                (run / language / "provenance.json").write_text(json.dumps({"git_sha": provenance_sha or self.head}))
        return run

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

    def test_caller_that_stops_running_the_gate_tests_is_reported(self) -> None:
        check = self.root / "scripts/check.sh"
        original = check.read_text()
        for replacement in ("", "# python3 scripts/tests-report.py --run-tests\n",
                            'echo "python3 scripts/tests-report.py --run-tests"\n'):
            with self.subTest(replacement=replacement):
                check.write_text(original.replace("python3 scripts/tests-report.py --run-tests\n", replacement))
                result = self.run_report("--check")
                check.write_text(original)
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertIn("scripts/check.sh never runs `python3 scripts/tests-report.py --run-tests`",
                              result.stderr)

    def test_run_tests_runs_exactly_the_listed_tests(self) -> None:
        result = self.run_report("--run-tests")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(self.tests, (self.root / "ran.txt").read_text().splitlines())
        self.assertEqual(self.ran, result.stdout.splitlines(keepends=True)[-1])

    def test_run_tests_stops_at_a_failing_test(self) -> None:
        (self.root / "scripts/test-doctor.py").write_text("raise SystemExit(3)\n")
        result = self.run_report("--run-tests")
        self.assertEqual(1, result.returncode)
        self.assertIn("scripts/test-doctor.py failed (exit 3)", result.stderr)
        self.assertNotIn("gate tests", result.stdout)

    def test_a_check_pass_needs_this_runs_completion_line(self) -> None:
        # A dead branch still reads as a command line; only the run's own output proves the tests ran.
        log = self.root / ".scratch/logs/check-1.log"
        for ran in ("", f"tests-report: ran {len(self.tests) - 1} gate tests\n"):
            with self.subTest(ran=ran):
                log.write_text(f"check: commit {self.head} tree clean\n{ran}check: end commit {self.head} tree clean\n"
                               "check: all gates passed\n")
                self.assertEqual("failed", self.suites()["check"]["status"])

    def test_a_pass_from_another_commit_is_stale_not_passed(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {'b' * 40} tree clean\n{self.ran}check: end commit {'b' * 40} tree clean\ncheck: all gates passed\n")
        suite = self.suites()["check"]
        self.assertEqual("stale", suite["status"])
        self.assertEqual("b" * 40, suite["evidence_commit"])
        log.write_text("check: end tree clean\ncheck: all gates passed\n")
        self.assertEqual("stale", self.suites()["check"]["status"], "an unbound log proves no commit")

    def test_a_dirty_tree_does_not_qualify_the_commit(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        for start, end in (("dirty", "clean"), ("clean", "dirty"), ("dirty", "dirty")):
            with self.subTest(start=start, end=end):
                log.write_text(f"check: commit {self.head} tree {start}\n{self.ran}check: end commit {self.head} tree {end}\n"
                               "check: all gates passed\n")
                self.assertEqual("dirty", self.suites()["check"]["status"])
        log.write_text(f"check: commit {self.head} tree clean\n{self.ran}check: all gates passed\n")
        self.assertEqual("dirty", self.suites()["check"]["status"], "a pass without its end state proves nothing")

    def test_a_run_that_ends_on_another_commit_does_not_qualify(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\n{self.ran}check: end commit {'b' * 40} tree clean\n"
                       "check: all gates passed\n")
        self.assertEqual("moved", self.suites()["check"]["status"])

    def test_release_verdicts_count_only_for_a_dry_run_record(self) -> None:
        log = self.root / ".scratch/logs/release-1.log"
        identity = f"release: commit {self.head} tree clean\n"
        log.write_text("release: run mode dry-run\n" + identity + f"release: end commit {self.head} tree clean\n"
                       "release: dry run complete (0.1-dev, manifest m)\n")
        self.assertEqual("passed", self.suites()["release-dry-run"]["status"])
        log.write_text("release: run mode dry-run\nrelease: failed (exit 1)\n")
        self.assertEqual("failed", self.suites()["release-dry-run"]["status"],
                         "a preflight failure is a failed run, not a stale one")
        log.write_text("release: run mode release\n" + identity + "release: failed (exit 1)\n")
        self.assertEqual("not_dry_run", self.suites()["release-dry-run"]["status"])
        log.write_text("release: run mode dry-run\n" + identity + f"release: end commit {self.head} tree clean\n"
                       "release: dry run complete (0.1-dev, manifest m)\nrelease: run mode dry-run\n")
        self.assertIn(self.suites()["release-dry-run"]["status"], ("running", "incomplete"))

    def test_only_the_latest_run_in_a_log_counts(self) -> None:
        import os
        import time

        # Review §2: a pass at commit A, then only the header of a run at HEAD.
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {'a' * 40} tree clean\ncheck: end commit {'a' * 40} tree clean\ncheck: all gates passed\ncheck: commit {self.head} tree clean\n")
        os.utime(log, (time.time() - 3600, time.time() - 3600))
        self.assertEqual("incomplete", self.suites()["check"]["status"])
        # Older E2E summaries cannot supply the language the latest run lacks.
        english = "e2e[en]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
        portuguese = "e2e[pt-BR]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
        header = f"e2e: commit {self.head} tree clean lang all only -\n"
        (self.root / ".scratch/logs/e2e-1.log").write_text(
            header + english + portuguese + f"e2e: end commit {self.head} tree clean\ne2e: output in /tmp/a\n" + header + english
            + f"e2e: end commit {self.head} tree clean\ne2e: output in /tmp/b\n"
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
                log.write_text(header + body + f"e2e: end commit {self.head} tree clean\ne2e: output in /tmp/run\n")
                self.assertEqual("partial", self.suites()["e2e"]["status"])
        log.write_text(f"e2e: commit {self.head} tree clean lang all only -\n" + english + portuguese
                       + f"e2e: end commit {self.head} tree clean\ne2e: output in {self.e2e_output()}\n")
        self.assertEqual("passed", self.suites()["e2e"]["status"])

    def test_an_e2e_language_counts_only_with_a_matching_report(self) -> None:
        log = self.root / ".scratch/logs/e2e-1.log"

        def write(total: str, output: pathlib.Path) -> None:
            summaries = "".join(f"e2e[{language}]: {total} scenarios passed, 0 screenshots (exit 0)\n"
                                for language in ("en", "pt-BR"))
            log.write_text(f"e2e: commit {self.head} tree clean lang all only -\n" + summaries
                           + f"e2e: end commit {self.head} tree clean\ne2e: output in {output}\n")

        missing = self.e2e_output()
        for language in ("en", "pt-BR"):
            (missing / language / "report.json").unlink()
        two = {"id": "a", "passed": True}
        for name, total, output in (
            ("missing reports", "1/1", missing),
            ("empty reports", "1/1", self.e2e_output(report=[])),
            ("count mismatch", "1/1", self.e2e_output(report=[two, dict(two, id="b")])),
            ("pass mismatch", "1/1", self.e2e_output(report=[dict(two, passed=False)])),
        ):
            with self.subTest(name):
                write(total, output)
                self.assertEqual("partial", self.suites()["e2e"]["status"])
        with self.subTest("0/0"):
            write("0/0", self.e2e_output(report=[]))
            self.assertEqual("failed", self.suites()["e2e"]["status"])

    def test_e2e_provenance_must_name_the_runs_commit(self) -> None:
        log = self.root / ".scratch/logs/e2e-1.log"
        summaries = "".join(f"e2e[{language}]: 1/1 scenarios passed, 2 screenshots (exit 0)\n"
                            for language in ("en", "pt-BR"))
        for output in (self.e2e_output(provenance_sha="b" * 40), self.e2e_output(provenance_sha=None)):
            with self.subTest(output=output):
                log.write_text(f"e2e: commit {self.head} tree clean lang all only -\n" + summaries
                               + f"e2e: end commit {self.head} tree clean\ne2e: output in {output}\n")
                self.assertEqual("stale", self.suites()["e2e"]["status"])

    def test_every_suite_script_prints_the_identity_the_report_reads(self) -> None:
        lines = {
            "scripts/check.sh": ('echo "check: $(run_identity)"', 'echo "check: end $(run_identity)"'),
            "scripts/e2e.sh": ('echo "e2e: $(run_identity) lang $lang only ${only:--}"', 'echo "e2e: end $(run_identity)"'),
            "scripts/release.sh": ('echo "release: $(run_identity)"', 'echo "release: end $(run_identity)"'),
        }
        for script, (start_line, end_line) in lines.items():
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                self.assertRegex(text, r"(?m)^source scripts/lib/run-identity\.sh$")
                self.assertIn(start_line, text)
                self.assertIn(end_line, text)
                self.assertNotIn("tree_state", text, "one shared helper, not a copy per script")

    def test_run_identity_names_the_commit_and_tree_state(self) -> None:
        helper = ROOT / "scripts/lib/run-identity.sh"
        def identity(directory: pathlib.Path) -> str:
            return subprocess.run(["/bin/zsh", "-c", f"source {helper}; run_identity"], cwd=directory,
                                  capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(f"commit {self.head} tree clean", identity(self.root))
        (self.root / "untracked.txt").write_text("new\n")
        self.assertEqual(f"commit {self.head} tree dirty", identity(self.root))
        with tempfile.TemporaryDirectory() as outside:
            self.assertEqual("commit unknown tree unknown", identity(pathlib.Path(outside)))

    def test_status_comes_from_the_evidence_marker(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\n== package tests\n{self.ran}check: end commit {self.head} tree clean\ncheck: all gates passed\n")
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
        log.write_text(f"check: commit {self.head} tree clean\n{self.ran}check: end commit {self.head} tree clean\ncheck: all gates passed\n")
        self.assertEqual(0, self.run_report().returncode)
        inventory = json.loads((self.root / "tests.json").read_text())
        self.assertEqual({"schema_version", "suites", "gates"}, set(inventory))
        for suite in inventory["suites"]:
            self.assertEqual({"id", "command", "evidence"}, set(suite))
        self.assertEqual("passed", self.suites()["check"]["status"])

    def test_check_validates_the_inventory_not_the_runs(self) -> None:
        log = self.root / ".scratch/logs/check-1.log"
        log.write_text(f"check: commit {self.head} tree clean\n{self.ran}check: end commit {self.head} tree clean\ncheck: all gates passed\n")
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
        log.write_text(f"check: commit {self.head} tree clean\n{self.ran}check: end commit {self.head} tree clean\ncheck: all gates passed\nFAILED (failures=1)\n")
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


class CheckGateRunsTheListTests(unittest.TestCase):
    """Review 2 F03: check.sh itself fails unless its own --run-tests step reported the whole list.
    Builds, lint and the inventory are stubbed; only check.sh's control flow is under test."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.check = scripts / "check.sh"
        shutil.copy(ROOT / "scripts/check.sh", self.check)
        for helper in ROOT.glob("scripts/lib/*.sh"):
            (scripts / "lib").mkdir(exist_ok=True)
            shutil.copy(helper, scripts / "lib" / helper.name)
        stubs = {
            "doctor.sh": "#!/bin/sh\nexit 0\n",
            "check-project-fresh.sh": "#!/bin/sh\nexit 0\n",
            "check-localization.py": "#!/bin/sh\nexit 0\n",
            # The dispatcher: --run-tests prints the completion line for STUB_RAN tests.
            "tests-report.py": (
                "import os, sys\n"
                "if sys.argv[1:] == ['--run-tests']:\n"
                "    print(f\"tests-report: ran {os.environ.get('STUB_RAN', '10')} gate tests\")\n"
                "elif sys.argv[1:] == ['--count']:\n"
                "    print(10)\n"
            ),
        }
        for name, source in stubs.items():
            (scripts / name).write_text(source)
            (scripts / name).chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("xcrun", "xcodebuild"):
            (self.bin / tool).write_text("#!/bin/sh\nexit 0\n")
            (self.bin / tool).chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)

    def run_check(self, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/zsh", str(self.check), "--unsigned"], cwd=self.root, capture_output=True, text=True,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "DEVELOPER_DIR": "/fixture", **environment},
            timeout=30,
        )

    def test_control_the_stubbed_gate_passes(self) -> None:
        result = self.run_check()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("check: all gates passed", result.stdout.strip().splitlines()[-1])

    def test_a_disabled_dispatcher_fails_the_gate(self) -> None:
        # Review 2 §2: the dispatcher inside `if false`.
        original = self.check.read_text()
        step = "python3 scripts/tests-report.py --run-tests"
        self.assertEqual(1, original.count(step))
        line_start = original.rindex("\n", 0, original.index(step)) + 1
        line_end = original.index("\n", original.index(step)) + 1
        line = original[line_start:line_end]
        self.check.write_text(original[:line_start] + "if false; then\n" + line + "fi\n" + original[line_end:])
        result = self.run_check()
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertNotIn("check: all gates passed", result.stdout)

    def test_a_short_run_of_the_list_fails_the_gate(self) -> None:
        result = self.run_check(STUB_RAN="9")
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertNotIn("check: all gates passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
