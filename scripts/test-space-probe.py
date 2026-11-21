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
    # The real host creates FULLSCREEN_FILE from windowDidEnterFullScreen.
    out.write_text('#!/bin/sh\\n[ -n "$HOST_NO_FULLSCREEN" ] || : > "$FULLSCREEN_FILE"\\nexec sleep 30\\n')
else:
    out.write_text('''#!/bin/sh
[ "$1" = "$PROBE_SILENT_VARIANT" ] && exit 0
# Like the real probe: measure only after the host's fullscreen signal; no signal is a failed control.
i=0
while [ ! -f "$FULLSCREEN_FILE" ]; do
  i=$((i + 1))
  [ $i -gt 30 ] && {{ printf '{{"error":"host never entered fullscreen"}}\\\\n'; exit 3; }}
  sleep 0.1
done
case "$PROBE_BEHAVIOUR" in
  report) printf '{{"hostEnteredFullScreen":true,"hostFrontBefore":true,"mode":"%s","spaceChanges":0,"variant":"%s"}}\\\\n' "$2" "$1" ;;
  not-fullscreen) printf '{{"hostEnteredFullScreen":false,"hostFrontBefore":true,"mode":"%s","spaceChanges":0,"variant":"%s"}}\\\\n' "$2" "$1" ;;
  wrong-mode) printf '{{"hostFrontBefore":true,"mode":"other","spaceChanges":0,"variant":"%s"}}\\\\n' "$1" ;;
  host-not-front) printf '{{"hostFrontBefore":false,"mode":"%s","spaceChanges":0,"variant":"%s"}}\\\\n' "$2" "$1" ;;
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

    def run_probe(self, behaviour: str, *arguments: str, silent: str = "",
                  host_fullscreen: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/zsh", str(self.root / "scripts/space-probe/run.sh"), *arguments],
            capture_output=True, text=True, timeout=60,
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "PROBE_BEHAVIOUR": behaviour,
                 "PROBE_SILENT_VARIANT": silent, "HOST_NO_FULLSCREEN": "" if host_fullscreen else "1"},
        )

    def test_a_host_that_never_enters_fullscreen_fails_the_control(self) -> None:
        # Review 2 N04: no windowDidEnterFullScreen signal means nothing was measured.
        for mode in ("fresh", "stale"):
            with self.subTest(mode=mode):
                result = self.run_probe("report", mode, "default", host_fullscreen=False)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn("space-probe: no valid result for default", result.stderr)
        result = self.run_probe("not-fullscreen", "fresh", "default")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)

    def test_the_real_probe_and_host_wire_the_fullscreen_signal(self) -> None:
        # The programs are compiled, not run, here: running them takes over a desktop.
        host = (ROOT / "scripts/space-probe/host.swift").read_text()
        probe = (ROOT / "scripts/space-probe/probe.swift").read_text()
        self.assertIn("func windowDidEnterFullScreen(", host)
        self.assertIn('ProcessInfo.processInfo.environment["FULLSCREEN_FILE"]', host)
        self.assertIn('ProcessInfo.processInfo.environment["FULLSCREEN_FILE"]', probe)
        self.assertIn('"hostEnteredFullScreen"', probe)

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
        for behaviour in ("silent", "crash", "other-variant", "no-count", "wrong-mode", "host-not-front"):
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
