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

    def test_app_is_notarized_and_stapled_before_the_disk_image_is_built(self) -> None:
        script = RELEASE.read_text()
        steps = [
            'ditto -c -k --keepParent "$app" "$app_zip"',
            'asc notarization submit --file "$app_zip" --wait --timeout 1h --output table',
            'xcrun stapler staple "$app"',
            'xcrun stapler validate "$app"',
            'ditto "$app" "$staging/Recortia.app"',
            'hdiutil create',
            'codesign --sign "Developer ID Application: Marcus Neves (Q96FUTC5G8)" --timestamp "$dmg"',
            'asc notarization submit --file "$dmg" --wait --timeout 1h --output table',
            'xcrun stapler staple "$dmg"',
            'xcrun stapler validate "$dmg"',
        ]
        positions = []
        for step in steps:
            self.assertEqual(1, script.count(step), f"expected exactly one: {step}")
            positions.append(script.index(step))
        self.assertEqual(positions, sorted(positions), "the app must be stapled before the DMG is built")
        # A dry run builds the DMG without notarizing either artifact.
        for step in (steps[1], steps[2], steps[3]):
            guarded = r"(?s)\nif \(\( ! dry_run \)\); then\n(?:(?!\nfi\n).)*?" + re.escape(step)
            self.assertRegex(script, guarded, f"not skipped in a dry run: {step}")
        # Stapling edits the bundle, so its seal and Gatekeeper assessment are checked afterwards.
        self.assertLess(
            positions[3], script.index('codesign --verify --deep --strict "$app"', positions[3]),
        )

    def test_bundled_notice_matches_pinned_dependency(self) -> None:
        if not hasattr(self, "app"):
            self.skipTest("run with --app and --package-checkout to check the bundled notices")
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
    # Without both paths only the static script checks run and the bundle checks are reported as skipped.
    parser.add_argument("--app", type=pathlib.Path)
    parser.add_argument("--package-checkout", type=pathlib.Path)
    arguments = parser.parse_args()
    if (arguments.app is None) != (arguments.package_checkout is None):
        parser.error("--app and --package-checkout go together")
    if arguments.app is not None:
        ReleaseContractTests.app = arguments.app
        ReleaseContractTests.checkout = arguments.package_checkout
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps({"tests_run": result.testsRun, "failures": len(result.failures), "errors": len(result.errors)}))
    sys.exit(0 if result.wasSuccessful() else 1)
