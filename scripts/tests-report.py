#!/usr/bin/env python3
"""Write the gate inventory to tests.json and the observed runs to an uncommitted report.

A status file edited by hand is a claim without an instrument, and a status committed at commit X
can never be true for X. So:

* GATES below is the one list of gate tests: `--run-tests` (called by check.sh) runs exactly those
  tests and ends with `tests-report: ran <N> gate tests`, and a check log without that line for the
  current N is not a pass, so a heredoc or a dead branch cannot stand in for running them;
* tests.json holds only the inventory: each suite, each gate's test scripts and the scripts that
  run them. `--check` proves each gate still exists and still has its test, that every
  scripts/test-*.py is in the list, that each caller still has the `--run-tests` command line, and
  that tests.json still records this inventory. A test file that nothing runs is a dead gate;
* run statuses go to .scratch/tests-report.json, never committed. Each comes from the latest run
  in a log, which records its commit and tree at both ends (scripts/lib/run-identity.sh). A
  verdict from another commit, or from a log that records none, is `stale`; a dirty tree is
  `dirty`, a commit change during the run `moved`; an E2E run of one language or of selected
  scenarios is `partial`, and one whose provenance names another commit `stale`.

Usage:
  scripts/tests-report.py            write tests.json and .scratch/tests-report.json
  scripts/tests-report.py --print    print the run report without writing
  scripts/tests-report.py --check    exit 1 when the inventory no longer holds
  scripts/tests-report.py --run-tests  run every gate test in the list, stopping at a failure
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent

# One entry per gate. `file` is what the gate protects, `tests` is what proves the gate, and
# `invoked_by` is the script that must name the test, so a test cannot exist uninvoked.
GATES: list[dict[str, object]] = [
    {
        "id": "toolchain",
        "file": "scripts/doctor.sh",
        "tests": ["scripts/test-doctor.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "e2e-isolation",
        "file": "scripts/e2e.sh",
        "tests": ["scripts/test-e2e-isolation.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "localization",
        "file": "scripts/check-localization.py",
        "tests": ["scripts/test-localization.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "release-entitlements",
        "file": "scripts/check-release-entitlements.py",
        "tests": ["scripts/test-release-entitlements.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "release-binary",
        "file": "scripts/check-release-binary.sh",
        "tests": ["scripts/test-release-binary.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "release-build",
        "file": "scripts/check-release-build.sh",
        "tests": [],
        "invoked_by": [".github/workflows/ci.yml"],
    },
    {
        "id": "release-contract",
        "file": "scripts/release.sh",
        "tests": ["scripts/test-release-contract.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "project-freshness",
        "file": "scripts/check-project-fresh.sh",
        "tests": ["scripts/test-project-freshness.py", "scripts/test-xcodegen-wrapper.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "space-probe",
        "file": "scripts/space-probe/run.sh",
        "tests": ["scripts/test-space-probe.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "tests-report",
        "file": "scripts/tests-report.py",
        "tests": ["scripts/test-tests-report.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "deployment-target",
        "file": "scripts/check-deployment-target.py",
        "tests": ["scripts/test-deployment-target.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "updater-plist",
        "file": "scripts/check-updater-plist.py",
        "tests": ["scripts/test-updater-plist.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "package-tests",
        "file": "Packages/RecortiaKit/Package.swift",
        "tests": [],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "native-e2e",
        "file": "RecortiaApp/E2E/E2EScenarios.swift",
        "tests": [],
        "invoked_by": ["scripts/e2e.sh"],
    },
]

# `prefix` is how the suite's script names itself in its log; `start` begins each run in it.
SUITES = (
    {
        "id": "check",
        "command": "./init.sh check --unsigned",
        "evidence": ".scratch/logs/check-*.log",
        "prefix": "check",
        "start": "check: commit ",
    },
    {
        "id": "e2e",
        "command": "./init.sh e2e --lang all",
        "evidence": ".scratch/logs/e2e-*.log",
        "prefix": "e2e",
        "start": "e2e: commit ",
    },
    {
        "id": "release-dry-run",
        "command": "scripts/release.sh --dry-run",
        "evidence": ".scratch/logs/release-*.log",
        "prefix": "release",
        # release.sh names its mode before preflight and its commit only after it.
        "start": "release: run mode ",
    },
)

# A suite's status must come from its own terminal markers. An unfinished log has no verdict, and
# calling that "failed" would be the same lie as calling it "passed" — both invent a result.
IN_PROGRESS_SECONDS = 120


def last_marker(text: str, markers: tuple[str, ...]) -> tuple[int, str] | None:
    """The last occurrence of any marker, so an appended log cannot hide a later failure."""
    found: list[tuple[int, str]] = []
    for marker in markers:
        index = text.rfind(marker)
        if index >= 0:
            found.append((index, marker))
    return max(found) if found else None


RUN_TESTS = "python3 scripts/tests-report.py --run-tests"


def gate_tests() -> list[str]:
    return [test for gate in GATES for test in gate["tests"]]  # type: ignore[union-attr]


def check_status(text: str) -> str | None:
    markers = last_marker(text, ("check: all gates passed", "FAILED (", "\nerror: "))
    if markers is None:
        return None
    if markers[1] != "check: all gates passed":
        return "failed"
    # The completion line only --run-tests prints proves every listed test ran in this run.
    ran = f"tests-report: ran {len(gate_tests())} gate tests"
    return "passed" if re.search(rf"(?m)^{re.escape(ran)}$", text) else "failed"


def e2e_status(text: str) -> str | None:
    if "e2e: output in" not in text:
        return None
    summary = [line for line in text.splitlines() if line.startswith("e2e[")]
    if not summary:
        return "failed"
    for line in summary:
        match = re.search(r"(\d+)/(\d+) scenarios passed", line)
        if match is None or match.group(1) != match.group(2) or "(exit 0)" not in line:
            return "failed"
        if match.group(2) == "0":
            return "failed"  # a run of no scenarios proves nothing
    return "passed"


def release_status(text: str) -> str | None:
    # scripts/release.sh prints exactly one of these as its last line.
    markers = last_marker(text, ("release: dry run complete", "release: failed ("))
    if markers is None:
        return None
    return "passed" if markers[1] == "release: dry run complete" else "failed"


STATUS = {"check": check_status, "e2e": e2e_status, "release-dry-run": release_status}


def latest_run(text: str, start: str) -> str | None:
    """The latest run in an appended log: its own header through the end of the file."""
    starts = list(re.finditer(rf"(?m)^{re.escape(start)}", text))
    return text[starts[-1].start():] if starts else None


def evidence_commit(run: str, prefix: str) -> str | None:
    found = re.search(rf"(?m)^{re.escape(prefix)}: commit ([0-9a-f]{{40}})\b", run)
    return found.group(1) if found else None


def source_state(run: str, prefix: str) -> str:
    """`clean` when the run started and ended on the same commit with a clean tree (the identity
    scripts/lib/run-identity.sh prints at both ends), `moved` when the commit changed, else `dirty`."""
    start = re.search(rf"(?m)^{re.escape(prefix)}: commit ([0-9a-f]{{40}}) tree (\S+)", run)
    ends = re.findall(rf"(?m)^{re.escape(prefix)}: end commit (\S+) tree (\S+)$", run)
    if start is None or not ends:
        return "dirty"
    if ends[-1][0] != start.group(1):
        return "moved"
    return "clean" if start.group(2) == "clean" and ends[-1][1] == "clean" else "dirty"


def e2e_output_directory(run: str) -> pathlib.Path | None:
    found = re.findall(r"(?m)^e2e: output in (.+)$", run)
    return pathlib.Path(found[-1]) if found else None


def e2e_provenance_matches(run: str, sha: str) -> bool:
    """Each language's provenance.json must name the commit the run's header names."""
    output = e2e_output_directory(run)
    if output is None:
        return False
    for language in ("en", "pt-BR"):
        try:
            record = json.loads((output / language / "provenance.json").read_text())
        except (OSError, json.JSONDecodeError):
            return False
        if not isinstance(record, dict) or record.get("git_sha") != sha:
            return False
    return True


def e2e_is_full_suite(text: str) -> bool:
    """Both languages and every scenario: the selection the suite's command names."""
    headers = re.findall(r"(?m)^e2e: commit [0-9a-f]{40} tree \S+ lang (\S+) only (\S+)$", text)
    if not headers or headers[-1] != ("all", "-"):
        return False
    return e2e_reported_languages(text) == {"en", "pt-BR"}


