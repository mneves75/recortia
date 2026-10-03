#!/usr/bin/env python3
"""Keep the DEBUG E2E runner inside its isolation contract (AGENTS.md, CLAUDE.md).

The runner must never touch the real screen, the general pasteboard, the app's user defaults or
keychain, and must install no global key handler. This guard scans RecortiaApp/E2E for the APIs
that would break that contract. Its controls plant a violation in a temporary directory and run
the same scan function the real check uses.
"""

import pathlib
import re
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
E2E_DIRECTORY = ROOT / "RecortiaApp/E2E"

FORBIDDEN: dict[str, re.Pattern[str]] = {
    # Global key handlers and live permission probes.
    "EscapeHotKey": re.compile(r"\bEscapeHotKey\s*[({]"),
    "RegisterEventHotKey": re.compile(r"\bRegisterEventHotKey\s*[({]"),
    "InstallEventHandler": re.compile(r"\bInstallEventHandler\s*[({]"),
    "CGRequestScreenCaptureAccess": re.compile(r"\bCGRequestScreenCaptureAccess\s*[({]"),
    "AXIsProcessTrustedWithOptions": re.compile(r"\bAXIsProcessTrustedWithOptions\s*[({]"),
    "addGlobalMonitorForEvents": re.compile(r"\baddGlobalMonitorForEvents\b"),
    # The real screen.
    "SCShareableContent": re.compile(r"\bSCShareableContent\b"),
    "SCScreenshotManager": re.compile(r"\bSCScreenshotManager\b"),
    "CGWindowList": re.compile(r"\bCGWindowList\w*"),
    "CGDisplayCreateImage": re.compile(r"\bCGDisplayCreateImage\b"),
    # The general pasteboard, the app's user defaults, and the keychain.
    "NSPasteboard.general": re.compile(r"\bNSPasteboard\s*\.\s*general\b"),
    "UserDefaults.standard": re.compile(r"\bUserDefaults\s*\.\s*standard\b"),
    "SecItem": re.compile(r"\bSecItem(?:Add|CopyMatching|Update|Delete)\b"),
}

# `UserDefaults.standard` inside the runner is its own `dev.mvneves.Recortia.E2E` domain: E2EHarness
# refuses to start under any other bundle identifier and clears that domain first (see
# test_allowlisted_user_defaults_are_guarded_by_the_runner_domain_check). KeyboardShortcuts stores
# shortcut assignments there, and the shortcut scenarios read and reset only those keys.
ALLOWLIST: dict[str, frozenset[str]] = {
    "E2EHarness.swift": frozenset({"UserDefaults.standard"}),
    "Scenarios+Shortcuts.swift": frozenset({"UserDefaults.standard"}),
}


def scan(directory: pathlib.Path, allowlist: dict[str, frozenset[str]] | None = None) -> list[str]:
    """Return one `file:line: rule` entry for every forbidden API use under `directory`."""
    allowed = ALLOWLIST if allowlist is None else allowlist
    hits: list[str] = []
    for path in sorted(directory.rglob("*.swift")):
        permitted = allowed.get(path.name, frozenset())
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            if line.lstrip().startswith("//"):
                continue
            for rule, pattern in FORBIDDEN.items():
                if rule not in permitted and pattern.search(line):
                    hits.append(f"{path.name}:{number}: {rule}")
    return hits


class E2EIsolationTests(unittest.TestCase):
    def test_runner_source_stays_inside_the_isolation_contract(self) -> None:
        self.assertGreater(len(list(E2E_DIRECTORY.glob("*.swift"))), 0, "the E2E sources moved")
        self.assertEqual([], scan(E2E_DIRECTORY))

    def test_scan_flags_every_planted_violation(self) -> None:
        planted = {
            "EscapeHotKey": "let escape = EscapeHotKey {}",
            "RegisterEventHotKey": "RegisterEventHotKey(1, 2, id, target, 0, &ref)",
            "InstallEventHandler": "InstallEventHandler(target, handler, 1, &spec, nil, nil)",
            "CGRequestScreenCaptureAccess": "_ = CGRequestScreenCaptureAccess()",
            "AXIsProcessTrustedWithOptions": "_ = AXIsProcessTrustedWithOptions(nil)",
            "addGlobalMonitorForEvents": "NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }",
            "SCShareableContent": "let content = try await SCShareableContent.current",
            "SCScreenshotManager": "let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: c)",
            "CGWindowList": "let list = CGWindowListCreateImage(.null, .optionOnScreenOnly, 0, [])",
            "CGDisplayCreateImage": "let image = CGDisplayCreateImage(CGMainDisplayID())",
            "NSPasteboard.general": "let board = NSPasteboard.general",
            "UserDefaults.standard": "UserDefaults.standard.set(true, forKey: \"k\")",
            "SecItem": "SecItemAdd(query as CFDictionary, nil)",
        }
        self.assertEqual(set(FORBIDDEN), set(planted), "every rule needs a planted control")
        for rule, source in planted.items():
            with self.subTest(rule=rule), tempfile.TemporaryDirectory() as directory:
                (pathlib.Path(directory) / "Planted.swift").write_text(f"func probe() {{\n    {source}\n}}\n")
                self.assertEqual([f"Planted.swift:2: {rule}"], scan(pathlib.Path(directory)))

    def test_scan_passes_a_clean_directory_and_ignores_comments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            (pathlib.Path(directory) / "Clean.swift").write_text(
                "// NSPasteboard.general is forbidden here\n"
                "let board = NSPasteboard(name: NSPasteboard.Name(\"dev.mvneves.Recortia.E2E.image\"))\n"
                "let unique = NSPasteboard.withUniqueName()\n"
            )
            self.assertEqual([], scan(pathlib.Path(directory)))

    def test_allowlist_is_narrow_per_file_and_per_rule(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "E2EHarness.swift").write_text("UserDefaults.standard.removePersistentDomain(forName: d)\n")
            (root / "Other.swift").write_text("UserDefaults.standard.set(1, forKey: \"k\")\n")
            (root / "Scenarios+Shortcuts.swift").write_text("let board = NSPasteboard.general\n")
            self.assertEqual(
                ["Other.swift:1: UserDefaults.standard", "Scenarios+Shortcuts.swift:1: NSPasteboard.general"],
                scan(root),
            )

    def test_allowlisted_user_defaults_are_guarded_by_the_runner_domain_check(self) -> None:
        for name, rules in ALLOWLIST.items():
            with self.subTest(file=name):
                source = (E2E_DIRECTORY / name).read_text()
                for rule in rules:
                    self.assertRegex(source, FORBIDDEN[rule], f"stale allowlist entry {name}: {rule}")
        harness = (E2E_DIRECTORY / "E2EHarness.swift").read_text()
        guard = harness.index("domain == E2ESystemShortcuts.runnerDomain")
        first_use = harness.index("UserDefaults.standard")
        self.assertLess(guard, first_use, "the bundle-identifier guard must precede the first defaults access")
        self.assertIn("E2ESystemShortcuts.runnerDomain", harness)


if __name__ == "__main__":
    unittest.main(verbosity=2)
