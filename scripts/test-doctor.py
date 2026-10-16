#!/usr/bin/env python3
"""Run the toolchain doctor through its real entry point with deterministic tool failures."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class E2EToolchainTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts").mkdir()
        for name in ("e2e.sh", "doctor.sh"):
            shutil.copy(ROOT / "scripts" / name, self.root / "scripts" / name)
        shutil.copy(ROOT / "TOOLCHAIN.json", self.root / "TOOLCHAIN.json")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        self.tool("xcodegen", "#!/bin/sh\nexit 0\n")
        self.tool("xcrun", f"#!{sys.executable}\n" + '''import pathlib, sys
args = sys.argv[1:]
if args == ['--sdk', 'macosx', '--show-sdk-version']:
    print(pathlib.Path('.fixture-sdk-version').read_text().strip())
elif args == ['--sdk', 'macosx', '--show-sdk-build-version']:
    print(pathlib.Path('.fixture-sdk-build').read_text().strip())
elif args == ['swift', '--version']:
    print('Swift fixture compiler')
else:
    sys.exit(f'unexpected xcrun arguments: {args}')
''')
        (self.root / ".fixture-sdk-version").write_text("27.0\n")
        (self.root / ".fixture-sdk-build").write_text("27A123\n")
        (self.root / ".fixture-untracked.json").write_text("[]")
        self.tool("git", f"#!{sys.executable}\n" + '''import difflib, json, os, pathlib, sys
args = sys.argv[1:]
if args == ['rev-parse', 'HEAD']:
    print(pathlib.Path('.fixture-sha').read_text().strip())
elif args == ['status', '--porcelain=v1', '--untracked-files=all']:
    if pathlib.Path('Tracked.swift').read_bytes() != pathlib.Path('.fixture-original').read_bytes():
        print(' M Tracked.swift')
    for name in json.loads(pathlib.Path('.fixture-untracked.json').read_text()):
        print('?? ' + name)
elif args == ['diff', 'HEAD', '--binary']:
    before = pathlib.Path('.fixture-original').read_text().splitlines(keepends=True)
    after = pathlib.Path('Tracked.swift').read_text().splitlines(keepends=True)
    sys.stdout.writelines(difflib.unified_diff(before, after, fromfile='a/Tracked.swift', tofile='b/Tracked.swift'))
elif args == ['ls-files', '--others', '--exclude-standard', '-z']:
    for name in json.loads(pathlib.Path('.fixture-untracked.json').read_text()):
        sys.stdout.buffer.write(os.fsencode(name) + bytes([0]))
else:
    sys.exit(f'unexpected git arguments: {args}')
''')
        (self.root / ".fixture-sha").write_text("a" * 40 + "\n")
        for name in ("Tracked.swift", ".fixture-original"):
            (self.root / name).write_text("let value = 1\n")
        app = self.root / ".build/dd/Build/Products/Debug/RecortiaE2E.app/Contents/MacOS/RecortiaE2E"
        app.parent.mkdir(parents=True)
        app.write_text('#!/bin/sh\ntouch launch-reached\nprintf \'[{"passed":true,"screenshots":[]}]\' > "$2/report.json"\n')
        app.chmod(0o755)

    def tool(self, name: str, source: str) -> None:
        executable = self.bin / name
        executable.write_text(source)
        executable.chmod(0o755)

    def run_e2e(self, *arguments: str, version: str = "27.0", build: str = "27A266a", mode: str = "stable") -> subprocess.CompletedProcess[str]:
        self.tool("xcodebuild", "#!/bin/sh\n"
                  f"if [ \"$1\" = -version ]; then printf 'Xcode {version}\\nBuild version {build}\\n'; "
                  "else touch build-reached; fi\n")
        return subprocess.run(
            ["/bin/zsh", str(self.root / "scripts/e2e.sh"), "--lang", "en", *arguments],
            cwd=self.root, capture_output=True, text=True, timeout=15,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "RECORTIA_TOOLCHAIN_MODE": mode,
                 "DEVELOPER_DIR": "/fixture/Xcode/Contents/Developer", "E2E_TIMEOUT": "1"},
        )

    def test_unreviewed_toolchain_never_builds_or_launches(self) -> None:
        result = self.run_e2e(version="27.9", build="unreviewed")
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertFalse((self.root / "build-reached").exists())
        self.assertFalse((self.root / "launch-reached").exists())

    def test_no_build_requires_matching_provenance_before_launch(self) -> None:
        result = self.run_e2e("--no-build")
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("provenance", result.stderr)
        self.assertFalse((self.root / "launch-reached").exists())

    def test_build_records_provenance_and_matching_no_build_reuses_it(self) -> None:
        result = self.run_e2e()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        provenance = self.root / ".build/dd-e2e-provenance.json"
        self.assertTrue(provenance.exists(), "successful builds need provenance next to derived data")
        record = json.loads(provenance.read_text())
        self.assertEqual("stable", record["toolchain_mode"])
        self.assertEqual("a" * 40, record["git_sha"])
        self.assertIn("27A266a", record["xcode_version"])
        self.assertEqual("27.0", record.get("sdk_version"))
        self.assertEqual("27A123", record.get("sdk_build_version"))
        runs = list((self.root / ".scratch/e2e").glob("*/en/provenance.json"))
        self.assertEqual(1, len(runs))
        self.assertEqual(record, json.loads(runs[0].read_text()))
        reused = self.run_e2e("--no-build")
        self.assertEqual(0, reused.returncode, reused.stdout + reused.stderr)

    def test_no_build_rejects_different_toolchain_or_source(self) -> None:
        self.assertEqual(0, self.run_e2e().returncode)
        (self.root / "launch-reached").unlink()
        changed = self.run_e2e("--no-build", version="27.1", build="27A9275", mode="development")
        self.assertNotEqual(0, changed.returncode)
        self.assertFalse((self.root / "launch-reached").exists())
        (self.root / ".fixture-sha").write_text("b" * 40 + "\n")
        changed = self.run_e2e("--no-build")
        self.assertNotEqual(0, changed.returncode)
        self.assertFalse((self.root / "launch-reached").exists())

    def test_no_build_rejects_tracked_edits_before_build_or_launch(self) -> None:
        initial = self.run_e2e()
        self.assertEqual(0, initial.returncode, initial.stdout + initial.stderr)
        provenance = self.root / ".build/dd-e2e-provenance.json"
        previous = json.loads(provenance.read_text())
        # The second edit keeps the same dirty status; its diff contents must still invalidate reuse.
        for value in (2, 3):
            (self.root / "Tracked.swift").write_text(f"let value = {value}\n")
            for marker in ("build-reached", "launch-reached"):
                (self.root / marker).unlink()
            refused = self.run_e2e("--no-build")
            self.assertEqual(2, refused.returncode, refused.stdout + refused.stderr)
            self.assertIn("provenance", refused.stderr)
            self.assertFalse((self.root / "build-reached").exists())
            self.assertFalse((self.root / "launch-reached").exists())
            rebuilt = self.run_e2e()
            self.assertEqual(0, rebuilt.returncode, rebuilt.stdout + rebuilt.stderr)
            current = json.loads(provenance.read_text())
            self.assertEqual(previous["git_sha"], current["git_sha"])
            self.assertNotEqual(previous["working_tree_fingerprint"], current["working_tree_fingerprint"])
            reused = self.run_e2e("--no-build")
            self.assertEqual(0, reused.returncode, reused.stdout + reused.stderr)
            previous = current

    def test_no_build_rejects_untracked_content_edits_before_build_or_launch(self) -> None:
        name = "untracked folder/Shape \n name.swift"
        path = self.root / name
        path.parent.mkdir()
        path.write_text("let value = 1\n")
        (self.root / ".fixture-untracked.json").write_text(json.dumps([name]))
        built = self.run_e2e()
        self.assertEqual(0, built.returncode, built.stdout + built.stderr)
        provenance = self.root / ".build/dd-e2e-provenance.json"
        previous = json.loads(provenance.read_text())
        for value in (2, 3):
            path.write_text(f"let value = {value}\n")
            for marker in ("build-reached", "launch-reached"):
                (self.root / marker).unlink()
            refused = self.run_e2e("--no-build")
            self.assertEqual(2, refused.returncode, refused.stdout + refused.stderr)
            self.assertIn("provenance", refused.stderr)
            self.assertFalse((self.root / "build-reached").exists())
            self.assertFalse((self.root / "launch-reached").exists())
            self.assertEqual(previous, json.loads(provenance.read_text()))
            rebuilt = self.run_e2e()
            self.assertEqual(0, rebuilt.returncode, rebuilt.stdout + rebuilt.stderr)
            current = json.loads(provenance.read_text())
            self.assertNotEqual(previous["working_tree_fingerprint"], current["working_tree_fingerprint"])
            self.assertEqual(0, self.run_e2e("--no-build").returncode)
            previous = current

    def test_no_build_rejects_untracked_symlink_target_changes(self) -> None:
        name = "Untracked.swift"
        path = self.root / name
        path.symlink_to("first-missing-target.swift")
        (self.root / ".fixture-untracked.json").write_text(json.dumps([name]))
        built = self.run_e2e()
        self.assertEqual(0, built.returncode, built.stdout + built.stderr)
        for marker in ("build-reached", "launch-reached"):
            (self.root / marker).unlink()
        path.unlink()
        path.symlink_to("second-missing-target.swift")
        refused = self.run_e2e("--no-build")
        self.assertEqual(2, refused.returncode, refused.stdout + refused.stderr)
        self.assertFalse((self.root / "build-reached").exists())
        self.assertFalse((self.root / "launch-reached").exists())

    def test_no_build_rejects_a_changed_sdk_before_build_or_launch(self) -> None:
        for filename, value in ((".fixture-sdk-version", "27.1"), (".fixture-sdk-build", "27A999")):
            with self.subTest(filename=filename):
                built = self.run_e2e()
                self.assertEqual(0, built.returncode, built.stdout + built.stderr)
                for marker in ("build-reached", "launch-reached"):
                    (self.root / marker).unlink()
                (self.root / filename).write_text(value + "\n")
                refused = self.run_e2e("--no-build")
                self.assertEqual(2, refused.returncode, refused.stdout + refused.stderr)
                self.assertFalse((self.root / "build-reached").exists())
                self.assertFalse((self.root / "launch-reached").exists())

    def test_development_mode_is_explicit_and_recorded(self) -> None:
        result = self.run_e2e(version="27.1", build="27A9275", mode="development")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("DEVELOPMENT", result.stdout)
        record = json.loads((self.root / ".build/dd-e2e-provenance.json").read_text())
        self.assertEqual("development", record["toolchain_mode"])


class DoctorTests(unittest.TestCase):
    def run_doctor(
        self, swift_exit: int = 0, *, version: str = "27.0", build: str = "27A266a",
        mode: str | None = None, arguments: tuple[str, ...] = (),
        observed_channel: str = "release_candidate", stable_channel: str = "stable",
        required_major: int = 27, allow_beta_release: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/doctor.sh").write_bytes((ROOT / "scripts/doctor.sh").read_bytes())
            (root / "TOOLCHAIN.json").write_text(json.dumps({
                "required_stable_xcode_major": required_major,
                "allow_beta_toolchains_for_release": allow_beta_release,
                "stable_xcode_baseline": {
                    "version": "27.0", "build": "27A266a", "release_channel": stable_channel,
                },
                "actual_xcode_version": "27.1",
                "actual_xcode_build": "27A9275",
                "actual_xcode_release_channel": observed_channel,
            }))
            binaries = root / "bin"
            binaries.mkdir()
            scripts = {
                "xcodebuild": f"#!/bin/sh\nprintf 'Xcode {version}\\nBuild version {build}\\n'\n",
                "xcodegen": "#!/bin/sh\nexit 0\n",
                "python3": "",
                "xcrun": (
                    f"#!{sys.executable}\nimport signal, sys\n"
                    "signal.signal(signal.SIGPIPE, signal.SIG_DFL)\n"
                    "sys.stdout.write('Swift test compiler\\n' + 'secondary line\\n' * 100000)\n"
                    f"sys.stdout.flush()\nsys.exit({swift_exit})\n"
                ),
            }
            for name, source in scripts.items():
                executable = binaries / name
                if name == "python3":
                    executable.symlink_to(sys.executable)
                else:
                    executable.write_text(source)
                    executable.chmod(0o755)
            environment = {
                "PATH": f"{binaries}:/usr/bin:/bin",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            }
            if mode is not None:
                environment["RECORTIA_TOOLCHAIN_MODE"] = mode
            return subprocess.run(
                ["/bin/zsh", str(root / "scripts/doctor.sh"), *arguments],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
            )

    def test_supported_stable_build_is_independent_of_local_observation(self) -> None:
        result = self.run_doctor()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("stable baseline", result.stdout)

    def test_recorded_rc_requires_explicit_development_mode(self) -> None:
        rejected = self.run_doctor(version="27.1", build="27A9275")
        self.assertNotEqual(0, rejected.returncode)
        accepted = self.run_doctor(version="27.1", build="27A9275", mode="development")
        self.assertEqual(0, accepted.returncode, accepted.stderr)
        self.assertIn("DEVELOPMENT", accepted.stdout)
        self.assertIn("release_candidate", accepted.stdout)
        self.assertIn("not release qualification", accepted.stdout)

    def test_unreviewed_release_channels_are_denied(self) -> None:
        for channel in ("beta", "unknown", "release_candidate"):
            with self.subTest(stable_channel=channel):
                result = self.run_doctor(stable_channel=channel)
                self.assertNotEqual(0, result.returncode, result.stdout)
        for channel in ("beta", "unknown", "stable"):
            with self.subTest(observed_channel=channel):
                result = self.run_doctor(
                    version="27.1", build="27A9275", mode="development", observed_channel=channel,
                )
                self.assertNotEqual(0, result.returncode, result.stdout)

    def test_unknown_and_beta_builds_are_denied_in_both_modes(self) -> None:
        for mode in ("stable", "development"):
            for version, build in (("27.0", "27A9999"), ("27.2", "27B5028f"), ("27.1", "27A266a")):
                with self.subTest(mode=mode, version=version, build=build):
                    result = self.run_doctor(version=version, build=build, mode=mode)
                    self.assertNotEqual(0, result.returncode, result.stdout)

    def test_release_mode_rejects_rc_despite_development_override(self) -> None:
        result = self.run_doctor(
            version="27.1", build="27A9275", mode="development", arguments=("--release",),
        )
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn("stable baseline", result.stderr)

    def test_release_mode_accepts_reviewed_stable_baseline(self) -> None:
        result = self.run_doctor(mode="development", arguments=("--release",))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("stable baseline", result.stdout)
        self.assertNotIn("DEVELOPMENT", result.stdout)

    def test_unknown_mode_and_arguments_fail_closed(self) -> None:
        for mode, arguments in (("beta", ()), (None, ("--unknown",)), ("development", ("--release", "--unknown"))):
            with self.subTest(mode=mode, arguments=arguments):
                self.assertNotEqual(0, self.run_doctor(mode=mode, arguments=arguments).returncode)

    def test_inconsistent_release_policy_is_denied(self) -> None:
        self.assertNotEqual(0, self.run_doctor(required_major=26).returncode)
        self.assertNotEqual(0, self.run_doctor(allow_beta_release=True, arguments=("--release",)).returncode)

    def test_multiline_version_output_does_not_trigger_sigpipe(self) -> None:
        result = self.run_doctor(0)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("doctor: Swift test compiler", result.stdout)
        self.assertNotIn("secondary line", result.stdout)

    def test_swift_failure_still_fails_doctor(self) -> None:
        self.assertNotEqual(0, self.run_doctor(42).returncode)


if __name__ == "__main__":
    unittest.main()
