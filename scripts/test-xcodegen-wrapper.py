#!/usr/bin/env python3
"""The pinned XcodeGen wrapper: verified install, digest-keyed cache, hardened download.

A fake `curl` serves a local zip for an https pin and records its arguments; the fixture record
names that zip's own hash, never a copy of the real pin.
"""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
WRAPPER = ROOT / "scripts/xcodegen.sh"
URL = "https://example.invalid/xcodegen.zip"
FAKE_CURL = f"""#!{sys.executable}
import json, os, pathlib, shutil, sys
arguments = sys.argv[1:]
with open(os.environ["CURL_LOG"], "a") as log:
    log.write(json.dumps(arguments) + "\\n")
served = pathlib.Path(os.environ["CURL_SERVES"])
if not served.exists():
    sys.exit(22)
shutil.copy(served, arguments[arguments.index("-o") + 1])
"""


def write_zip(path: pathlib.Path, message: str) -> str:
    with zipfile.ZipFile(path, "w") as archive:
        info = zipfile.ZipInfo("xcodegen/bin/xcodegen")
        info.external_attr = 0o755 << 16
        archive.writestr(info, f'#!/bin/sh\necho "{message} [$*] in $(pwd -P)"\n')
    return hashlib.sha256(path.read_bytes()).hexdigest()


class XcodegenWrapperTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.base = pathlib.Path(directory.name)
        self.root = self.base / "repo"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy(WRAPPER, self.root / "scripts/xcodegen.sh")
        self.served = self.base / "served.zip"
        self.sha256 = write_zip(self.served, "fake xcodegen")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        self.tool("curl", FAKE_CURL)
        self.curl_log = self.base / "curl.log"
        self.caller = self.base / "caller"
        self.caller.mkdir()
        self.tools = self.root / ".build/tools"

    def tool(self, name: str, source: str) -> None:
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def install_dir(self, sha256: str) -> pathlib.Path:
        return self.tools / f"xcodegen-0.0.1-{sha256[:16]}"

    def run_wrapper(self, *arguments: str, sha256: str | None = None, url: str = URL,
                    background: bool = False) -> subprocess.CompletedProcess[str] | subprocess.Popen[str]:
        (self.root / "TOOLCHAIN.json").write_text(json.dumps(
            {"xcodegen": {"version": "0.0.1", "sha256": sha256 or self.sha256, "url": url}}))
        command = ["/bin/zsh", str(self.root / "scripts/xcodegen.sh"), *arguments]
        environment = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root),
                       "CURL_LOG": str(self.curl_log), "CURL_SERVES": str(self.served)}
        if background:
            return subprocess.Popen(command, cwd=self.caller, env=environment, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return subprocess.run(command, cwd=self.caller, capture_output=True, text=True, timeout=30,
                              env=environment)

    def curl_calls(self) -> list[list[str]]:
        if not self.curl_log.exists():
            return []
        return [json.loads(line) for line in self.curl_log.read_text().splitlines()]

    def test_verified_download_installs_once_and_runs_in_the_callers_directory(self) -> None:
        result = self.run_wrapper("generate", "--quiet")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn(f"fake xcodegen [generate --quiet] in {self.caller.resolve()}", result.stdout)
        self.assertTrue((self.install_dir(self.sha256) / "bin/xcodegen").exists())
        self.assertEqual([self.install_dir(self.sha256).name], sorted(p.name for p in self.tools.iterdir()))
        self.served.unlink()
        cached = self.run_wrapper("--version")
        self.assertEqual(0, cached.returncode, cached.stdout + cached.stderr)
        self.assertIn("fake xcodegen [--version]", cached.stdout)
        self.assertEqual(1, len(self.curl_calls()), "a warm cache downloads nothing")

    def test_download_allows_only_https_and_ends_options_before_the_url(self) -> None:
        self.assertEqual(0, self.run_wrapper("generate").returncode)
        [arguments] = self.curl_calls()
        self.assertEqual(URL, arguments[-1])
        self.assertEqual("--", arguments[-2])
        for flag in ("--proto", "--proto-redir"):
            self.assertEqual("=https", arguments[arguments.index(flag) + 1], flag)

    def test_checksum_mismatch_installs_nothing(self) -> None:
        wrong = hashlib.sha256(b"not the pinned zip").hexdigest()
        result = self.run_wrapper("generate", sha256=wrong)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("nothing installed", result.stderr)
        self.assertNotIn("fake xcodegen", result.stdout)
        self.assertEqual([], list(self.tools.iterdir()))

    def test_a_warm_cache_never_satisfies_a_changed_digest(self) -> None:
        self.assertEqual(0, self.run_wrapper("generate").returncode)
        self.served.unlink()
        changed = hashlib.sha256(b"a different release at the same version").hexdigest()
        result = self.run_wrapper("generate", sha256=changed)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertNotIn("fake xcodegen", result.stdout)
        self.assertIn("download of", result.stderr)

    def test_malformed_pin_is_refused_before_download(self) -> None:
        cases = [{"sha256": value} for value in ("ABC", self.sha256.upper())] + [
            {"url": value} for value in (
                "", "http://example.invalid/xcodegen.zip", "file:///tmp/xcodegen.zip",
                "-Khttps://example.invalid/x.zip", "--config=https://example.invalid/x.zip",
                "https://example.invalid/x y.zip", "HTTPS://example.invalid/x.zip",
            )]
        for case in cases:
            with self.subTest(**case):
                result = self.run_wrapper("generate", **case)  # type: ignore[arg-type]
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn("pin error", result.stderr)
                self.assertEqual([], self.curl_calls())
                self.assertFalse((self.root / ".build").exists())

    def test_a_symlinked_cache_entry_is_refused(self) -> None:
        elsewhere = self.base / "elsewhere"
        write_zip(self.base / "other.zip", "unverified xcodegen")
        shutil.unpack_archive(self.base / "other.zip", elsewhere)
        (elsewhere / "xcodegen/bin/xcodegen").chmod(0o755)
        self.tools.mkdir(parents=True)
        self.install_dir(self.sha256).symlink_to(elsewhere / "xcodegen", target_is_directory=True)
        result = self.run_wrapper("generate")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("symbolic link", result.stderr)
        self.assertNotIn("unverified xcodegen", result.stdout)

    def test_an_entry_published_by_a_concurrent_run_is_used_not_nested(self) -> None:
        # The other run publishes while this one is unpacking; this run must discard its staging.
        winner = self.install_dir(self.sha256)
        self.tool("unzip", f"#!/bin/sh\n/usr/bin/unzip \"$@\" || exit $?\n"
                  f"mkdir -p '{winner}/bin'\nprintf '#!/bin/sh\\necho winner xcodegen\\n' > '{winner}/bin/xcodegen'\n"
                  f"chmod 755 '{winner}/bin/xcodegen'\n")
        result = self.run_wrapper("generate")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("winner xcodegen", result.stdout)
        self.assertEqual(["bin"], sorted(p.name for p in winner.iterdir()))
        self.assertEqual([winner.name], sorted(p.name for p in self.tools.iterdir()), "no staging left")

    def test_parallel_cold_runs_all_succeed_with_one_entry(self) -> None:
        runs = [self.run_wrapper("generate", background=True) for _ in range(8)]
        for run in runs:
            stdout, stderr = run.communicate(timeout=60)  # type: ignore[union-attr]
            self.assertEqual(0, run.returncode, stdout + stderr)
            self.assertIn("fake xcodegen [generate]", stdout)
        entry = self.install_dir(self.sha256)
        self.assertEqual([entry.name], sorted(p.name for p in self.tools.iterdir()))
        self.assertEqual(["bin"], sorted(p.name for p in entry.iterdir()))
        self.assertFalse(os.path.islink(entry))


if __name__ == "__main__":
    unittest.main(verbosity=2)
