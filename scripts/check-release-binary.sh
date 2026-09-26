#!/bin/zsh
# Fails when the DEBUG-only E2E scenario runner (its launch-argument literal) is in a binary.
# Usage: scripts/check-release-binary.sh <path-to-executable>
set -euo pipefail
symbols=$(strings -a "$1")
for marker in RecortiaE2E; do
  if [[ "$symbols" == *"$marker"* ]]; then
    echo "release: DEBUG-only code ($marker) is present in $1" >&2
    exit 1
  fi
done
echo "release: no DEBUG-only markers in $1"
