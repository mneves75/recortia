#!/bin/zsh
# Fails when the E2E scenario runner or the synthetic fixture generators are in a binary.
# Usage: scripts/check-release-binary.sh <path-to-executable>
set -euo pipefail
symbols=$(strings -a "$1")
for marker in RecortiaE2E RecortiaFixtures ChartFixture TextCorpus; do
  if [[ "$symbols" == *"$marker"* ]]; then
    echo "release: test-only code ($marker) is present in $1" >&2
    exit 1
  fi
done
echo "release: no test-only markers in $1"
