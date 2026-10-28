#!/usr/bin/env python3
"""Write tests.json from the real gate inventory, or check that the inventory is not lying.

The point is narrow. A status file edited by hand is a claim without an instrument, and this
repository already carries one too many of those. So:

* the inventory below is the single source, and `--check` proves each gate still exists, still has
  its test, and is still invoked by a script that names it. A test file that nothing runs is a dead
  gate, which is how the bundled-license check sat unexecuted;
* every observed status is written with the evidence path and the commit it was observed at, so a
  reader can tell a local observation from a CI result and can tell a stale claim from a fresh one.

Usage:
  scripts/tests-report.py            write tests.json for the current tree
  scripts/tests-report.py --print    print tests.json without writing
  scripts/tests-report.py --check    exit 1 when the inventory names a gate that no longer holds
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
        "id": "release-contract",
        "file": "scripts/release.sh",
        "tests": ["scripts/test-release-contract.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "project-freshness",
        "file": "scripts/check-project-fresh.sh",
        "tests": ["scripts/test-project-freshness.py"],
        "invoked_by": ["scripts/check.sh"],
    },
    {
        "id": "tests-report",
        "file": "scripts/tests-report.py",
        "tests": ["scripts/test-tests-report.py"],
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

SUITES = (
    {
        "id": "check",
        "command": "./init.sh check --unsigned",
        "evidence": ".scratch/logs/check-*.log",
    },
    {
        "id": "e2e",
        "command": "./init.sh e2e --lang all",
        "evidence": ".scratch/logs/e2e-*.log",
    },
    {
        "id": "release-dry-run",
        "command": "scripts/release.sh --dry-run",
        "evidence": ".scratch/logs/release-*.log",
    },
)

# A suite's status must come from its own terminal markers. An unfinished log has no verdict, and
# calling that "failed" would be the same lie as calling it "passed" — both invent a result.
IN_PROGRESS_SECONDS = 120


def check_status(text: str) -> str | None:
    if "check: all gates passed" in text:
        return "passed"
    if "FAILED (" in text or "\nerror: " in text:
        return "failed"
    return None


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
    return "passed"


def release_status(text: str) -> str | None:
    if "release: dry run complete" in text:
        return "passed"
    if "release:" in text and "error" in text.lower():
        return "failed"
    return None


STATUS = {"check": check_status, "e2e": e2e_status, "release-dry-run": release_status}


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


def observe(suite: dict[str, str]) -> dict[str, object]:
    """Newest evidence for one suite, with only the verdict that evidence actually shows."""
    paths = sorted(ROOT.glob(suite["evidence"]), key=lambda p: p.stat().st_mtime)
    if not paths:
        return {"id": suite["id"], "command": suite["command"], "status": "not_run", "evidence": None}
    newest = paths[-1]
    text = newest.read_text(errors="replace")
    age = datetime.now(tz=timezone.utc).timestamp() - newest.stat().st_mtime
    status = STATUS[suite["id"]](text)
    if status is None:
        status = "running" if age < IN_PROGRESS_SECONDS else "incomplete"
    return {
        "id": suite["id"],
        "command": suite["command"],
        "status": status,
        "evidence": str(newest.relative_to(ROOT)),
        "observed_at": datetime.fromtimestamp(
            newest.stat().st_mtime, tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": "local observation of the evidence file above, not a CI result",
    }


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
            text = caller_path.read_text()
            for test in gate["tests"]:  # type: ignore[union-attr]
                if pathlib.Path(test).name not in text:
                    problems.append(f"{gate['id']}: {caller} never invokes {test}")
    # A test script that no gate names is a dead gate: it exists and never runs.
    named = {pathlib.Path(t).name for gate in GATES for t in gate["tests"]}  # type: ignore[union-attr]
    for path in sorted((ROOT / "scripts").glob("test-*.py")):
        if path.name not in named:
            problems.append(f"scripts/{path.name} is not named by any gate in this inventory")
    return problems


def build() -> dict[str, object]:
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit(),
        "toolchain": toolchain(),
        "status_source": "local evidence files; CI results are separate and not recorded here",
        "suites": [observe(suite) for suite in SUITES],
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when the inventory is not true")
    parser.add_argument("--print", dest="print_only", action="store_true", help="print, do not write")
    arguments = parser.parse_args()

    problems = inventory_problems()
    if problems:
        for problem in problems:
            print(f"tests-report: {problem}", file=sys.stderr)
        return 1
    document = build()
    rendered = json.dumps(document, indent=2, sort_keys=False) + "\n"
    if arguments.print_only:
        sys.stdout.write(rendered)
        return 0
    if arguments.check:
        print(
            f"tests-report: {len(GATES)} gates, {len(SUITES)} suites, "
            f"{sum(len(g['tests']) for g in GATES)} tests, every test invoked"  # type: ignore[arg-type]
        )
        return 0
    (ROOT / "tests.json").write_text(rendered)
    print(f"tests-report: wrote tests.json at {document['commit']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
