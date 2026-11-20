#!/usr/bin/env python3
"""REL-01: the test-only-marker gate must scan every Mach-O in the app bundle, with planted controls."""

import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts/check-release-binary.sh"
MACH_O_MAGIC = bytes.fromhex("cffaedfe")  # 64-bit little-endian Mach-O header
MARKERS = ("RecortiaE2E", "RecortiaFixtures", "ChartFixture", "TextCorpus")


def mach_o(marker: str | None = None) -> bytes:
    body = b"\0" * 64 + b"Recortia production code\0"
    if marker is not None:
        body += b"\0" * 8 + marker.encode() + b"\0"
    return MACH_O_MAGIC + body


def make_app(root: pathlib.Path, *, main: bytes, extras: dict[str, bytes]) -> pathlib.Path:
    app = root / "Recortia.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/Recortia").write_bytes(main)
    for relative, data in extras.items():
        path = app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return app


def run_gate(target: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/bin/zsh", str(GATE), str(target)], capture_output=True, text=True)


class ReleaseBinaryGateTests(unittest.TestCase):
    def test_marker_in_sibling_dylib_is_rejected(self) -> None:
        for marker in MARKERS:
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                app = make_app(
                    pathlib.Path(directory),
                    main=mach_o(),
                    extras={"Contents/MacOS/Recortia.debug.dylib": mach_o(marker)},
                )
                result = run_gate(app)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn(marker, result.stderr)

    def test_marker_in_fat64_sibling_is_rejected(self) -> None:
        for magic in ("cafebabf", "bfbafeca"):  # universal headers with 64-bit offsets, both byte orders
            with self.subTest(magic=magic), tempfile.TemporaryDirectory() as directory:
                fat64 = bytes.fromhex(magic) + mach_o("RecortiaE2E")[len(MACH_O_MAGIC):]
                app = make_app(
                    pathlib.Path(directory), main=mach_o(), extras={"Contents/MacOS/Recortia.debug.dylib": fat64}
                )
                result = run_gate(app)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)

    def test_marker_in_embedded_framework_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(
                pathlib.Path(directory),
                main=mach_o(),
                extras={"Contents/Frameworks/Helper.framework/Versions/A/Helper": mach_o("RecortiaE2E")},
            )
            self.assertEqual(1, run_gate(app).returncode)

    def test_marker_in_main_executable_is_rejected_by_app_and_by_executable_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(pathlib.Path(directory), main=mach_o("RecortiaE2E"), extras={})
            self.assertEqual(1, run_gate(app).returncode)
            self.assertEqual(1, run_gate(app / "Contents/MacOS/Recortia").returncode)

    def test_clean_bundle_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(
                pathlib.Path(directory),
                main=mach_o(),
                extras={
                    "Contents/MacOS/Recortia.debug.dylib": mach_o(),
                    # Not Mach-O: resources may mention a marker without shipping test code.
                    "Contents/Resources/notes.txt": b"RecortiaE2E is documented here\n",
                },
            )
            result = run_gate(app)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(0, run_gate(app / "Contents/MacOS/Recortia").returncode)

    def test_bundle_without_any_mach_o_fails_instead_of_passing_vacuously(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(pathlib.Path(directory), main=b"#!/bin/sh\n", extras={})
            self.assertNotEqual(0, run_gate(app).returncode)

    def test_release_script_passes_the_bundle_not_only_the_executable(self) -> None:
        script = (ROOT / "scripts/release.sh").read_text()
        self.assertIn('scripts/check-release-binary.sh "$app"\n', script)


RUNNER_MARKERS = ("-RecortiaE2EOnly", "-RecortiaE2EProbe", "-RecortiaE2ELastWindowProbe", "E2ERunner")
BUILD_ARGUMENTS = (
    "-project Recortia.xcodeproj -scheme {scheme} -configuration Release -destination generic/platform=macOS "
    "-derivedDataPath .build/dd-release -onlyUsePackageVersionsFromResolvedFile "
    "CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- build"
)


class ReleaseBuildGateTests(unittest.TestCase):
    """R3-D09/D10, review F05/F10/F12: hosted CI qualifies the toolchain, builds both schemes in
    Release, scans the shipping app, and refuses a Release runner hook or foreground helper."""

    def run_build_gate(self, *, helper_executable: bool = False, marker: str | None = None,
                       runner_marker: str | None = None, doctor_exit: int = 0) -> subprocess.CompletedProcess[str]:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = root = pathlib.Path(directory.name)
        (root / "scripts").mkdir()
        for name in ("check-release-build.sh", "check-release-binary.sh"):
            (root / "scripts" / name).write_bytes((ROOT / "scripts" / name).read_bytes())
            (root / "scripts" / name).chmod(0o755)
        self.calls = root / "calls"
        doctor = root / "scripts/doctor.sh"
        doctor.write_text(f"#!/bin/sh\necho \"doctor $*\" >> '{self.calls}'\nexit {doctor_exit}\n")
        doctor.chmod(0o755)
        products = root / ".build/dd-release/Build/Products/Release"
        bin_directory = root / "bin"
        bin_directory.mkdir()
        production = (MACH_O_MAGIC + b"production").hex()
        # Stand-in xcodebuild: records its arguments and writes what a Release build of each scheme leaves.
        script = (
            "#!/bin/sh\n"
            f"echo \"xcodebuild $*\" >> '{self.calls}'\n"
            f"products='{products}'\n"
            "mkdir -p \"$products/Recortia.app/Contents/MacOS\" \"$products/RecortiaE2E.app/Contents/MacOS\"\n"
            f"printf '%s' '{production}' | xxd -r -p > \"$products/Recortia.app/Contents/MacOS/Recortia\"\n"
            f"printf '%s' '{production}' | xxd -r -p > \"$products/RecortiaE2E.app/Contents/MacOS/RecortiaE2E\"\n"
            # The E2E product links the fixture generators on purpose; that is not the runner.
            "printf 'RecortiaFixtures ChartFixture' >> \"$products/RecortiaE2E.app/Contents/MacOS/RecortiaE2E\"\n"
            "mkdir -p \"$products/RecortiaE2EForegroundHost.app/Contents\"\n"
        )
        if marker:
            script += f"printf '{marker}' >> \"$products/Recortia.app/Contents/MacOS/Recortia\"\n"
        if runner_marker:
            script += f"printf -- '{runner_marker}' >> \"$products/RecortiaE2E.app/Contents/MacOS/RecortiaE2E\"\n"
        if helper_executable:
            script += "mkdir -p \"$products/RecortiaE2EForegroundHost.app/Contents/MacOS\"\n"
        xcodebuild = bin_directory / "xcodebuild"
        xcodebuild.write_text(script)
        xcodebuild.chmod(0o755)
        products.mkdir(parents=True)
        return subprocess.run(
            ["/bin/zsh", str(root / "scripts/check-release-build.sh")], capture_output=True, text=True,
            env={"PATH": f"{bin_directory}:/usr/bin:/bin", "DEVELOPER_DIR": "/fixture"},
        )

    def test_clean_release_products_pass_after_doctor_and_both_builds(self) -> None:
        result = self.run_build_gate()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Release build gate passed", result.stdout)
        self.assertEqual([
            "doctor --release",
            "xcodebuild " + BUILD_ARGUMENTS.format(scheme="Recortia"),
            "xcodebuild " + BUILD_ARGUMENTS.format(scheme="RecortiaE2E"),
        ], self.calls.read_text().splitlines())

    def test_an_unqualified_toolchain_builds_nothing(self) -> None:
        result = self.run_build_gate(doctor_exit=1)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(["doctor --release"], self.calls.read_text().splitlines())

    def test_release_foreground_helper_with_an_executable_fails(self) -> None:
        result = self.run_build_gate(helper_executable=True)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("foreground helper has an executable in Release", result.stderr)

    def test_test_only_code_in_the_release_app_fails(self) -> None:
        result = self.run_build_gate(marker="RecortiaFixtures")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("RecortiaFixtures", result.stderr)

    def test_the_runner_in_the_release_e2e_product_fails(self) -> None:
        for runner_marker in RUNNER_MARKERS:
            with self.subTest(marker=runner_marker):
                result = self.run_build_gate(runner_marker=runner_marker)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn(f"E2E runner code ({runner_marker}) is in the Release", result.stderr)

    def test_hosted_ci_runs_the_release_build_gate_unconditionally(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        steps = re.split(r"(?m)^      - ", workflow.split("\n    steps:\n", 1)[1])
        step = next(step for step in steps if "run: scripts/check-release-build.sh" in step)
        self.assertRegex(step, r"(?m)^        run: scripts/check-release-build\.sh$")
        self.assertNotRegex(step, r"(?m)^\s*(if|continue-on-error):")
        job = workflow.split("\n    steps:\n", 1)[0].split("\n  check:\n", 1)[1]
        self.assertNotRegex(job, r"(?m)^\s*(if|continue-on-error):")


if __name__ == "__main__":
    unittest.main(verbosity=2)
