#!/bin/zsh
# Fails unless the committed Recortia.xcodeproj equals what XcodeGen generates from project.yml.
# It compares against git, not against the tree before generation: a stale project is rewritten in
# place by the first run, and a before/after hash would then pass on the second run while the fix
# was still uncommitted. Uncommitted regeneration, including new files, therefore keeps failing.
# Usage: scripts/check-project-fresh.sh
set -euo pipefail
cd "${0:A:h}/.."

if ! command -v xcodegen >/dev/null; then
  if [[ -n "${CI:-}" ]]; then
    echo "check: xcodegen is missing, so the generated-project freshness gate cannot run in CI" >&2
    exit 1
  fi
  echo "check: xcodegen is missing; skipping the generated-project freshness gate"
  exit 0
fi

xcodegen generate --quiet
drift=$(git status --porcelain --untracked-files=all -- Recortia.xcodeproj)
if [[ -n "$drift" ]]; then
  echo "check: Recortia.xcodeproj differs from what project.yml generates (stale or uncommitted); commit the regenerated project:" >&2
  echo "$drift" >&2
  exit 1
fi
echo "check: Recortia.xcodeproj matches project.yml"
