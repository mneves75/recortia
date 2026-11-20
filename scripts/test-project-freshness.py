#!/usr/bin/env python3
"""The generated-project gate.

The gate must generate into a temporary copy: generating in the worktree overwrote an unstaged
project edit and then passed. The wrapper it runs has its own suite (test-xcodegen-wrapper.py).
"""

import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts/check-project-fresh.sh"
PROJECT = "Recortia.xcodeproj/project.pbxproj"


def git(repository: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repository, check=True, capture_output=True)


def executable(path: pathlib.Path, source: str) -> None:
    path.write_text(source)
    path.chmod(0o755)


class Fixture:
    """A throwaway repository whose fake `scripts/xcodegen.sh` writes project.yml into the project."""

    def __init__(self, directory: pathlib.Path, *, committed: str, spec: str, extra: str | None = None) -> None:
        self.repository = directory / "repo"
        (self.repository / "scripts").mkdir(parents=True)
        shutil.copy(GATE, self.repository / "scripts/check-project-fresh.sh")
        extra_line = f"printf 'extra' > Recortia.xcodeproj/{extra}\n" if extra else ""
        executable(self.repository / "scripts/xcodegen.sh",
                   f"#!/bin/sh\n[ \"$*\" = 'generate --quiet' ] || exit 64\ncat project.yml > {PROJECT}\n{extra_line}")
        (self.repository / "project.yml").write_text(spec)
        (self.repository / "Recortia.xcodeproj").mkdir()
        (self.repository / PROJECT).write_text(committed)
        git(self.repository, "init", "-q")
        git(self.repository, "config", "user.name", "Freshness Test")
        git(self.repository, "config", "user.email", "freshness@example.invalid")
        git(self.repository, "add", "-A")
        git(self.repository, "commit", "-qm", "committed project")
        # A global xcodegen must never be what the gate runs.
        self.bin = directory / "bin"
        self.bin.mkdir()
        executable(self.bin / "xcodegen", "#!/bin/sh\necho 'global xcodegen called' >&2\nexit 97\n")

    def project(self) -> str:
        return (self.repository / PROJECT).read_text()

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/zsh", str(self.repository / "scripts/check-project-fresh.sh")],
            capture_output=True, text=True,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.repository)},
        )


class ProjectFreshnessTests(unittest.TestCase):
    def fixture(self, **options: str | None) -> Fixture:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Fixture(pathlib.Path(directory.name), **options)  # type: ignore[arg-type]

    def test_stale_committed_project_fails_on_every_run(self) -> None:
        fixture = self.fixture(committed="stale", spec="fresh")
        for attempt in (1, 2, 3):
            result = fixture.run()
            self.assertEqual(1, result.returncode, f"run {attempt}: {result.stdout}{result.stderr}")
            self.assertIn("stale", result.stderr)
            self.assertIn("project.pbxproj", result.stderr)
            self.assertEqual("stale", fixture.project(), "the gate must not rewrite the worktree")

    def test_fresh_committed_project_passes(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        result = fixture.run()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_unstaged_project_edit_fails_and_survives_the_check(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / PROJECT).write_text("edited by hand")
        for _ in range(2):
            result = fixture.run()
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("project.pbxproj", result.stderr)
            self.assertEqual("edited by hand", fixture.project())

    def test_uncommitted_spec_edit_is_an_input(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / "project.yml").write_text("changed")
        self.assertEqual(1, fixture.run().returncode)
        (fixture.repository / PROJECT).write_text("changed")
        result = fixture.run()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_generated_file_missing_from_the_project_fails(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh", extra="new.xcscheme")
        for _ in range(2):
            result = fixture.run()
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("new.xcscheme", result.stderr)
        self.assertFalse((fixture.repository / "Recortia.xcodeproj/new.xcscheme").exists())

    def test_missing_wrapper_fails(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / "scripts/xcodegen.sh").unlink()
        result = fixture.run()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("scripts/xcodegen.sh is missing", result.stderr)
        self.assertNotIn("global xcodegen called", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
