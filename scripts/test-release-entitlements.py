#!/usr/bin/env python3
"""REL-01/02: exercise the actual distribution-entitlement gate with adversarial plists."""

import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GROUP = "Q96FUTC5G8.dev.mvneves.Recortia"


class ReleaseEntitlementTests(unittest.TestCase):
    def run_gate(self, values: object) -> int:
        script = (ROOT / "scripts/release.sh").read_text()
        self.assertIn('python3 "$src/scripts/check-release-entitlements.py" "$entitlements"', script)
        with tempfile.TemporaryDirectory(dir=ROOT / ".scratch") as directory:
            fixture = pathlib.Path(directory) / "entitlements.plist"
            fixture.write_bytes(plistlib.dumps(values))
            result = subprocess.run(
                ["python3", str(ROOT / "scripts/check-release-entitlements.py"), str(fixture),
                 "--access-group", GROUP], capture_output=True, text=True,
            )
            return result.returncode

    def test_valid_group(self) -> None:
        self.assertEqual(0, self.run_gate({
            "com.apple.application-identifier": GROUP, "keychain-access-groups": [GROUP],
        }))

    def test_application_identifier_is_not_an_access_group(self) -> None:
        self.assertNotEqual(0, self.run_gate({"com.apple.application-identifier": GROUP}))

    def test_wrong_group_and_wrong_type(self) -> None:
        for groups in (["OTHER.group"], GROUP, {"name": GROUP}):
            with self.subTest(groups=groups):
                self.assertNotEqual(0, self.run_gate({
                    "com.apple.application-identifier": GROUP, "keychain-access-groups": groups,
                }))

    def test_debug_entitlement_is_rejected(self) -> None:
        self.assertNotEqual(0, self.run_gate({"keychain-access-groups": [GROUP], "get-task-allow": False}))

    def test_non_dictionary_is_rejected(self) -> None:
        self.assertNotEqual(0, self.run_gate([GROUP]))


if __name__ == "__main__":
    (ROOT / ".scratch").mkdir(exist_ok=True)
    unittest.main(verbosity=2)
