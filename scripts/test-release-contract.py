#!/usr/bin/env python3
"""REL-01 checks for source provenance and the shipped dependency notice."""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASE = ROOT / "scripts/release.sh"
RESOLVED = ROOT / "Recortia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NOTICE = "KeyboardShortcuts-LICENSE.txt"


class ReleaseFixture:
    """Run the real release entry point, stopping at the gate or archive boundary."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        (root / "scripts").mkdir()
        for name in ("release.sh", "doctor.sh"):
            shutil.copy(ROOT / "scripts" / name, root / "scripts" / name)
        shutil.copy(ROOT / "TOOLCHAIN.json", root / "TOOLCHAIN.json")
        self.bin = root / "bin"
        self.bin.mkdir()
        self.write_tool("xcodegen", "#!/bin/sh\nexit 0\n")
        self.write_tool("xcrun", "#!/bin/sh\necho 'Swift fixture compiler'\n")
        (self.bin / "python3").symlink_to(sys.executable)
        self.write_tool("xcodebuild", "#!/bin/sh\n"
                        "if [ \"$1\" = -version ]; then printf 'Xcode 27.0\\nBuild version 27A266a\\n'; "
                        "else touch archive-reached; exit 89; fi\n")
        self.write_tool("git", f"#!{sys.executable}\n" + '''import pathlib, shutil, sys
root = pathlib.Path(__file__).resolve().parent.parent
args = sys.argv[1:]
if args[:2] == ['rev-parse', 'HEAD']:
    print('a' * 40)
elif args[0] == 'show':
    print('MARKETING_VERSION: 0.12.2\\nCURRENT_PROJECT_VERSION: 21')
elif args[0] == 'describe':
    print('v0.12.2')
elif args[:2] == ['worktree', 'add']:
    target = pathlib.Path(args[-2])
    shutil.copytree(root / 'gate', target)
''')
        (root / "gate/scripts").mkdir(parents=True)
        gate = root / "gate/scripts/check.sh"
        gate.write_text("#!/bin/sh\ntouch gate-reached\nexit 23\n")
        gate.chmod(0o755)

    def write_tool(self, name: str, source: str) -> None:
        tool = self.bin / name
        tool.write_text(source)
        tool.chmod(0o755)

    def run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/zsh", str(self.root / "scripts/release.sh"), *arguments], cwd=self.root,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "RECORTIA_TOOLCHAIN_MODE": "stable"},
            capture_output=True, text=True, timeout=15,
        )


def git(*args: str, cwd: pathlib.Path) -> str:
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


class ReleaseContractTests(unittest.TestCase):
    app: pathlib.Path
    checkout: pathlib.Path

    def fixture(self) -> ReleaseFixture:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(directory.cleanup)
        return ReleaseFixture(pathlib.Path(directory.name))

    def test_existing_tagged_artifacts_survive_every_rerun(self) -> None:
        fixture = self.fixture()
        out = fixture.root / ".build/release/0.12.2"
        sentinels = {
            out / "Recortia.xcarchive/archive": b"original archive\x00",
            out / "Recortia.xcarchive/dSYMs/Recortia.dSYM/symbols": b"original symbols\xff",
            out / "Recortia-0.12.2.dmg": b"original notarized image",
        }
        for path, content in sentinels.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        for _ in range(2):
            result = fixture.run()
            self.assertNotEqual(0, result.returncode)
            self.assertIn(str(out), result.stderr)
            for path, content in sentinels.items():
                self.assertTrue(path.exists(), f"retained artifact deleted: {path}")
                self.assertEqual(content, path.read_bytes())
            self.assertFalse((out / "src").exists(), "reservation must fail before the gate")
            self.assertFalse((fixture.root / "archive-reached").exists())

    def test_failed_gate_keeps_reservation_and_second_invocation_refuses_it(self) -> None:
        fixture = self.fixture()
        first = fixture.run()
        self.assertIn("the gate failed", first.stderr)
        out = fixture.root / ".build/release/0.12.2"
        (out / "reserved").write_bytes(b"first invocation")
        second = fixture.run()
        self.assertNotEqual(0, second.returncode)
        self.assertIn("already exists", second.stderr)
        self.assertEqual(b"first invocation", (out / "reserved").read_bytes())
        self.assertFalse((fixture.root / "archive-reached").exists())

    def test_concurrent_invocations_reserve_the_tag_exactly_once(self) -> None:
        fixture = self.fixture()
        gate = fixture.root / "gate/scripts/check.sh"
        # The winner holds its reservation inside the gate while the other invocation arrives.
        gate.write_text("#!/bin/sh\nsleep 2\ntouch gate-reached\nexit 23\n")
        environment = {"PATH": f"{fixture.bin}:/usr/bin:/bin", "RECORTIA_TOOLCHAIN_MODE": "stable"}
        processes = [
            subprocess.Popen(
                ["/bin/zsh", str(fixture.root / "scripts/release.sh")], cwd=fixture.root, env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            for _ in range(2)
        ]
        errors = [process.communicate(timeout=30)[1] for process in processes]
        self.assertTrue(all(process.returncode != 0 for process in processes))
        self.assertEqual(1, sum("already exists" in error for error in errors), errors)
        self.assertEqual(1, sum("the gate failed" in error for error in errors), errors)
        release = fixture.root / ".build/release"
        self.assertEqual([release / "0.12.2"], sorted(release.iterdir()))
        self.assertEqual(1, len(list(release.rglob("gate-reached"))), "exactly one invocation may run the gate")
        self.assertFalse((fixture.root / "archive-reached").exists())

    def test_dry_runs_reserve_unique_directories_and_preserve_older_output(self) -> None:
        fixture = self.fixture()
        older = fixture.root / ".build/release/0.12.2-dev"
        older.mkdir(parents=True)
        (older / "retained").write_bytes(b"older dry run")
        for _ in range(2):
            result = fixture.run("--dry-run")
            self.assertNotEqual(0, result.returncode)  # fixture stops at archive, before signing
        self.assertEqual(b"older dry run", (older / "retained").read_bytes())
        fresh = list(older.parent.glob("0.12.2-dev-*"))
        self.assertEqual(2, len(fresh), "each dry run needs its own reservation")
        self.assertTrue((fixture.root / "archive-reached").exists(), "dry run control reaches archive")

    def test_missing_xcodegen_fails_release_gate_before_archive(self) -> None:
        fixture = self.fixture()
        (fixture.bin / "xcodegen").unlink()
        gate = fixture.root / "gate"
        shutil.copy(ROOT / "scripts/check.sh", gate / "scripts/check.sh")
        for name in ("doctor.sh", "check-project-fresh.sh"):
            shutil.copy(ROOT / "scripts" / name, gate / "scripts" / name)
        shutil.copy(ROOT / "TOOLCHAIN.json", gate / "TOOLCHAIN.json")
        # Earlier gate tests are independently exercised by their own suites.
        for name in re.findall(r"python3 scripts/(test-[\w-]+\.py)", (ROOT / "scripts/check.sh").read_text()):
            (gate / "scripts" / name).write_text("")
        fixture.write_tool("swift", "#!/bin/sh\nexit 0\n")
        result = fixture.run()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("the gate failed", result.stderr)
        self.assertFalse((fixture.root / "archive-reached").exists(), "no archive after a failed freshness gate")
        self.assertFalse(list((fixture.root / ".build/release").rglob("archive-reached")))

    def test_release_entry_point_requires_stable_toolchain_before_git_or_artifacts(self) -> None:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            for name in ("release.sh", "doctor.sh"):
                script = root / "scripts" / name
                script.write_bytes((ROOT / "scripts" / name).read_bytes())
                script.chmod(0o755)
            (root / "TOOLCHAIN.json").write_bytes((ROOT / "TOOLCHAIN.json").read_bytes())
            binaries = root / "bin"
            binaries.mkdir()
            for name, source in {
                "git": '#!/bin/sh\necho "git boundary reached (mode=$RECORTIA_TOOLCHAIN_MODE)" >&2\nexit 87\n',
                "xcodegen": "#!/bin/sh\nexit 0\n",
                "xcrun": "#!/bin/sh\necho 'Swift fixture compiler'\n",
            }.items():
                executable = binaries / name
                executable.write_text(source)
                executable.chmod(0o755)
            (binaries / "python3").symlink_to(sys.executable)
            xcodebuild = binaries / "xcodebuild"
            xcodebuild.write_text("#!/bin/sh\nprintf 'Xcode 27.1\\nBuild version 27A9275\\n'\n")
            xcodebuild.chmod(0o755)
            environment = {
                "PATH": f"{binaries}:/usr/bin:/bin",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "RECORTIA_TOOLCHAIN_MODE": "development",
            }
            for arguments in ((), ("--dry-run",)):
                with self.subTest(arguments=arguments):
                    result = subprocess.run(
                        ["/bin/zsh", str(root / "scripts/release.sh"), *arguments],
                        cwd=root, env=environment, capture_output=True, text=True, timeout=15,
                    )
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("stable baseline", result.stderr)
                    self.assertNotIn("git boundary reached", result.stderr)
                    self.assertFalse((root / ".build").exists())
            xcodebuild.write_text("#!/bin/sh\nprintf 'Xcode 27.0\\nBuild version 27A266a\\n'\n")
            control = subprocess.run(
                ["/bin/zsh", str(root / "scripts/release.sh"), "--dry-run"],
                cwd=root, env=environment, capture_output=True, text=True, timeout=15,
            )
            self.assertIn("stable baseline", control.stdout)
            self.assertIn("git boundary reached (mode=stable)", control.stderr)

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
