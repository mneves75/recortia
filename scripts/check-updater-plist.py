#!/usr/bin/env python3
"""Fail unless the updater's Info.plist contract holds (FP-024, PRIV-01).

The shipping app names the feed, keeps automatic downloading off and disallowed (a value stored
in the user defaults cannot turn it on) and carries no automatic-check,
profiling or other Sparkle key; `SUPublicEDKey`, once the key ticket adds it, must be an Ed25519
public key (32 bytes, base64). The E2E runner carries no Sparkle key at all, so no live updater
can start in it. Without arguments it reads the plists XcodeGen generates from project.yml (the
freshness gate keeps them current); a built bundle's Contents/Info.plist works the same way.

Usage:
  scripts/check-updater-plist.py [<shipping Info.plist> <runner Info.plist>]
  scripts/check-updater-plist.py [--app-plist <path>] [--e2e-plist <path>]
"""
import argparse
import base64
import binascii
import pathlib
import plistlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FEED = "https://mneves75.github.io/recortia/appcast.xml"
# Every Sparkle key the shipping app may carry. Anything else (SUEnableAutomaticChecks,
# SUEnableSystemProfiling, SUSendProfileInfo, SUAllowsAutomaticUpdates, installer options...)
# changes what the updater does without the person choosing it.
ALLOWED = {"SUFeedURL", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUPublicEDKey"}


def load(path: pathlib.Path) -> dict:
    with path.open("rb") as file:
        value = plistlib.load(file)
    if not isinstance(value, dict):
        raise ValueError("not a dictionary")
    return value


def sparkle_keys(info: dict) -> list[str]:
    return sorted(key for key in info if key.startswith("SU"))


def shipping_problems(info: dict) -> list[str]:
    problems = [f"unreviewed Sparkle key {key}" for key in sparkle_keys(info) if key not in ALLOWED]
    if info.get("SUFeedURL") != FEED:
        problems.append(f"SUFeedURL must be {FEED}, found {info.get('SUFeedURL')!r}")
    # SUAutomaticallyUpdate is only the initial value: a stored one outranks it. The developer
    # disallow SUAllowsAutomaticUpdates=false makes Sparkle read automatic downloads as off.
    for key in ("SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"):
        if info.get(key) is not False:
            problems.append(f"{key} must be false, found {info.get(key)!r}")
    if "SUPublicEDKey" in info:
        key = info["SUPublicEDKey"]
        try:
            valid = isinstance(key, str) and len(base64.b64decode(key, validate=True)) == 32
        except (binascii.Error, ValueError):
            valid = False
        if not valid:
            problems.append("SUPublicEDKey is not a base64 Ed25519 public key (32 bytes)")
    return problems


def parse_paths(argv: list[str]) -> tuple[pathlib.Path, pathlib.Path] | None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--app-plist", type=pathlib.Path)
    parser.add_argument("--e2e-plist", type=pathlib.Path)
    parser.add_argument("positional", nargs="*", type=pathlib.Path)
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return None
    has_flags = args.app_plist is not None or args.e2e_plist is not None
    if has_flags:
        if args.positional:
            return None
        return (
            args.app_plist or (ROOT / "RecortiaApp/Info.plist"),
            args.e2e_plist or (ROOT / "RecortiaApp/E2E/Info.plist"),
        )
    if len(args.positional) == 0:
        return (ROOT / "RecortiaApp/Info.plist", ROOT / "RecortiaApp/E2E/Info.plist")
    if len(args.positional) == 2:
        return (args.positional[0], args.positional[1])
    return None


def main() -> int:
    paths = parse_paths(sys.argv[1:])
    if paths is None:
        print(
            "Usage: scripts/check-updater-plist.py [<shipping Info.plist> <runner Info.plist>] "
            "| [--app-plist <path>] [--e2e-plist <path>]",
            file=sys.stderr,
        )
        return 2
    shipping, runner = paths
    problems = []
    try:
        shipping_info, runner_info = load(shipping), load(runner)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"updater-plist: cannot read a plist: {error}", file=sys.stderr)
        return 1
    problems += [f"{shipping}: {problem}" for problem in shipping_problems(shipping_info)]
    problems += [f"{runner}: the E2E runner carries Sparkle key {key}" for key in sparkle_keys(runner_info)]
    if problems:
        for problem in problems:
            print(f"updater-plist: {problem}", file=sys.stderr)
        return 1
    key = "present" if "SUPublicEDKey" in shipping_info else "absent, so the updater stays hidden"
    print(f"updater-plist: shipping feed {FEED}, automatic updates off, public key {key}; runner has no Sparkle key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
