#!/usr/bin/env python3
"""Fail unless the updater's Info.plist contract holds (FP-024, PRIV-01).

The shipping app names the feed, keeps automatic downloading off and carries no automatic-check,
profiling or other Sparkle key; `SUPublicEDKey`, once the key ticket adds it, must be an Ed25519
public key (32 bytes, base64). The E2E runner carries no Sparkle key at all, so no live updater
can start in it. Without arguments it reads the plists XcodeGen generates from project.yml (the
freshness gate keeps them current); a built bundle's Contents/Info.plist works the same way.

Usage: scripts/check-updater-plist.py [<shipping Info.plist> <runner Info.plist>]
"""
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
ALLOWED = {"SUFeedURL", "SUAutomaticallyUpdate", "SUPublicEDKey"}


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
    if info.get("SUAutomaticallyUpdate") is not False:
        problems.append(f"SUAutomaticallyUpdate must be false, found {info.get('SUAutomaticallyUpdate')!r}")
    if "SUPublicEDKey" in info:
        key = info["SUPublicEDKey"]
        try:
            valid = isinstance(key, str) and len(base64.b64decode(key, validate=True)) == 32
        except (binascii.Error, ValueError):
            valid = False
        if not valid:
            problems.append("SUPublicEDKey is not a base64 Ed25519 public key (32 bytes)")
    return problems


def main() -> int:
    if len(sys.argv) not in (1, 3):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    shipping, runner = (
        (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])) if len(sys.argv) == 3
        else (ROOT / "RecortiaApp/Info.plist", ROOT / "RecortiaApp/E2E/Info.plist")
    )
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
