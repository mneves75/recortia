#!/usr/bin/env python3
"""Run the toolchain doctor through its real entry point with deterministic tool failures."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


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
