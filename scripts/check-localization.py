#!/usr/bin/env python3
"""Fails when a string the compiler extracted from the app has no translated pt-BR entry.

Usage: scripts/check-localization.py <derived-data-dir> [target]
Reads the `.stringsdata` files the build emits (SWIFT_EMIT_LOC_STRINGS) for the target (default
Recortia) and checks every key against RecortiaApp/Resources/<table>.xcstrings.
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
derived = pathlib.Path(sys.argv[1])
target = sys.argv[2] if len(sys.argv) > 2 else "Recortia"
data = sorted(derived.glob(f"Build/Intermediates.noindex/Recortia.build/*/{target}.build/Objects-normal/*/*.stringsdata"))
if not data:
    sys.exit(f"localization: no .stringsdata for {target} under {derived}; build the app first")

def translated(node):
    """True when every leaf of a localization (plain, or plural/device variations, nested) is a
    translated, non-empty string unit. Xcode prefills variations with untranslated source text."""
    if "stringUnit" in node:
        unit = node["stringUnit"]
        return unit.get("state") == "translated" and bool(unit.get("value"))
    variations = node.get("variations")
    if not variations:
        return False
    cases = [case for kind in variations.values() for case in kind.values()]
    return bool(cases) and all(translated(case) for case in cases)


catalogs = {}
missing = []
checked = 0
for path in data:
    record = json.loads(path.read_text())
    for table, entries in record.get("tables", {}).items():
        if table not in catalogs:
            file = root / "RecortiaApp" / "Resources" / f"{table}.xcstrings"
            if not file.exists():
                sys.exit(f"localization: {record['source']} uses table {table}, which has no catalog")
            catalogs[table] = json.loads(file.read_text())["strings"]
        for entry in entries:
            key, checked = entry["key"], checked + 1
            item = catalogs[table].get(key)
            if item is not None and item.get("shouldTranslate") is False:
                continue
            pt = (item or {}).get("localizations", {}).get("pt-BR", {})
            if not translated(pt):
                line = entry.get("location", {}).get("startingLine", "?")
                missing.append(f"{pathlib.Path(record['source']).relative_to(root)}:{line}: [{table}] {key!r}")

if missing:
    print("localization: strings without a translated pt-BR entry:", file=sys.stderr)
    print("\n".join(sorted(set(missing))), file=sys.stderr)
    sys.exit(1)
print(f"localization: {checked} extracted strings all have pt-BR translations")
