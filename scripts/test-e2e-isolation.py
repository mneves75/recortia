#!/usr/bin/env python3
"""Keep synthetic E2E source free of live global-key and permission probes."""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class E2EIsolationTests(unittest.TestCase):
    def test_scenarios_do_not_register_host_keys_or_request_permissions(self) -> None:
        forbidden = re.compile(
            r"\b(?:EscapeHotKey|RegisterEventHotKey|InstallEventHandler|CGRequestScreenCaptureAccess|AXIsProcessTrustedWithOptions)\s*(?:\(|\{)"
        )
        for path in (ROOT / "RecortiaApp/E2E").glob("*.swift"):
            with self.subTest(file=path.name):
                self.assertIsNone(forbidden.search(path.read_text()))

    def test_guard_rejects_the_original_live_escape_probe(self) -> None:
        source = "let escape = EscapeHotKey {}"
        self.assertRegex(source, r"\bEscapeHotKey\s*(?:\(|\{)")


if __name__ == "__main__":
    unittest.main()