def e2e_reported_languages(run: str) -> set[str]:
    """Languages whose summary line is backed by a nonempty report.json with the same counts."""
    output = e2e_output_directory(run)
    counted: set[str] = set()
    for language, passed, total in re.findall(r"(?m)^e2e\[([^\]]+)\]: (\d+)/(\d+) scenarios passed", run):
        if output is None:
            break
        try:
            results = json.loads((output / language / "report.json").read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(results, list) or not results or not all(isinstance(r, dict) for r in results):
            continue
        if len(results) == int(total) and sum(r.get("passed") is True for r in results) == int(passed):
            counted.add(language)
    return counted


def commit() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=False
    )
    return result.stdout.strip() or "unknown"


def toolchain() -> dict[str, str]:
    try:
        record = json.loads((ROOT / "TOOLCHAIN.json").read_text())
    except (OSError, json.JSONDecodeError):
        return {"xcode": "unknown", "mode": "unknown"}
    return {
        "xcode": f"{record.get('actual_xcode_version', '?')} ({record.get('actual_xcode_build', '?')})",
        "channel": str(record.get("actual_xcode_release_channel", "?")),
        "stable_baseline": (
            f"{record.get('stable_xcode_baseline', {}).get('version', '?')} "
            f"({record.get('stable_xcode_baseline', {}).get('build', '?')})"
        ),
    }


