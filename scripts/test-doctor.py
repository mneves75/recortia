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
    def run_doctor(self, swift_exit: int) -> subprocess.CompletedProcess[str]:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/doctor.sh").write_bytes((ROOT / "scripts/doctor.sh").read_bytes())
            (root / "TOOLCHAIN.json").write_text(json.dumps({"actual_xcode_build": "test-build"}))
            binaries = root / "bin"
            binaries.mkdir()
            scripts = {
                "xcodebuild": "#!/bin/sh\nprintf 'Xcode test\\nBuild version test-build\\n'\n",
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
            return subprocess.run(
                ["/bin/zsh", str(root / "scripts/doctor.sh")],
                cwd=root,
                env={"PATH": f"{binaries}:/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"},
                capture_output=True,
                text=True,
                timeout=15,
            )

    def test_multiline_version_output_does_not_trigger_sigpipe(self) -> None:
        result = self.run_doctor(0)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("doctor: Swift test compiler", result.stdout)
        self.assertNotIn("secondary line", result.stdout)

    def test_swift_failure_still_fails_doctor(self) -> None:
        self.assertNotEqual(0, self.run_doctor(42).returncode)


if __name__ == "__main__":
    unittest.main()
