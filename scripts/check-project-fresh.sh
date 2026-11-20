#!/bin/zsh
# Fails unless the worktree's Recortia.xcodeproj equals what the pinned XcodeGen generates from the
# worktree's inputs. Generation runs in a temporary copy (every tracked or untracked, non-ignored
# file, plus the current project), never in the worktree: generating in place overwrote unstaged
# project edits and then passed. Reports each differing path.
# Usage: scripts/check-project-fresh.sh
set -euo pipefail
cd "${0:A:h}/.."
root=$PWD

if [[ ! -x scripts/xcodegen.sh ]]; then
  echo "check: scripts/xcodegen.sh is missing, so the required generated-project freshness gate cannot run" >&2
  exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/recortia-project-fresh.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
copy="$scratch/tree"
mkdir "$copy"

listing=$(git ls-files -z --cached --others --exclude-standard)
inputs=()
for file in "${(@0)listing}"; do
  [[ -n "$file" && "$file" != Recortia.xcodeproj/* ]] || continue
  # A tracked file deleted in the worktree is not an input.
  [[ -e "$file" || -L "$file" ]] && inputs+=("$file")
done
if (( ${#inputs} )); then
  print -rN -- "${inputs[@]}" | tar -cf - --null -T - | tar -xf - -C "$copy"
fi
[[ -d Recortia.xcodeproj ]] && cp -Rp Recortia.xcodeproj "$copy/"

if ! (cd "$copy" && "$root/scripts/xcodegen.sh" generate --quiet); then
  echo "check: XcodeGen failed, so the generated-project freshness gate cannot run" >&2
  exit 1
fi

drift_status=0
drift=$(diff -rq Recortia.xcodeproj "$copy/Recortia.xcodeproj" 2>&1) || drift_status=$?
if (( drift_status != 0 )); then
  echo "check: Recortia.xcodeproj differs from what project.yml generates (stale or edited by hand); run scripts/xcodegen.sh generate and commit the project:" >&2
  echo "${drift//$copy\//generated/}" >&2
  exit 1
fi
echo "check: Recortia.xcodeproj matches project.yml"
