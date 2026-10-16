#!/usr/bin/env python3
"""The generated-project gate must compare against git, so a stale committed project fails every run."""

import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts/check-project-fresh.sh"
PROJECT = "Recortia.xcodeproj/project.pbxproj"


def git(repository: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repository, check=True, capture_output=True)


class Fixture:
    """A throwaway repository with a committed project and a fake `xcodegen` that writes `generated`."""

    def __init__(self, directory: pathlib.Path, *, committed: str, generated: str, extra: str | None = None) -> None:
        self.repository = directory / "repo"
        (self.repository / "scripts").mkdir(parents=True)
        shutil.copy(GATE, self.repository / "scripts/check-project-fresh.sh")
        (self.repository / "Recortia.xcodeproj").mkdir()
        (self.repository / PROJECT).write_text(committed)
        git(self.repository, "init", "-q")
        git(self.repository, "config", "user.name", "Freshness Test")
        git(self.repository, "config", "user.email", "freshness@example.invalid")
        git(self.repository, "add", "-A")
        git(self.repository, "commit", "-qm", "committed project")
        self.bin = directory / "bin"
        self.bin.mkdir()
        stub = self.bin / "xcodegen"
        extra_line = f"printf 'extra' > Recortia.xcodeproj/{extra}\n" if extra else ""
        stub.write_text(f"#!/bin/sh\nprintf '%s' '{generated}' > {PROJECT}\n{extra_line}")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    def run(self, *, with_xcodegen: bool = True, ci: bool = False) -> subprocess.CompletedProcess[str]:
        path = f"{self.bin}:/usr/bin:/bin" if with_xcodegen else "/usr/bin:/bin"
        environment = {"PATH": path, "HOME": str(self.repository)}
        if ci:
            environment["CI"] = "1"
        return subprocess.run(
            ["/bin/zsh", str(self.repository / "scripts/check-project-fresh.sh")],
            capture_output=True, text=True, env=environment,
        )


class ProjectFreshnessTests(unittest.TestCase):
    def fixture(self, **options: str | None) -> Fixture:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Fixture(pathlib.Path(directory.name), **options)  # type: ignore[arg-type]

    def test_stale_committed_project_fails_on_every_run(self) -> None:
        fixture = self.fixture(committed="stale", generated="fresh")
        for attempt in (1, 2, 3):
            result = fixture.run()
            self.assertEqual(1, result.returncode, f"run {attempt}: {result.stdout}{result.stderr}")
            self.assertIn("stale", result.stderr)

    def test_fresh_committed_project_passes(self) -> None:
        fixture = self.fixture(committed="fresh", generated="fresh")
        result = fixture.run()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_generated_file_missing_from_git_fails(self) -> None:
        fixture = self.fixture(committed="fresh", generated="fresh", extra="new.xcscheme")
        for _ in range(2):
            self.assertEqual(1, fixture.run().returncode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
