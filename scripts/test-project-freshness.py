#!/usr/bin/env python3
"""The generated-project gate.

The gate generates into a temporary copy whose generator outputs start empty, then compares every
generator-owned file (the project and each target's info and entitlements plist) with the
worktree. Generating in the worktree overwrote an unstaged project edit and then passed. The
wrapper it runs has its own suite (test-xcodegen-wrapper.py).
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts/check-project-fresh.sh"
PROJECT = "Recortia.xcodeproj/project.pbxproj"
PLIST = "App/Info.plist"
RESOLVED = "Recortia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# The resolved spec the fake XcodeGen dumps, in the shape of `xcodegen dump --type parsed-json`.
SPEC = {"name": "Recortia", "targets": {
    "App": {"info": {"path": PLIST}, "entitlements": None, "sources": [{"path": "App"}]}}}
FAKE_XCODEGEN = f"""#!{sys.executable}
import json, pathlib, sys
arguments = sys.argv[1:]
if arguments[:5] == ["dump", "--quiet", "--type", "parsed-json", "--file"] and len(arguments) == 6:
    pathlib.Path(arguments[5]).write_text({json.dumps(json.dumps(SPEC))})
    sys.exit(0)
if arguments != ["generate", "--quiet"]:
    sys.exit(64)
project, plist = pathlib.Path("Recortia.xcodeproj"), pathlib.Path({PLIST!r})
if project.exists() or plist.exists():
    sys.exit("fake xcodegen: generator outputs were seeded before generation")
spec = pathlib.Path("project.yml").read_text()
project.mkdir()
(project / "project.pbxproj").write_text(spec)
plist.write_text("plist:" + spec)
extra = pathlib.Path(".fixture-extra")
if extra.exists():
    (project / extra.read_text()).write_text("extra")
"""


def git(repository: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repository, check=True, capture_output=True)


def executable(path: pathlib.Path, source: str) -> None:
    path.write_text(source)
    path.chmod(0o755)


class Fixture:
    """A throwaway repository whose fake `scripts/xcodegen.sh` turns project.yml into the outputs."""

    def __init__(self, directory: pathlib.Path, *, committed: str, spec: str, plist: str | None = None,
                 extra: str | None = None) -> None:
        self.repository = directory / "repo"
        (self.repository / "scripts").mkdir(parents=True)
        shutil.copy(GATE, self.repository / "scripts/check-project-fresh.sh")
        executable(self.repository / "scripts/xcodegen.sh", FAKE_XCODEGEN)
        (self.repository / ".gitignore").write_text("build/\n.DS_Store\n")
        (self.repository / "project.yml").write_text(spec)
        (self.repository / "App").mkdir()
        (self.repository / "App/main.swift").write_text("print(1)\n")
        (self.repository / PLIST).write_text(plist if plist is not None else "plist:" + spec)
        if extra:
            (self.repository / ".fixture-extra").write_text(extra)
        (self.repository / RESOLVED).parent.mkdir(parents=True)
        (self.repository / RESOLVED).write_text("{}")
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
        (self.bin / "python3").symlink_to(sys.executable)

    def read(self, path: str) -> str:
        return (self.repository / path).read_text()

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/zsh", str(self.repository / "scripts/check-project-fresh.sh")],
            capture_output=True, text=True, timeout=30,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.repository)},
        )


class ProjectFreshnessTests(unittest.TestCase):
    def fixture(self, **options: str | None) -> Fixture:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Fixture(pathlib.Path(directory.name), **options)  # type: ignore[arg-type]

    def test_fresh_outputs_pass_from_an_empty_output_location(self) -> None:
        # The fake generator refuses seeded outputs, and Package.resolved belongs to SwiftPM.
        fixture = self.fixture(committed="fresh", spec="fresh")
        result = fixture.run()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_stale_committed_project_fails_on_every_run(self) -> None:
        fixture = self.fixture(committed="stale", spec="fresh")
        for attempt in (1, 2, 3):
            result = fixture.run()
            self.assertEqual(1, result.returncode, f"run {attempt}: {result.stdout}{result.stderr}")
            self.assertIn("stale", result.stderr)
            self.assertIn(f"differs: {PROJECT}", result.stderr)
            self.assertEqual("stale", fixture.read(PROJECT), "the gate must not rewrite the worktree")

    def test_stale_generated_plist_fails(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh", plist="plist:older")
        result = fixture.run()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn(f"differs: {PLIST}", result.stderr)
        self.assertEqual("plist:older", fixture.read(PLIST))

    def test_unstaged_project_edit_fails_and_survives_the_check(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / PROJECT).write_text("edited by hand")
        for _ in range(2):
            result = fixture.run()
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn(f"differs: {PROJECT}", result.stderr)
            self.assertEqual("edited by hand", fixture.read(PROJECT))

    def test_uncommitted_spec_edit_is_an_input(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / "project.yml").write_text("changed")
        self.assertEqual(1, fixture.run().returncode)
        (fixture.repository / PROJECT).write_text("changed")
        (fixture.repository / PLIST).write_text("plist:changed")
        result = fixture.run()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_generated_file_missing_from_the_project_fails(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh", extra="new.xcscheme")
        for _ in range(2):
            result = fixture.run()
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("missing from the worktree: Recortia.xcodeproj/new.xcscheme", result.stderr)
        self.assertFalse((fixture.repository / "Recortia.xcodeproj/new.xcscheme").exists())

    def test_project_file_the_generator_does_not_write_fails(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / "Recortia.xcodeproj/old.xcscheme").write_text("left behind")
        result = fixture.run()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("not generated: Recortia.xcodeproj/old.xcscheme", result.stderr)

    def test_ignored_file_under_a_source_path_fails_loudly(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / "App/.DS_Store").write_text("finder")
        self.assertEqual(0, fixture.run().returncode, "control: XcodeGen itself skips .DS_Store")
        (fixture.repository / "App/build").mkdir()
        (fixture.repository / "App/build/Generated.swift").write_text("let generated = 1\n")
        result = fixture.run()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("App/build/Generated.swift", result.stderr)
        self.assertIn("git-ignored", result.stderr)

    def test_a_symlinked_output_parent_is_refused(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        outside = fixture.repository.parent / "outside"
        shutil.move(fixture.repository / "App", outside)
        (fixture.repository / "App").symlink_to(outside, target_is_directory=True)
        result = fixture.run()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("symbolic link", result.stderr)
        self.assertEqual("plist:fresh", (outside / "Info.plist").read_text())

    def test_missing_wrapper_fails(self) -> None:
        fixture = self.fixture(committed="fresh", spec="fresh")
        (fixture.repository / "scripts/xcodegen.sh").unlink()
        result = fixture.run()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("scripts/xcodegen.sh is missing", result.stderr)
        self.assertNotIn("global xcodegen called", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
