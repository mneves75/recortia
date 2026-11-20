#!/usr/bin/env python3
"""The generated-project gate and the pinned XcodeGen wrapper it runs.

The gate must generate into a temporary copy: generating in the worktree overwrote an unstaged
project edit and then passed. The wrapper must refuse a download whose checksum differs from the
pin in TOOLCHAIN.json.
"""

import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts/check-project-fresh.sh"
WRAPPER = ROOT / "scripts/xcodegen.sh"
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


class XcodegenWrapperTests(unittest.TestCase):
    """Run the real wrapper against a local zip; the fixture record names that zip and its hash."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        base = pathlib.Path(directory.name)
        self.root = base / "repo"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy(WRAPPER, self.root / "scripts/xcodegen.sh")
        self.archive = base / "xcodegen.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            info = zipfile.ZipInfo("xcodegen/bin/xcodegen")
            info.external_attr = 0o755 << 16
            archive.writestr(info, '#!/bin/sh\necho "fake xcodegen [$*] in $(pwd -P)"\n')
        self.sha256 = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.bin = base / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        self.caller = base / "caller"
        self.caller.mkdir()

    def run_wrapper(self, sha256: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        (self.root / "TOOLCHAIN.json").write_text(json.dumps(
            {"xcodegen": {"version": "0.0.1", "sha256": sha256, "url": self.archive.as_uri()}}))
        return subprocess.run(
            ["/bin/zsh", str(self.root / "scripts/xcodegen.sh"), *arguments],
            cwd=self.caller, capture_output=True, text=True, timeout=30,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root)},
        )

    def test_verified_download_installs_once_and_runs_in_the_callers_directory(self) -> None:
        result = self.run_wrapper(self.sha256, "generate", "--quiet")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn(f"fake xcodegen [generate --quiet] in {self.caller.resolve()}", result.stdout)
        tools = self.root / ".build/tools"
        self.assertTrue((tools / "xcodegen-0.0.1/bin/xcodegen").exists())
        self.assertEqual(["xcodegen-0.0.1"], sorted(path.name for path in tools.iterdir()))
        self.archive.unlink()
        cached = self.run_wrapper(self.sha256, "--version")
        self.assertEqual(0, cached.returncode, cached.stdout + cached.stderr)
        self.assertIn("fake xcodegen [--version]", cached.stdout)

    def test_checksum_mismatch_installs_nothing(self) -> None:
        wrong = hashlib.sha256(b"not the pinned zip").hexdigest()
        result = self.run_wrapper(wrong, "generate")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("nothing installed", result.stderr)
        self.assertNotIn("fake xcodegen", result.stdout)
        self.assertEqual([], list((self.root / ".build/tools").iterdir()))

    def test_malformed_pin_is_refused_before_download(self) -> None:
        for sha256 in ("", "ABC", self.sha256.upper()):
            with self.subTest(sha256=sha256):
                result = self.run_wrapper(sha256, "generate")
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn("pin error", result.stderr)
                self.assertFalse((self.root / ".build").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
