#!/bin/zsh
# Fails when the E2E scenario runner or the synthetic fixture generators are in a binary.
# Scans every Mach-O file in an app bundle: a Debug-style build moves the code into a sibling
# `<name>.debug.dylib`, so the main executable alone is not enough. A single file is scanned as is.
# Usage: scripts/check-release-binary.sh <path-to-.app-or-executable>
set -euo pipefail

if (( $# != 1 )) || [[ ! -e "$1" ]]; then
  echo "usage: check-release-binary.sh <path-to-.app-or-executable>" >&2
  exit 2
fi

# True when the file starts with a Mach-O or universal (fat) magic number.
is_mach_o() {
  case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
    feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

files=()
if [[ -d "$1" ]]; then
  while IFS= read -r -d '' file; do
    is_mach_o "$file" && files+=("$file")
  done < <(find "$1" -type f -print0)
  if (( ${#files} == 0 )); then
    echo "release: no Mach-O files found in $1; refusing to pass without scanning anything" >&2
    exit 1
  fi
else
  files=("$1")
fi

for file in "${files[@]}"; do
  # grep -a reads the raw bytes, so a file that `strings` cannot parse as Mach-O is still scanned.
  for marker in RecortiaE2E RecortiaFixtures ChartFixture TextCorpus; do
    if grep -aqF -- "$marker" "$file"; then
      echo "release: test-only code ($marker) is present in $file" >&2
      exit 1
    fi
  done
done
echo "release: no test-only markers in $1 (${#files} Mach-O file(s) scanned)"
