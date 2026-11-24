#!/usr/bin/env python3
"""Prove the updater Info.plist check passes on this tree and fails on each planted violation."""
import base64
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts/check-updater-plist.py"
SHIPPING = ROOT / "RecortiaApp/Info.plist"
RUNNER = ROOT / "RecortiaApp/E2E/Info.plist"


class UpdaterPlistTests(unittest.TestCase):
    def run_check(self, *paths: pathlib.Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(CHECK), *map(str, paths)], capture_output=True, text=True, timeout=15,
        )

    def planted(self, shipping_change=None, runner_change=None) -> subprocess.CompletedProcess:
        """Copies both generated plists, applies the changes to the parsed dictionaries, and checks."""
        (ROOT / ".scratch").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            copies = []
            for source, change in ((SHIPPING, shipping_change), (RUNNER, runner_change)):
                info = plistlib.loads(source.read_bytes())
                if change:
                    change(info)
                copy = pathlib.Path(directory) / f"{source.parent.name}-Info.plist"
                copy.write_bytes(plistlib.dumps(info))
                copies.append(copy)
            return self.run_check(*copies)

    def test_this_tree_passes_without_a_public_key(self):
        result = self.run_check()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("public key absent", result.stdout)
        self.assertNotIn("SUPublicEDKey", plistlib.loads(SHIPPING.read_bytes()))

    def test_unchanged_copies_pass(self):
        result = self.planted()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_a_well_formed_public_key_passes(self):
        key = base64.b64encode(bytes(range(32))).decode()
        result = self.planted(lambda info: info.__setitem__("SUPublicEDKey", key))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("public key present", result.stdout)

    def test_each_shipping_violation_fails(self):
        cases = {
            "another feed": (lambda i: i.__setitem__("SUFeedURL", "https://example.com/appcast.xml"), "SUFeedURL"),
            "an http feed": (
                lambda i: i.__setitem__("SUFeedURL", "http://mneves75.github.io/recortia/appcast.xml"), "SUFeedURL"),
            "no feed": (lambda i: i.pop("SUFeedURL"), "SUFeedURL"),
            "automatic updates on": (lambda i: i.__setitem__("SUAutomaticallyUpdate", True), "SUAutomaticallyUpdate"),
            "automatic updates unset": (lambda i: i.pop("SUAutomaticallyUpdate"), "SUAutomaticallyUpdate"),
            "automatic updates as a string": (
                lambda i: i.__setitem__("SUAutomaticallyUpdate", "NO"), "SUAutomaticallyUpdate"),
            "automatic checks on": (lambda i: i.__setitem__("SUEnableAutomaticChecks", True), "SUEnableAutomaticChecks"),
            "automatic checks declared off": (
                lambda i: i.__setitem__("SUEnableAutomaticChecks", False), "SUEnableAutomaticChecks"),
            "system profiling": (lambda i: i.__setitem__("SUEnableSystemProfiling", True), "SUEnableSystemProfiling"),
            "profile info": (lambda i: i.__setitem__("SUSendProfileInfo", True), "SUSendProfileInfo"),
            "automatic-update option allowed": (
                lambda i: i.__setitem__("SUAllowsAutomaticUpdates", True), "SUAllowsAutomaticUpdates"),
            # Without the developer disallow, a stored SUAutomaticallyUpdate wins over the plist.
            "automatic-update option unset": (lambda i: i.pop("SUAllowsAutomaticUpdates"), "SUAllowsAutomaticUpdates"),
            "automatic-update option as a string": (
                lambda i: i.__setitem__("SUAllowsAutomaticUpdates", "NO"), "SUAllowsAutomaticUpdates"),
            "a malformed key": (lambda i: i.__setitem__("SUPublicEDKey", "not base64!"), "SUPublicEDKey"),
            "a short key": (
                lambda i: i.__setitem__("SUPublicEDKey", base64.b64encode(b"short").decode()), "SUPublicEDKey"),
            "an empty key": (lambda i: i.__setitem__("SUPublicEDKey", ""), "SUPublicEDKey"),
        }
        for name, (change, expected) in cases.items():
            with self.subTest(name):
                result = self.planted(change)
                self.assertEqual(1, result.returncode, result.stdout)
                self.assertIn(expected, result.stderr)

    def test_a_runner_with_any_sparkle_key_fails(self):
        for key, value in (("SUFeedURL", "https://mneves75.github.io/recortia/appcast.xml"),
                           ("SUPublicEDKey", base64.b64encode(bytes(32)).decode()), ("SUEnableAutomaticChecks", False)):
            with self.subTest(key):
                result = self.planted(runner_change=lambda info: info.__setitem__(key, value))
                self.assertEqual(1, result.returncode, result.stdout)
                self.assertIn(f"E2E runner carries Sparkle key {key}", result.stderr)

    def test_a_missing_or_unreadable_plist_fails(self):
        (ROOT / ".scratch").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            garbage = pathlib.Path(directory) / "Info.plist"
            garbage.write_text("not a plist")
            for paths in ((SHIPPING, pathlib.Path(directory) / "missing.plist"), (garbage, RUNNER)):
                with self.subTest(paths):
                    result = self.run_check(*paths)
                    self.assertEqual(1, result.returncode, result.stdout)
                    self.assertIn("cannot read a plist", result.stderr)

    def test_explicit_app_and_e2e_flags_validate_exported_plists(self):
        (ROOT / ".scratch").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            app_copy = pathlib.Path(directory) / "ExportedApp-Info.plist"
            e2e_copy = pathlib.Path(directory) / "ExportedE2E-Info.plist"
            app_copy.write_bytes(SHIPPING.read_bytes())
            e2e_copy.write_bytes(RUNNER.read_bytes())

            for argv in (
                ["--app-plist", str(app_copy)],
                ["--e2e-plist", str(e2e_copy)],
                ["--app-plist", str(app_copy), "--e2e-plist", str(e2e_copy)],
            ):
                with self.subTest(argv=argv):
                    result = subprocess.run(
                        [sys.executable, str(CHECK), *argv], capture_output=True, text=True, timeout=15
                    )
                    self.assertEqual(0, result.returncode, result.stderr)

            bad_app = plistlib.loads(SHIPPING.read_bytes())
            bad_app["SUAllowsAutomaticUpdates"] = True
            app_copy.write_bytes(plistlib.dumps(bad_app))
            result = subprocess.run(
                [sys.executable, str(CHECK), "--app-plist", str(app_copy)], capture_output=True, text=True, timeout=15
            )
            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn("SUAllowsAutomaticUpdates", result.stderr)

            app_copy.write_bytes(SHIPPING.read_bytes())
            bad_e2e = plistlib.loads(RUNNER.read_bytes())
            bad_e2e["SUFeedURL"] = "https://mneves75.github.io/recortia/appcast.xml"
            e2e_copy.write_bytes(plistlib.dumps(bad_e2e))
            result = subprocess.run(
                [sys.executable, str(CHECK), "--app-plist", str(app_copy), "--e2e-plist", str(e2e_copy)],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn("E2E runner carries Sparkle key SUFeedURL", result.stderr)

            for invalid in ([str(app_copy)], ["--app-plist", str(app_copy), str(e2e_copy)]):
                with self.subTest(invalid=invalid):
                    result = subprocess.run(
                        [sys.executable, str(CHECK), *invalid], capture_output=True, text=True, timeout=15
                    )
                    self.assertEqual(2, result.returncode, result.stdout)


if __name__ == "__main__":
    unittest.main()
