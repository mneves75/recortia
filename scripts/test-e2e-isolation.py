#!/usr/bin/env python3
"""Keep the DEBUG E2E runner inside its isolation contract (AGENTS.md, CLAUDE.md).

The runner must never touch the real screen, the general pasteboard, the app's user defaults or
keychain, and must install no global key handler. This guard scans RecortiaApp/E2E for the APIs
that would break that contract. Its controls plant a violation in a temporary directory and run
the same scan function the real check uses.
"""

import os
import pathlib
import re
import signal
import subprocess
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
    # Another app's interface: element snapping uses a synthetic tree in the runner (ADR-010).
    "AXUIElementCreateSystemWide": re.compile(r"\bAXUIElementCreateSystemWide\s*[({]"),
    "LiveInterfaceElements": re.compile(r"\bLiveInterfaceElements\s*[({]"),
    "addGlobalMonitorForEvents": re.compile(r"\baddGlobalMonitorForEvents\b"),
    # The real screen.
    "SCShareableContent": re.compile(r"\bSCShareableContent\b"),
    "SCScreenshotManager": re.compile(r"\bSCScreenshotManager\b"),
    "CGWindowList": re.compile(r"\bCGWindowList\w*"),
    "CGDisplayCreateImage": re.compile(r"\bCGDisplayCreateImage\b"),
    # The general pasteboard, the app's user defaults, and the keychain.
    "NSPasteboard.general": re.compile(r"\bNSPasteboard\s*\.\s*general\b"),
    # The same pasteboard and defaults reachable through the initialiser spellings: a scan that
    # only knows the dot spelling reports clean while the runner rewrites the user's real consent.
    "NSPasteboard.generalByName": re.compile(
        r"\bNSPasteboard\s*\(\s*name:\s*(?:\.\s*general\b|NSPasteboard\.Name\.general\b)"
    ),
    "UserDefaults.standard": re.compile(r"\bUserDefaults\s*\.\s*standard\b"),
    "UserDefaults.suiteName": re.compile(r"\bUserDefaults\s*\(\s*suiteName\s*:"),
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
            "AXUIElementCreateSystemWide": "let system = AXUIElementCreateSystemWide()",
            "LiveInterfaceElements": "let elements = LiveInterfaceElements()",
            "addGlobalMonitorForEvents": "NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }",
            "SCShareableContent": "let content = try await SCShareableContent.current",
            "SCScreenshotManager": "let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: c)",
            "CGWindowList": "let list = CGWindowListCreateImage(.null, .optionOnScreenOnly, 0, [])",
            "CGDisplayCreateImage": "let image = CGDisplayCreateImage(CGMainDisplayID())",
            "NSPasteboard.general": "let board = NSPasteboard.general",
            "NSPasteboard.generalByName": "let board = NSPasteboard(name: .general)",
            "UserDefaults.standard": "UserDefaults.standard.set(true, forKey: \"k\")",
            "UserDefaults.suiteName": "let d = UserDefaults(suiteName: \"dev.mvneves.Recortia\")",
            "SecItem": "SecItemAdd(query as CFDictionary, nil)",
        }
        self.assertEqual(set(FORBIDDEN), set(planted), "every rule needs a planted control")
        for rule, source in planted.items():
            with self.subTest(rule=rule), tempfile.TemporaryDirectory() as directory:
                (pathlib.Path(directory) / "Planted.swift").write_text(f"func probe() {{\n    {source}\n}}\n")
                self.assertEqual([f"Planted.swift:2: {rule}"], scan(pathlib.Path(directory)))

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
        # `str.index` counts comment lines, so a guard quoted in a comment would satisfy this
        # check on its own. Read the executable lines only, as `scan` already does.
        code = "\n".join(
            line for line in harness.splitlines() if not line.lstrip().startswith("//")
        )
        self.assertRegex(
            code,
            r"guard\s+let\s+domain\s*=\s*Bundle\.main\.bundleIdentifier\s*,\s*\n?\s*"
            r"domain\s*==\s*E2ESystemShortcuts\.runnerDomain",
            "the runner must compare the real bundle identifier with its own domain",
        )
        guard = code.index("domain == E2ESystemShortcuts.runnerDomain")
        first_use = code.index("UserDefaults.standard")
        self.assertLess(guard, first_use, "the bundle-identifier guard must precede the first defaults access")


APP_ENTRY = ROOT / "RecortiaApp/App/RecortiaApp.swift"
ADMIT = "E2ERunner.admit()"
# The line every refused launch prints before exiting 2 (E2ERunner.admit).
REFUSAL = "[e2e] RecortiaE2E refuses this launch"
# Set by scripts/check.sh after the E2E target builds; without it the process controls are skipped.
BINARY = os.environ.get("RECORTIA_E2E_BINARY")


