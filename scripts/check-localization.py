#!/usr/bin/env python3
"""Fails when an extracted string lacks a translated pt-BR entry or mismatches format specifiers.

Usage:
  scripts/check-localization.py <derived-data-dir> [target] [configuration]
  scripts/check-localization.py --catalogs [catalog.xcstrings ...]

Reads the `.stringsdata` files the build emits (SWIFT_EMIT_LOC_STRINGS) for the target (default
Recortia, configuration Debug) and checks every key against RecortiaApp/Resources/<table>.xcstrings
for translated pt-BR entries and printf/Foundation format-specifier parity. With `--catalogs`,
checks format-specifier parity directly across the given `.xcstrings` files (defaulting to all
catalogs under RecortiaApp/Resources).
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Printf / Foundation format specifiers and xcstrings `%#@name@` substitutions (`%%` first).
FORMAT_SPECIFIER = re.compile(
    r"%%|%#@(?P<sub>[A-Za-z0-9_]+)@|%(?:(?P<pos>\d+)\$)?(?P<flags>[-+ #0']*)"
    r"(?P<width>\*(?:\d+\$)?|\d+)?(?:\.(?P<prec>\*(?:\d+\$)?|\d+))?"
    r"(?P<length>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiIuUxXoOfFeEgGaAcCsSp])"
)
VALID_SUB_SPEC = re.compile(r"^(?:hh|h|ll|l|q|L|z|t|j)?[@dDiIuUxXoOfFeEgGaAcCsSp]$")
INTEGER_CONVERSIONS = set("dDiIuUxXoO")


def translated(node: dict) -> bool:
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


def variation_leaves(
    node: dict, prefix: tuple[tuple[str, str], ...] = ()
) -> dict[tuple[tuple[str, str], ...], str]:
    """Map variation path tuples (e.g. `(('plural', 'other'),)`) to stringUnit values."""
    if "stringUnit" in node:
        value = node["stringUnit"].get("value")
        return {prefix: value} if isinstance(value, str) else {}
    variations = node.get("variations")
    if not variations:
        return {}
    result: dict[tuple[tuple[str, str], ...], str] = {}
    for kind_name, cases in variations.items():
        for case_name, case_node in cases.items():
            result.update(variation_leaves(case_node, prefix + ((kind_name, case_name),)))
    return result


def is_singular_plural_path(path: tuple[tuple[str, str], ...]) -> bool:
    return any(kind == "plural" and case in ("one", "zero") for kind, case in path)


def is_single_integer_signature(sig: tuple[tuple[int, str], ...]) -> bool:
    return len(sig) == 1 and sig[0][1][-1] in INTEGER_CONVERSIONS


def format_signature(text: str, substitutions: dict | None = None) -> tuple[tuple[int, str], ...] | None:
    """Canonical argument-index -> conversion-type mapping, or None on malformed specs/substitutions."""
    subs = substitutions or {}
    mapping: dict[int, str] = {}
    sequential = 1
    saw_positional = False
    saw_sequential = False

    def record(pos: int, conv: str) -> bool:
        if pos < 1:
            return False
        if pos in mapping and mapping[pos] != conv:
            return False
        mapping[pos] = conv
        return True

    def record_star(token: str | None) -> bool:
        nonlocal sequential, saw_positional, saw_sequential
        if not token or not token.startswith("*"):
            return True
        if token == "*":
            pos = sequential
            sequential += 1
            saw_sequential = True
        else:
            pos = int(token[1:-1])
            saw_positional = True
        return record(pos, "d")

    for match in FORMAT_SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        sub_name = match.group("sub")
        if sub_name is not None:
            sub = subs.get(sub_name)
            if not isinstance(sub, dict):
                return None
            pos = sub.get("argNum")
            conv = sub.get("formatSpecifier")
            if not isinstance(pos, int) or isinstance(pos, bool) or pos < 1:
                return None
            if not isinstance(conv, str) or not VALID_SUB_SPEC.match(conv):
                return None
            # Each leaf inside a substitution may use `%arg` (for its own specifier) and no stray specs.
            for sub_path, sub_leaf in variation_leaves(sub).items():
                expanded = sub_leaf.replace("%arg", f"%{conv}")
                sub_sig = format_signature(expanded)
                if sub_sig is None:
                    return None
                if is_singular_plural_path(sub_path) and conv[-1] in INTEGER_CONVERSIONS:
                    if sub_sig not in ((), ((1, conv),)):
                        return None
                elif sub_sig != ((1, conv),):
                    return None
            saw_positional = True
            if not record(pos, conv):
                return None
        else:
            if not record_star(match.group("width")) or not record_star(match.group("prec")):
                return None
            pos_raw = match.group("pos")
            if pos_raw is not None:
                pos = int(pos_raw)
                saw_positional = True
            else:
                pos = sequential
                sequential += 1
                saw_sequential = True
            conv = (match.group("length") or "") + match.group("conv")
            if not record(pos, conv):
                return None
    if saw_positional and saw_sequential:
        return None
    if mapping and set(mapping) != set(range(1, max(mapping) + 1)):
        return None
    return tuple(sorted(mapping.items()))


def format_parity_problems(table: str, key: str, item: dict) -> list[str]:
    """Fail closed when pt-BR disagrees with en (or the source key) on format specifiers.

    Plural variations are compared by variation case: `"other"` requires exact parity with `en`
    (or the source key), while `"one"` / `"zero"` may omit a single integer count specifier when
    natural (e.g. `"Um item"`), still rejecting any type mismatch.
    """
    locs = item.get("localizations", {})
    pt_node = locs.get("pt-BR")
    if not pt_node:
        return []
    pt_leaves = variation_leaves(pt_node)
    if not pt_leaves:
        return []
    en_node = locs.get("en")
    en_leaves = variation_leaves(en_node) if en_node is not None else {(): key}
    en_subs = en_node.get("substitutions") if isinstance(en_node, dict) else None
    pt_subs = pt_node.get("substitutions") if isinstance(pt_node, dict) else None
    en_sigs: dict[tuple[tuple[str, str], ...], tuple[tuple[int, str], ...]] = {}
    for path, text in en_leaves.items():
        sig = format_signature(text, en_subs)
        if sig is None:
            return [f"[{table}] {key!r}: malformed en format specifiers in {text!r}"]
        en_sigs[path] = sig
    problems: list[str] = []
    for path, text in pt_leaves.items():
        sig = format_signature(text, pt_subs)
        if sig is None:
            problems.append(f"[{table}] {key!r}: malformed pt-BR format specifiers in {text!r}")
            continue
        other_path = tuple((kind, "other") if kind == "plural" else (kind, case) for kind, case in path)
        expected_other = en_sigs.get(other_path, en_sigs.get(()))
        expected_case = en_sigs.get(path, expected_other)
        if expected_case is None:
            expected_case = next(iter(en_sigs.values()), ())
        if is_singular_plural_path(path):
            allowed = {expected_case}
            if expected_other is not None:
                allowed.add(expected_other)
                if is_single_integer_signature(expected_other):
                    allowed.add(())
            elif is_single_integer_signature(expected_case):
                allowed.add(())
            if sig not in allowed:
                problems.append(
                    f"[{table}] {key!r}: format specifier mismatch in {path} "
                    f"(expected {sorted(allowed)}, pt-BR has {sig} in {text!r})"
                )
        elif sig != expected_case:
            problems.append(
                f"[{table}] {key!r}: format specifier mismatch in {path} "
                f"(expected {expected_case}, pt-BR has {sig} in {text!r})"
            )
    return problems


def check_catalogs(paths: list[pathlib.Path]) -> tuple[int, list[str]]:
    checked = 0
    problems: list[str] = []
    for path in paths:
        table = path.stem
        strings = json.loads(path.read_text()).get("strings", {})
        for key, item in strings.items():
            if item.get("shouldTranslate") is False:
                continue
            checked += 1
            problems.extend(format_parity_problems(table, key, item))
    return checked, problems


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--catalogs":
        paths = [pathlib.Path(p) for p in argv[2:]] or sorted((ROOT / "RecortiaApp/Resources").glob("*.xcstrings"))
        if not paths:
            print("localization: no .xcstrings catalogs found", file=sys.stderr)
            return 1
        checked, problems = check_catalogs(paths)
        if problems:
            print("localization: format specifier parity failed:", file=sys.stderr)
            print("\n".join(sorted(set(problems))), file=sys.stderr)
            return 1
        print(f"localization: {checked} catalog entries pass format specifier parity")
        return 0

    if len(argv) < 2:
        print("Usage: scripts/check-localization.py <derived-data-dir> [target] [configuration]", file=sys.stderr)
        return 2

    derived = pathlib.Path(argv[1])
    target = argv[2] if len(argv) > 2 else "Recortia"
    configuration = argv[3] if len(argv) > 3 else "Debug"
    data = sorted(derived.glob(f"Build/Intermediates.noindex/Recortia.build/{configuration}/{target}.build/Objects-normal/*/*.stringsdata"))
    if not data:
        print(f"localization: no .stringsdata for {target} ({configuration}) under {derived}; build the app first", file=sys.stderr)
        return 1

    catalogs: dict[str, dict] = {}
    missing: list[str] = []
    mismatched: list[str] = []
    checked = 0
    for path in data:
        record = json.loads(path.read_text())
        for table, entries in record.get("tables", {}).items():
            if table not in catalogs:
                file = ROOT / "RecortiaApp" / "Resources" / f"{table}.xcstrings"
                if not file.exists():
                    print(f"localization: {record['source']} uses table {table}, which has no catalog", file=sys.stderr)
                    return 1
                catalogs[table] = json.loads(file.read_text())["strings"]
            for entry in entries:
                key, checked = entry["key"], checked + 1
                item = catalogs[table].get(key)
                if item is not None and item.get("shouldTranslate") is False:
                    continue
                pt = (item or {}).get("localizations", {}).get("pt-BR", {})
                if not translated(pt):
                    line = entry.get("location", {}).get("startingLine", "?")
                    missing.append(f"{pathlib.Path(record['source']).relative_to(ROOT)}:{line}: [{table}] {key!r}")
                elif item is not None:
                    mismatched.extend(format_parity_problems(table, key, item))

    if missing:
        print("localization: strings without a translated pt-BR entry:", file=sys.stderr)
        print("\n".join(sorted(set(missing))), file=sys.stderr)
    if mismatched:
        print("localization: format specifier parity failed:", file=sys.stderr)
        print("\n".join(sorted(set(mismatched))), file=sys.stderr)
    if missing or mismatched:
        return 1
    print(f"localization: {checked} extracted strings all have pt-BR translations and matching format specifiers")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
