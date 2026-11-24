#!/usr/bin/env python3
"""REL-01 checks for source provenance and the shipped dependency notice."""

import argparse
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
# The reviewed stable pin comes from the record, never a copy: a copied pin fails every release
# control the moment the toolchain is re-observed.
RECORD = json.loads((ROOT / "TOOLCHAIN.json").read_text())
STABLE = RECORD["stable_xcode_baseline"]
STABLE_XCODE = f"Xcode {STABLE['version']}\\nBuild version {STABLE['build']}\\n"
SWIFT_XCRUN = f"#!/bin/sh\necho 'Apple Swift version {RECORD['expected_bundled_swift_compiler_major_minor']}.0 (fixture)'\n"
RELEASE = ROOT / "scripts/release.sh"
RESOLVED = ROOT / "Recortia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NOTICE = "KeyboardShortcuts-LICENSE.txt"


def inventory_release_status(text: str) -> str | None:
    """The verdict scripts/tests-report.py gives a release log, from the real parser."""
    spec = importlib.util.spec_from_file_location("tests_report", ROOT / "scripts/tests-report.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.release_status(text)


class ReleaseFixture:
    """Run the real release entry point, stopping at the gate or archive boundary."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        (root / "scripts").mkdir()
        for name in ("release.sh", "doctor.sh"):
            shutil.copy(ROOT / "scripts" / name, root / "scripts" / name)
        shutil.copytree(ROOT / "scripts/lib", root / "scripts/lib")
        shutil.copy(ROOT / "TOOLCHAIN.json", root / "TOOLCHAIN.json")
        self.bin = root / "bin"
        self.bin.mkdir()
        self.write_tool("xcrun", SWIFT_XCRUN)
        (self.bin / "python3").symlink_to(sys.executable)
        self.write_tool("xcodebuild", "#!/bin/sh\n"
                        f"if [ \"$1\" = -version ]; then printf '{STABLE_XCODE}'; "
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
elif args[0] == '-C' and args[2:4] == ['worktree', 'remove']:
    sys.exit(1 if (root / 'fail-cleanup').exists() else 0)
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

    def test_a_failed_dry_run_reads_as_failed_never_as_complete(self) -> None:
        fixture = self.fixture()
        result = fixture.run("--dry-run")  # the fixture's xcodebuild fails the archive step
        self.assertNotEqual(0, result.returncode)
        output = result.stdout + result.stderr
        self.assertIn(f"release: failed (exit {result.returncode})", result.stderr)
        self.assertNotIn("dry run complete", output)
        self.assertEqual("failed", inventory_release_status(output))

    def run_finish(self, *, exit_status: int, cleanup_fails: bool, completed: bool) -> subprocess.CompletedProcess[str]:
        """Run release.sh's own EXIT handler: the success path needs codesign, hdiutil and
        /usr/libexec/PlistBuddy, which no fixture stands in for, so this drives its last step."""
        script = RELEASE.read_text()
        handler = re.search(r"(?ms)^finish\(\) \{\n.*?\n^\}\n", script)
        self.assertIsNotNone(handler, "release.sh must define finish")
        assert handler is not None
        fixture = self.fixture()
        if cleanup_fails:
            (fixture.root / "fail-cleanup").write_text("")
        body = (f"source {ROOT / 'scripts/lib/run-identity.sh'}\n" + handler.group(0) + f"root={fixture.root}\nsrc={fixture.root}/src\nlabel=0.1-dev\nout=/out\n"
                f"dry_run=1\ncompleted=0\ntrap finish EXIT\n{'completed=1' if completed else ':'}\nexit {exit_status}\n")
        return subprocess.run(["/bin/zsh", "-c", body], cwd=fixture.root, capture_output=True, text=True,
                              env={"PATH": f"{fixture.bin}:/usr/bin:/bin"}, timeout=15)

    def test_the_verdict_follows_cleanup_and_the_inventory_reads_it(self) -> None:
        done = self.run_finish(exit_status=0, cleanup_fails=False, completed=True)
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        self.assertEqual("release: dry run complete (0.1-dev, manifest /out/manifest.txt)",
                         done.stdout.strip().splitlines()[-1])
        record = "release: run mode dry-run\nrelease: commit " + "a" * 40 + " tree clean\n" + done.stdout
        self.assertEqual("passed", inventory_release_status(record))
        failed_cleanup = self.run_finish(exit_status=0, cleanup_fails=True, completed=True)
        self.assertNotEqual(0, failed_cleanup.returncode)
        self.assertIn("release: cleanup failed", failed_cleanup.stderr)
        self.assertNotIn("complete", failed_cleanup.stdout)
        self.assertEqual("failed", inventory_release_status(failed_cleanup.stdout + failed_cleanup.stderr))
        early_exit = self.run_finish(exit_status=0, cleanup_fails=False, completed=False)
        self.assertNotEqual(0, early_exit.returncode, "an exit before the last step is not a success")
        self.assertNotIn("complete", early_exit.stdout)

    def test_the_run_header_names_the_mode_before_preflight(self) -> None:
        fixture = self.fixture()
        for arguments, mode in ((("--dry-run",), "dry-run"), ((), "release")):
            with self.subTest(mode=mode):
                result = fixture.run(*arguments)
                self.assertEqual(f"release: run mode {mode}", result.stdout.splitlines()[0])
        script = RELEASE.read_text()
        self.assertLess(script.index('echo "release: run mode $mode"'), script.index("scripts/doctor.sh --release"))

    def test_unknown_arguments_stop_before_the_toolchain_or_release_path(self) -> None:
        for arguments in (("--dryrun",), ("dry-run",), ("--dry-run", "extra"), ("",)):
            with self.subTest(arguments=arguments):
                fixture = self.fixture()
                result = fixture.run(*arguments)
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                self.assertIn("usage: scripts/release.sh [--dry-run]", result.stderr)
                self.assertNotIn("doctor:", result.stdout + result.stderr)
                self.assertFalse((fixture.root / ".build").exists())
                self.assertFalse((fixture.root / "gate-reached").exists())

    def test_unavailable_xcodegen_fails_release_gate_before_archive(self) -> None:
        fixture = self.fixture()
        # The pinned XcodeGen cannot be fetched, and a global copy must not stand in for it.
        fixture.write_tool("curl", "#!/bin/sh\nexit 22\n")
        global_called = fixture.root / "global-xcodegen-called"
        fixture.write_tool("xcodegen", f"#!/bin/sh\ntouch '{global_called}'\nexit 0\n")
        gate = fixture.root / "gate"
        shutil.copy(ROOT / "scripts/check.sh", gate / "scripts/check.sh")
        for name in ("doctor.sh", "check-project-fresh.sh", "xcodegen.sh"):
            shutil.copy(ROOT / "scripts" / name, gate / "scripts" / name)
        shutil.copytree(ROOT / "scripts/lib", gate / "scripts/lib")
        shutil.copy(ROOT / "TOOLCHAIN.json", gate / "TOOLCHAIN.json")
        # Earlier gate steps are independently exercised by their own suites.
        for name in re.findall(r"python3 scripts/([\w-]+\.py)", (ROOT / "scripts/check.sh").read_text()):
            (gate / "scripts" / name).write_text("")
        result = fixture.run()
        self.assertFalse(global_called.exists(), "a global xcodegen must never stand in for the pin")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("the gate failed", result.stderr)
        gate_log = next((fixture.root / ".build/release").rglob("gate.log")).read_text()
        self.assertIn("xcodegen: download of", gate_log, "the gate must fail at the pinned XcodeGen")
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
            shutil.copytree(ROOT / "scripts/lib", root / "scripts/lib")
            (root / "TOOLCHAIN.json").write_bytes((ROOT / "TOOLCHAIN.json").read_bytes())
            binaries = root / "bin"
            binaries.mkdir()
            for name, source in {
                "git": '#!/bin/sh\necho "git boundary reached (mode=$RECORTIA_TOOLCHAIN_MODE)" >&2\nexit 87\n',
                "xcrun": SWIFT_XCRUN,
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
            xcodebuild.write_text(f"#!/bin/sh\nprintf '{STABLE_XCODE}'\n")
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

    def test_every_shipped_notice_is_checked_in_the_bundle_before_notarization(self) -> None:
        script = RELEASE.read_text()
        notarize = script.index("== notarize the app")
        notices = sorted(path.name for path in (ROOT / "RecortiaApp/Resources").glob("*-LICENSE.txt"))
        self.assertIn("Fosco-LICENSE.txt", notices)
        for name in notices:
            with self.subTest(notice=name):
                bundled = f'"$app/Contents/Resources/{name}"'
                check = re.search(r"cmp -s [^\n]*" + re.escape(bundled) + r"|" + re.escape(f"={bundled}"), script)
                self.assertIsNotNone(check, f"release.sh never compares the bundled {name}")
                self.assertLess(check.start(), notarize, f"{name} is checked only after notarization")

    def test_exported_app_updater_plist_is_checked_before_notarization(self) -> None:
        script = RELEASE.read_text()
        notarize = script.index("== notarize the app")
        check = 'python3 "$src/scripts/check-updater-plist.py" --app-plist "$app/Contents/Info.plist"'
        self.assertEqual(1, script.count(check), "release.sh must check the exported app's Info.plist")
        self.assertLess(script.index(check), notarize, "updater Info.plist check must precede notarization")

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
        fosco = (ROOT / "RecortiaApp/Resources/Fosco-LICENSE.txt").read_bytes()
        self.assertIn(b"Copyright (c) 2026 Gabriel Buzzi Venturi", fosco)
        self.assertEqual(fosco, (self.app / "Contents/Resources/Fosco-LICENSE.txt").read_bytes())


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
