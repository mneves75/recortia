#!/usr/bin/env python3
"""REL-01 checks for source provenance and the shipped dependency notice."""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASE = ROOT / "scripts/release.sh"
RESOLVED = ROOT / "Recortia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NOTICE = "KeyboardShortcuts-LICENSE.txt"


def git(*args: str, cwd: pathlib.Path) -> str:
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


class ReleaseContractTests(unittest.TestCase):
    app: pathlib.Path
    checkout: pathlib.Path

    def test_manifest_source_is_frozen_before_build(self) -> None:
        script = RELEASE.read_text()
        for expected in (
            r"(?m)^source_commit=\$\(git rev-parse HEAD\)$",
            r'(?m)^version=\$\(git show "\$\{source_commit\}:project.yml" \| sed ',
            r'(?m)^tag=\$\(git describe --exact-match --tags "\$source_commit" ',
            r'(?m)^git worktree add --quiet --detach "\$src" "\$source_commit"$',
            r'(?m)^  echo "commit: \$source_commit"$',
        ):
            self.assertTrue(re.search(expected, script), f"release source invariant missing: {expected}")
        self.assertLess(script.index("source_commit=$(git rev-parse HEAD)"), script.index("version=$(git show"))
        self.assertEqual(1, script.count("source_commit="))
        self.assertFalse(re.search(r'echo "commit: \$\(git rev-parse HEAD\)"', script))

        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            repository = pathlib.Path(directory) / "repo"
            repository.mkdir()
            git("init", "-q", cwd=repository)
            git("config", "user.name", "Release Contract", cwd=repository)
            git("config", "user.email", "release@example.invalid", cwd=repository)
            (repository / "source").write_text("first\n")
            git("add", "source", cwd=repository)
            git("commit", "-qm", "first", cwd=repository)
            source_commit = git("rev-parse", "HEAD", cwd=repository)
            checkout = pathlib.Path(directory) / "checkout"
            git("worktree", "add", "--quiet", "--detach", str(checkout), source_commit, cwd=repository)
            (repository / "source").write_text("second\n")
            git("commit", "-qam", "second", cwd=repository)
            self.assertNotEqual(source_commit, git("rev-parse", "HEAD", cwd=repository))
            self.assertEqual(source_commit, git("rev-parse", "HEAD", cwd=checkout))

    def test_bundled_notice_matches_pinned_dependency(self) -> None:
        pins = json.loads(RESOLVED.read_text())["pins"]
        keyboard_shortcuts = next(pin for pin in pins if pin["identity"] == "keyboardshortcuts")
        self.assertEqual("3.1.0", keyboard_shortcuts["state"]["version"])
        self.assertEqual(
            keyboard_shortcuts["state"]["revision"], git("rev-parse", "HEAD", cwd=self.checkout)
        )
        upstream = (self.checkout / "license").read_bytes()
        self.assertIn(b"Copyright (c) Sindre Sorhus", upstream)
        self.assertEqual(upstream, (ROOT / "RecortiaApp/Resources" / NOTICE).read_bytes())
        self.assertEqual(upstream, (self.app / "Contents/Resources" / NOTICE).read_bytes())
        self.assertEqual(
            (ROOT / "LICENSE").read_bytes(),
            (self.app / "Contents/Resources/Recortia-LICENSE.txt").read_bytes(),
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--package-checkout", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    ReleaseContractTests.app = arguments.app
    ReleaseContractTests.checkout = arguments.package_checkout
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps({"tests_run": result.testsRun, "failures": len(result.failures), "errors": len(result.errors)}))
    sys.exit(0 if result.wasSuccessful() else 1)
