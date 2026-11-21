#!/bin/zsh
# Fails when test-only code is in a binary. One scan for both Release bundles: every Mach-O file
# anywhere in the bundle (Contents/MacOS, Frameworks, PlugIns, Resources), because a Debug-style
# build moves code into a sibling `<name>.debug.dylib`; a single file is scanned as is.
#   default   the shipping app: no E2E runner and no synthetic fixture generators
#   --runner  the Release RecortiaE2E product, which links the fixture generators on purpose: no
#             runner, whose primary launch argument and type exist only under RECORTIA_E2E
# Fails closed: a file it cannot read, or a missing or non-Mach-O executable at
# Contents/MacOS/<bundle name>, is a failure, never a clean scan.
# Usage: scripts/check-release-binary.sh [--runner] <path-to-.app-or-executable>
set -euo pipefail

markers=(RecortiaE2E RecortiaFixtures ChartFixture TextCorpus)
if [[ "${1:-}" == "--runner" ]]; then
  markers=(-RecortiaE2E E2ERunner)
  shift
fi
if (( $# != 1 )) || [[ ! -e "$1" ]]; then
  echo "usage: check-release-binary.sh [--runner] <path-to-.app-or-executable>" >&2
  exit 2
fi

# True for a Mach-O or universal (fat or fat64) magic number; an unreadable file stops the scan.
is_mach_o() {
  local magic
  if [[ ! -r "$1" ]] || ! magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n'); then
    echo "release: could not read $1; refusing to pass without scanning it" >&2
    exit 1
  fi
  case "$magic" in
    feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -d "$1" ]]; then
  executable="$1/Contents/MacOS/${${1:t}%.app}"
  if [[ ! -f "$executable" || -L "$executable" ]] || ! is_mach_o "$executable"; then
    echo "release: expected a Mach-O executable at $executable" >&2
    exit 1
  fi
  listing=$(find "$1" -type f -print0)  # a find error stops the script (set -e)
  files=()
  for file in ${(0)listing}; do
    if is_mach_o "$file"; then files+=("$file"); fi
  done
else
  if ! is_mach_o "$1"; then
    echo "release: $1 is not a Mach-O file" >&2
    exit 1
  fi
  files=("$1")
fi

for file in "${files[@]}"; do
  for marker in "${markers[@]}"; do
    # grep -a reads the raw bytes, so a file that `strings` cannot parse is still scanned.
    # Exit 1 is "absent"; anything else is a read error, not a clean result.
    if grep -aqF -- "$marker" "$file"; then
      echo "release: test-only code ($marker) is present in $file" >&2
      exit 1
    elif (( $? != 1 )); then
      echo "release: could not read $file; refusing to pass without scanning it" >&2
      exit 1
    fi
  done
done
echo "release: no test-only markers in $1 (${#files} Mach-O file(s) scanned)"
