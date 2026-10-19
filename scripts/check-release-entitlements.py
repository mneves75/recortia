#!/usr/bin/env python3
"""Validate parsed distribution entitlements instead of matching incidental XML text."""

import argparse
import pathlib
import plistlib

# The exact entitlement set reviewed for a Developer ID distribution build. A new entitlement
# changes what the signed app may do, so it has to be added here deliberately.
REVIEWED_ENTITLEMENTS = {
    "com.apple.application-identifier": str,
    "com.apple.developer.team-identifier": str,
    "keychain-access-groups": list,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=pathlib.Path)
    parser.add_argument("--access-group", required=True)
    arguments = parser.parse_args()
    try:
        with arguments.plist.open("rb") as file:
            entitlements = plistlib.load(file)
    except (OSError, ValueError, plistlib.InvalidFileException):
        parser.error("distribution entitlements could not be read as a plist")
    if not isinstance(entitlements, dict):
        parser.error("distribution entitlements must be a dictionary")
    if any(key in entitlements for key in ("get-task-allow", "com.apple.security.get-task-allow")):
        parser.error("debug entitlement is present in the distribution build")
    unknown = sorted(set(entitlements) - set(REVIEWED_ENTITLEMENTS))
    if unknown:
        parser.error("unreviewed entitlement in the distribution build: " + ", ".join(unknown))
    missing = sorted(set(REVIEWED_ENTITLEMENTS) - set(entitlements))
    if missing:
        parser.error("reviewed entitlement missing from the distribution build: " + ", ".join(missing))
    for key, expected in REVIEWED_ENTITLEMENTS.items():
        if not isinstance(entitlements[key], expected):
            parser.error(f"{key} must be a {expected.__name__}")
    groups = entitlements.get("keychain-access-groups")
    if not isinstance(groups, list) or not all(isinstance(group, str) for group in groups):
        parser.error("keychain-access-groups must be a string array")
    if arguments.access_group not in groups:
        parser.error("required keychain access group is missing")
    print("release: distribution entitlement checks passed")


if __name__ == "__main__":
    main()