def launch_guard_problems(entry: str) -> list[str]:
    """Why AppDelegate could build its live composition root before the launch request was admitted
    (R3-D01). The process controls below prove what admission itself refuses."""
    code = "\n".join(line for line in entry.splitlines() if not line.lstrip().startswith("//"))
    init = re.search(r"override init\(\)\s*\{(.*?)\n    \}", code, re.S)
    if init is None:
        return ["AppDelegate.init not found"]
    body = init.group(1)
    branches = re.findall(r"#if RECORTIA_E2E(.*?)#(?:else|endif)", body, re.S)
    if not any(ADMIT in branch for branch in branches):
        return [f"no RECORTIA_E2E branch of AppDelegate.init calls {ADMIT}"]
    if body.index(ADMIT) > body.find("AppModel("):
        return [f"{ADMIT} must run before AppModel is built"]
    return []


def run_supervised(arguments: list[str], timeout: float = 30) -> tuple[int | None, str, bool]:
    """Runs the binary in its own process group. Returns its exit status (None on timeout), its
    stderr, and whether any process of the group outlived it; the group is always killed."""
    process = subprocess.Popen(
        [BINARY, *arguments], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        start_new_session=True,
    )
    try:
        _, stderr = process.communicate(timeout=timeout)
        status: int | None = process.returncode
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        _, stderr = process.communicate()
        return None, stderr, True
    try:
        os.killpg(process.pid, signal.SIGKILL)
        survived = True
    except ProcessLookupError:
        survived = False
    return status, stderr, survived


class E2ELaunchGuardTests(unittest.TestCase):
    def test_launch_request_is_admitted_before_the_app_model_exists(self) -> None:
        self.assertEqual([], launch_guard_problems(APP_ENTRY.read_text()))

    def test_planted_launch_guard_regressions_are_reported(self) -> None:
        entry = APP_ENTRY.read_text()
        line = re.compile(r"^(\s*)(.*" + re.escape(ADMIT) + r".*)$", re.M)
        self.assertRegex(entry, line)
        self.assertTrue(launch_guard_problems(line.sub("", entry, count=1)), "a removed call must fail")
        commented = line.sub(r"\1// \2", entry, count=1)
        self.assertTrue(launch_guard_problems(commented), "a commented-out call must fail")
        # Still inside a RECORTIA_E2E branch, but after AppModel: only the ordering check catches it.
        late = line.sub("", entry, count=1).replace(
            "super.init()", f"#if RECORTIA_E2E\n            _ = {ADMIT}\n        #endif\n        super.init()", 1
        )
        self.assertEqual([f"{ADMIT} must run before AppModel is built"], launch_guard_problems(late))

    @unittest.skipUnless(BINARY, "RECORTIA_E2E_BINARY is set by scripts/check.sh after the E2E build")
    def test_built_binary_refuses_missing_or_malformed_requests(self) -> None:
        # Negative controls only: a valid request starts the runner, which scripts/e2e.sh exercises.
        with tempfile.TemporaryDirectory() as scratch:
            out = str(pathlib.Path(scratch) / "never-created")
            refused = {
                "no arguments (opened from Finder)": [],
                "runner flag without a directory": ["-RecortiaE2E"],
                "relative output directory": ["-RecortiaE2E", "relative/output"],
                "only flag without ids": ["-RecortiaE2E", out, "-RecortiaE2EOnly"],
                "unknown scenario id": ["-RecortiaE2E", out, "-RecortiaE2EOnly", "no-such-id"],
                "duplicate runner flag": ["-RecortiaE2E", out, "-RecortiaE2E", out],
                "duplicate only flag": ["-RecortiaE2E", out, "-RecortiaE2EOnly", "settings", "-RecortiaE2EOnly", "settings"],
                "unknown panel probe": ["-RecortiaE2EProbe", "no-such-probe"],
                "panel probe without a kind": ["-RecortiaE2EProbe"],
                "duplicate panel probe": ["-RecortiaE2EProbe", "pin-panel", "-RecortiaE2EProbe", "pin-panel"],
                "unknown last-window probe": ["-RecortiaE2ELastWindowProbe", "no-such-probe"],
                "probe and runner": ["-RecortiaE2EProbe", "pin-panel", "-RecortiaE2E", out],
                "two probe modes": ["-RecortiaE2EProbe", "pin-panel", "-RecortiaE2ELastWindowProbe", "launch-without-window"],
                "probe with a scenario list": ["-RecortiaE2EProbe", "pin-panel", "-RecortiaE2EOnly", "settings"],
            }
            for name, arguments in refused.items():
                with self.subTest(name):
                    status, stderr, survived = run_supervised(arguments)
                    self.assertIsNotNone(status, f"{name}: the binary kept running instead of refusing")
                    self.assertEqual(2, status, f"{name}: {stderr.strip()}")
                    self.assertIn(REFUSAL, stderr, f"{name}: refused by something other than admission")
                    self.assertFalse(survived, f"{name}: a child process outlived the refused launch")
                    self.assertFalse(pathlib.Path(out).exists(), f"{name}: the runner created its output")


if __name__ == "__main__":
    unittest.main(verbosity=2)
