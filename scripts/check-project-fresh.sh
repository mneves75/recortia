#!/bin/zsh
# Fails unless every file XcodeGen owns equals what the pinned XcodeGen generates from the worktree:
# the project (except SwiftPM's Package.resolved) and each target's info and entitlements plist,
# as `xcodegen dump` resolves them. Generation runs in a temporary copy of the inputs (every
# tracked or untracked, non-ignored file) whose outputs are removed first, so nothing from the
# worktree seeds the generated side and nothing is written into the worktree. A git-ignored file
# under a source path fails the gate: XcodeGen would discover it, the copy would not.
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
tree="$scratch/tree"
mkdir "$tree"

listing=$(git ls-files -z --cached --others --exclude-standard)
inputs=()
typeset -A checked_parents
for file in "${(@0)listing}"; do
  # A tracked file deleted in the worktree is not an input.
  [[ -n "$file" ]] && [[ -e "$file" || -L "$file" ]] || continue
  parent="${file:h}"
  while [[ "$parent" != . && -z "${checked_parents[$parent]:-}" ]]; do
    if [[ -L "$parent" ]]; then
      echo "check: $parent is a symbolic link; the gate copies no input through it" >&2
      exit 1
    fi
    checked_parents[$parent]=1
    parent="${parent:h}"
  done
  inputs+=("$file")
done
if (( ${#inputs} )); then
  print -rN -- "${inputs[@]}" | tar -cf - --null -T - | tar -xf - -C "$tree"
fi

if ! (cd "$tree" && "$root/scripts/xcodegen.sh" dump --quiet --type parsed-json --file "$scratch/spec.json"); then
  echo "check: XcodeGen cannot resolve project.yml, so the generated-project freshness gate cannot run" >&2
  exit 1
fi

# Read the generator's outputs and source roots, refuse inputs the copy cannot reproduce, and
# empty the outputs in the copy.
python3 - "$tree" "$scratch/spec.json" "$scratch/outputs.json" <<'PY'
import json, os, pathlib, shutil, subprocess, sys
tree, spec_path, plan_path = map(pathlib.Path, sys.argv[1:])
spec = json.loads(spec_path.read_text())
targets = spec.get("targets") or {}
project = f"{spec['name']}.xcodeproj"
plists = sorted({
    target[key]["path"] for target in targets.values() for key in ("info", "entitlements")
    if isinstance(target.get(key), dict) and target[key].get("path")
})
sources = sorted({source["path"] for target in targets.values() for source in target.get("sources") or []})

if sources:
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", *sources],
        check=True, capture_output=True,
    ).stdout.decode()
    ignored = [path for path in listed.split("\0") if path and os.path.basename(path) != ".DS_Store"]
    if ignored:
        print("check: these git-ignored files sit under a project.yml source path; XcodeGen would "
              "discover them but the freshness copy omits them. Remove them or stop ignoring them:",
              *ignored, sep="\n  ", file=sys.stderr)
        sys.exit(1)

for relative in [project, *plists]:
    parts = pathlib.PurePosixPath(relative).parts
    if pathlib.PurePosixPath(relative).is_absolute() or ".." in parts:
        sys.exit(f"check: generator output {relative} lies outside the project root")
    for depth in range(1, len(parts)):
        if (tree / pathlib.PurePosixPath(*parts[:depth])).is_symlink():
            sys.exit(f"check: {pathlib.PurePosixPath(*parts[:depth])} is a symbolic link; the gate does not generate through it")
    output = tree / relative
    if output.is_symlink() or output.is_file():
        output.unlink()
    elif output.is_dir():
        shutil.rmtree(output)
plan_path.write_text(json.dumps({"project": project, "plists": plists}))
PY

if ! (cd "$tree" && "$root/scripts/xcodegen.sh" generate --quiet); then
  echo "check: XcodeGen failed, so the generated-project freshness gate cannot run" >&2
  exit 1
fi

python3 - "$tree" "$scratch/outputs.json" <<'PY'
import json, os, pathlib, subprocess, sys
tree, plan_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
plan = json.loads(plan_path.read_text())
project, plists = plan["project"], plan["plists"]
swiftpm_owned = f"{project}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

generated = set(plists)
for directory, _, files in os.walk(tree / project):
    for name in files:
        generated.add((pathlib.Path(directory) / name).relative_to(tree).as_posix())
listed = subprocess.run(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", project],
    check=True, capture_output=True,
).stdout.decode()
current = {path for path in listed.split("\0") if path and os.path.lexists(path)} - {swiftpm_owned}
current |= {path for path in plists if os.path.lexists(path)}

problems = []
for path in sorted(generated | current):
    if path not in current:
        problems.append(f"missing from the worktree: {path}")
    elif path not in generated or not (tree / path).is_file():
        problems.append(f"not generated: {path}")
    elif pathlib.Path(path).read_bytes() != (tree / path).read_bytes():
        problems.append(f"differs: {path}")
if problems:
    print("check: files XcodeGen owns differ from what project.yml generates (stale or edited by "
          "hand); run scripts/xcodegen.sh generate and commit the results:",
          *problems, sep="\n  ", file=sys.stderr)
    sys.exit(1)
print(f"check: {project} and {', '.join(plists) or 'no plists'} match project.yml")
PY
