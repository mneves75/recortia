#!/usr/bin/env python3
"""Fail unless every place that states the deployment target states the same one (ADR-008).

TOOLCHAIN.json records it, project.yml sets it for the app (`deploymentTarget` and every
`MACOSX_DEPLOYMENT_TARGET`), the generated project carries it, and Package.swift sets it for
RecortiaKit. Nothing else ties them together, so a floor change that misses one builds silently.

Usage: scripts/check-deployment-target.py [repository root]
"""
import json
import pathlib
import re
import sys


def normalized(version: str) -> str:
    parts = version.split(".")
    while len(parts) > 1 and parts[-1] == "0":
        parts.pop()
    return ".".join(parts)


def values(root: pathlib.Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    try:
        toolchain = json.loads((root / "TOOLCHAIN.json").read_text())["minimum_deployment_target"]
        found["TOOLCHAIN.json minimum_deployment_target"] = [str(toolchain)]
    except (OSError, KeyError, json.JSONDecodeError) as error:
        found["TOOLCHAIN.json minimum_deployment_target"] = []
        print(f"deployment-target: TOOLCHAIN.json: {error}", file=sys.stderr)

    spec = (root / "project.yml").read_text()
    block = re.search(r"^\s*deploymentTarget:\s*\n\s+macOS:\s*\"?([0-9.]+)\"?", spec, re.MULTILINE)
    found["project.yml deploymentTarget.macOS"] = [block.group(1)] if block else []
    found["project.yml MACOSX_DEPLOYMENT_TARGET"] = re.findall(
        r"MACOSX_DEPLOYMENT_TARGET:\s*\"?([0-9.]+)\"?", spec)

    project = (root / "Recortia.xcodeproj/project.pbxproj").read_text()
    found["project.pbxproj MACOSX_DEPLOYMENT_TARGET"] = re.findall(
        r"MACOSX_DEPLOYMENT_TARGET = \"?([0-9.]+)\"?;", project)

    manifest = (root / "Packages/RecortiaKit/Package.swift").read_text()
    package = [f"{major}.{minor or '0'}" for major, minor in re.findall(r"\.macOS\(\.v(\d+)(?:_(\d+))?\)", manifest)]
    package += re.findall(r"\.macOS\(\"([0-9.]+)\"\)", manifest)
    found["Package.swift platforms .macOS"] = package
    return found


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
    try:
        found = values(root)
    except OSError as error:
        print(f"deployment-target: {error}", file=sys.stderr)
        return 1
    problems = [f"{place}: no value found" for place, versions in found.items() if not versions]
    distinct = {normalized(v) for versions in found.values() for v in versions}
    if len(distinct) > 1:
        problems.append("the deployment targets differ:")
        problems += [f"  {place}: {', '.join(versions)}" for place, versions in found.items() if versions]
    if problems:
        for problem in problems:
            print(f"deployment-target: {problem}", file=sys.stderr)
        return 1
    print(f"deployment-target: macOS {distinct.pop()} in all {len(found)} places")
    return 0


if __name__ == "__main__":
    sys.exit(main())
