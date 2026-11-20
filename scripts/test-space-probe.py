#!/usr/bin/env python3
"""CAP-02: the physical Space probe may succeed only with a measurement for every variant.

Each test runs the real scripts/space-probe/run.sh with stand-in host and probe programs (no
window, no fullscreen Space) and checks its exit status against what the probe actually reported.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

# `xcrun swiftc -O <name>.swift -o <out>` writes a stand-in program instead of compiling.
XCRUN = f"""#!{sys.executable}
import pathlib, sys
args = sys.argv[1:]
assert args[:2] == ["swiftc", "-O"] and args[3] == "-o", args
out = pathlib.Path(args[4])
if args[2] == "host.swift":
    out.write_text("#!/bin/sh\\nexec sleep 30\\n")
else:
    out.write_text('''#!/bin/sh
[ "$1" = "$PROBE_SILENT_VARIANT" ] && exit 0
case "$PROBE_BEHAVIOUR" in
  report) printf '{{"spaceChanges":0,"variant":"%s"}}\\\\n' "$1" ;;
  other-variant) printf '{{"spaceChanges":0,"variant":"other"}}\\\\n' ;;
  no-count) printf '{{"variant":"%s"}}\\\\n' "$1" ;;
  silent) ;;
  crash) printf '{{"spaceChanges":0,"variant":"%s"}}\\\\n' "$1"; exit 3 ;;
esac
''')
out.chmod(0o755)
"""


class SpaceProbeRunTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts/space-probe").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/space-probe/run.sh", self.root / "scripts/space-probe/run.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        xcrun = self.bin / "xcrun"
        xcrun.write_text(XCRUN)
        xcrun.chmod(0o755)

    def run_probe(self, behaviour: str, *arguments: str, silent: str = "") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/zsh", str(self.root / "scripts/space-probe/run.sh"), *arguments],
            capture_output=True, text=True, timeout=60,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "PROBE_BEHAVIOUR": behaviour,
                 "PROBE_SILENT_VARIANT": silent},
        )

    def test_every_variant_reporting_passes_and_prints_each_result(self) -> None:
        result = self.run_probe("report", "fresh", "default", "overlay")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn('"variant":"default"', result.stdout)
        self.assertIn('"variant":"overlay"', result.stdout)

    def test_no_variant_is_a_usage_error(self) -> None:
        result = self.run_probe("report", "fresh")
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("usage:", result.stderr)

    def test_a_missing_or_invalid_result_fails(self) -> None:
        for behaviour in ("silent", "crash", "other-variant", "no-count"):
            with self.subTest(behaviour=behaviour):
                result = self.run_probe(behaviour, "fresh", "default")
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn("space-probe: no valid result for default", result.stderr)

    def test_one_missing_result_fails_the_whole_run(self) -> None:
        result = self.run_probe("report", "fresh", "default", "overlay", silent="default")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn('"variant":"overlay"', result.stdout, "the other variant still reports")
        self.assertIn("space-probe: no valid result for default", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
