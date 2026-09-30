#!/usr/bin/env python3
"""Validate parsed distribution entitlements instead of matching incidental XML text."""

import argparse
import pathlib
import plistlib


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
    groups = entitlements.get("keychain-access-groups")
    if not isinstance(groups, list) or not all(isinstance(group, str) for group in groups):
        parser.error("keychain-access-groups must be a string array")
    if arguments.access_group not in groups:
        parser.error("required keychain access group is missing")
    print("release: distribution entitlement checks passed")


if __name__ == "__main__":
    main()