def observe(suite: dict[str, str], head: str) -> dict[str, object]:
    """Newest evidence for one suite, with only the verdict that evidence actually shows."""
    paths = sorted(ROOT.glob(suite["evidence"]), key=lambda p: p.stat().st_mtime)
    if not paths:
        return {"id": suite["id"], "command": suite["command"], "status": "not_run", "evidence": None}
    newest = paths[-1]
    text = newest.read_text(errors="replace")
    age = datetime.now(tz=timezone.utc).timestamp() - newest.stat().st_mtime
    # One run is one record: a verdict or summary from an earlier run in the same log never counts.
    run = latest_run(text, suite["start"])
    status = STATUS[suite["id"]](text if run is None else run)
    ran_at = None if run is None else evidence_commit(run, suite["prefix"])
    if status is None:
        status = "running" if age < IN_PROGRESS_SECONDS else "incomplete"
    elif suite["id"] == "release-dry-run" and run is not None and not run.startswith("release: run mode dry-run\n"):
        status = "not_dry_run"
    elif status == "failed" and run is not None and ran_at is None:
        # Failed in preflight, before naming a commit: a failure, never credited to another commit.
        pass
    elif ran_at != head:
        # A verdict proves only the commit it ran at; the report speaks for HEAD.
        status = "stale"
    elif status == "passed" and (state := source_state(run or "", suite["prefix"])) != "clean":
        # Uncommitted changes, or another commit by the end, were tested, not HEAD.
        status = state
    elif suite["id"] == "e2e" and status == "passed" and not e2e_is_full_suite(run or ""):
        status = "partial"
    elif suite["id"] == "e2e" and status == "passed" and not e2e_provenance_matches(run or "", head):
        status = "stale"
    return {
        "id": suite["id"],
        "command": suite["command"],
        "status": status,
        "evidence": str(newest.relative_to(ROOT)),
        "evidence_commit": ran_at,
        "observed_at": datetime.fromtimestamp(
            newest.stat().st_mtime, tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": "local observation of the evidence file above, not a CI result",
    }


REQUIRED_CHECK_STEPS: tuple[tuple[str, str], ...] = (
    ("scripts/doctor.sh", r"^scripts/doctor\.sh(?:\s|$)"),
    ("swift format lint --strict", r"^(?:xcrun\s+)?swift\s+format\s+lint\b.*--strict\b"),
    ("scripts/check-project-fresh.sh", r"^scripts/check-project-fresh\.sh(?:\s|$)"),
    ("swift test", r"^(?:xcrun\s+)?swift\s+test\b.*--package-path\s+Packages/RecortiaKit\b"),
    ("scripts/check-localization.py", r"^(?:python3\s+)?scripts/check-localization\.py(?:\s|$)"),
    (
        "RECORTIA_E2E_BINARY launch guard",
        r"^RECORTIA_E2E_BINARY=\S+\s+python3\s+scripts/test-e2e-isolation\.py\b",
    ),
)


def script_commands(script: str) -> list[str]:
    """Logical non-comment, non-echo command lines, joining trailing backslash continuations."""
    commands: list[str] = []
    pending = ""
    for raw in script.splitlines():
        stripped = raw.strip()
        if not pending and (not stripped or stripped.startswith("#")):
            continue
        if stripped.endswith("\\"):
            pending += stripped[:-1].rstrip() + " "
            continue
        line = (pending + stripped).strip()
        pending = ""
        if not line or line.startswith("#"):
            continue
        first = line.split(None, 1)[0]
        if first in ("echo", "print"):
            continue
        commands.append(line)
    if pending.strip():
        commands.append(pending.strip())
    return commands


def runs_gate_tests(script: str) -> bool:
    """A command line starting `python3 scripts/tests-report.py --run-tests`, not a comment or an
    echo. check.sh itself refuses to pass unless that step printed the completion line."""
    return any(line.strip() == RUN_TESTS or line.strip().startswith(RUN_TESTS + " ")
               for line in script.splitlines())


def missing_check_steps(script: str) -> list[str]:
    commands = script_commands(script)
    return [
        label
        for label, pattern in REQUIRED_CHECK_STEPS
        if not any(re.search(pattern, command) for command in commands)
    ]


def run_tests() -> int:
    """Run every gate test from the one list, in order; the first failure stops the run."""
    tests = gate_tests()
    for test in tests:
        print(f"== {test}", flush=True)
        result = subprocess.run([sys.executable, test], cwd=ROOT, check=False)
        if result.returncode != 0:
            print(f"tests-report: {test} failed (exit {result.returncode})", file=sys.stderr)
            return 1
    print(f"tests-report: ran {len(tests)} gate tests")
    return 0


def inventory_problems() -> list[str]:
    problems: list[str] = []
    for gate in GATES:
        if not (ROOT / str(gate["file"])).exists():
            problems.append(f"{gate['id']}: protected file {gate['file']} is missing")
        for test in gate["tests"]:  # type: ignore[union-attr]
            if not (ROOT / test).exists():
                problems.append(f"{gate['id']}: test {test} is missing")
        callers = gate["invoked_by"]
        assert isinstance(callers, list)
        for caller in callers:
            caller_path = ROOT / caller
            if not caller_path.exists():
                problems.append(f"{gate['id']}: caller {caller} is missing")
                continue
            if gate["tests"] and not runs_gate_tests(caller_path.read_text()):
                problems.append(f"{gate['id']}: {caller} never runs `{RUN_TESTS}`")
    check_script = ROOT / "scripts/check.sh"
    if check_script.exists():
        for missing in missing_check_steps(check_script.read_text()):
            problems.append(f"scripts/check.sh never runs required gate step `{missing}`")
    named = {pathlib.Path(t).name for gate in GATES for t in gate["tests"]}  # type: ignore[union-attr]
    for path in sorted((ROOT / "scripts").glob("test-*.py")):
        if path.name not in named:
            problems.append(f"scripts/{path.name} is not named by any gate in this inventory")
    return problems


REPORT = ROOT / ".scratch/tests-report.json"


def inventory() -> dict[str, object]:
    """What tests.json commits: true for every commit that has this tree's scripts."""
    return {
        "schema_version": 2,
        "suites": [
            {"id": suite["id"], "command": suite["command"], "evidence": suite["evidence"]}
            for suite in SUITES
        ],
        "gates": [
            {
                "id": gate["id"],
                "protected_file": gate["file"],
                "tests": gate["tests"],
                "invoked_by": gate["invoked_by"],
            }
            for gate in GATES
        ],
    }


def report() -> dict[str, object]:
    """The observed runs for HEAD; written under .scratch, never committed."""
    head = commit()
    return {
        "schema_version": 2,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": head,
        "toolchain": toolchain(),
        "status_source": "local evidence files; CI results are separate and not recorded here",
        "suites": [observe(suite, head) for suite in SUITES],
        "gates": inventory()["gates"],
    }


def drift_problems(fresh: dict[str, object]) -> list[str]:
    """Fail when the committed tests.json no longer describes this tree's inventory."""
    path = ROOT / "tests.json"
    if not path.exists():
        return ["tests.json is missing; run scripts/tests-report.py"]
    try:
        recorded = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        return [f"tests.json is not valid JSON: {error}"]
    if not isinstance(recorded, dict):
        return ["tests.json is not an object; regenerate it"]
    problems: list[str] = []
    if recorded.get("gates") != fresh["gates"]:
        problems.append("tests.json records a different gate inventory; regenerate it")
    if recorded.get("suites") != fresh["suites"]:
        problems.append("tests.json records a different suite inventory; regenerate it")
    if recorded != fresh and not problems:
        problems.append("tests.json records more than the inventory; regenerate it")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when the inventory is not true")
    parser.add_argument("--print", dest="print_only", action="store_true", help="print, do not write")
    parser.add_argument("--run-tests", action="store_true", help="run every gate test in the list")
    parser.add_argument("--count", action="store_true", help="print how many gate tests the list has")
    arguments = parser.parse_args()

    problems = inventory_problems()
    if problems:
        for problem in problems:
            print(f"tests-report: {problem}", file=sys.stderr)
        return 1
    if arguments.count:
        print(len(gate_tests()))
        return 0
    if arguments.run_tests:
        return run_tests()
    if arguments.check:
        problems = drift_problems(inventory())
        if problems:
            for problem in problems:
                print(f"tests-report: {problem}", file=sys.stderr)
            return 1
        print(
            f"tests-report: {len(GATES)} gates, {len(SUITES)} suites, "
            f"{sum(len(g['tests']) for g in GATES)} tests, every test run by --run-tests"  # type: ignore[arg-type]
        )
        return 0
    observed = json.dumps(report(), indent=2) + "\n"
    if arguments.print_only:
        sys.stdout.write(observed)
        return 0
    (ROOT / "tests.json").write_text(json.dumps(inventory(), indent=2) + "\n")
    REPORT.parent.mkdir(exist_ok=True)
    REPORT.write_text(observed)
    print(f"tests-report: wrote tests.json and {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
