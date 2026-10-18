#!/bin/zsh
# End-to-end scenario run (RecortiaApp/E2E): builds Debug, runs the app binary with
# `-RecortiaE2E <dir>` per language, and prints each report. Synthetic inputs only: no screen
# capture, TCC prompt, general clipboard, or user settings are touched.
# Usage: scripts/e2e.sh [--lang en|pt-BR|all] [--only id,id] [--unsigned] [--no-build]
# Output: .scratch/e2e/<timestamp>-<pid>/<lang>/{report.json,report.md,provenance.json,NN-*.png}
# Exit: 0 when every scenario passed in every language; 1 on a failed scenario, crash, missing
# report, or timeout; 2 on bad arguments or a failed build.
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

lang=all
only=""
build=1
sign_args=()
timeout_seconds=${E2E_TIMEOUT:-300}
while (( $# > 0 )); do
  case "$1" in
    --lang) lang="${2:-}"; shift 2 ;;
    --only) only="${2:-}"; shift 2 ;;
    --unsigned) sign_args=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=-); shift ;;
    --no-build) build=0; shift ;;
    *) echo "e2e: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$lang" in
  en) languages=(en) ;;
  pt-BR) languages=(pt-BR) ;;
  all) languages=(en pt-BR) ;;
  *) echo "e2e: --lang must be en, pt-BR, or all" >&2; exit 2 ;;
esac

scripts/doctor.sh
toolchain_mode="${RECORTIA_TOOLCHAIN_MODE:-stable}"
xcode_version=$(xcodebuild -version)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
sdk_build_version=$(xcrun --sdk macosx --show-sdk-build-version)
derived=.build/dd
provenance="$derived-e2e-provenance.json"
# Compare the source and the doctor-approved compiler, including its selected installation.
source_provenance() {
python3 - "$(git rev-parse HEAD)" "$toolchain_mode" "$DEVELOPER_DIR" "$xcode_version" "$sdk_version" "$sdk_build_version" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
record = dict(zip(("git_sha", "toolchain_mode", "developer_dir", "xcode_version", "sdk_version", "sdk_build_version"), sys.argv[1:]))
fingerprint = hashlib.sha256()
for arguments in (("status", "--porcelain=v1", "--untracked-files=all"), ("diff", "HEAD", "--binary")):
    fingerprint.update(subprocess.check_output(["git", *arguments]))
    fingerprint.update(b"\0")
# Git's NUL-separated names preserve spaces, newlines and non-UTF-8 path bytes.
# Hash symlink text rather than following links outside the working tree.
untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"])
for name in sorted(filter(None, untracked.split(b"\0"))):
    fingerprint.update(b"untracked\0" + len(name).to_bytes(8, "big") + name)
    path = pathlib.Path(os.fsdecode(name))
    if path.is_symlink():
        target = os.fsencode(os.readlink(path))
        fingerprint.update(b"symlink\0" + len(target).to_bytes(8, "big") + target)
    else:
        fingerprint.update(b"file\0" + path.stat().st_size.to_bytes(8, "big"))
        with path.open("rb") as contents:
            while chunk := contents.read(64 * 1024):
                fingerprint.update(chunk)
record["working_tree_fingerprint"] = fingerprint.hexdigest()
print(json.dumps(record, sort_keys=True))
PY
}
current_provenance=$(source_provenance)
bundle="$derived/Build/Products/Debug/RecortiaE2E.app"
app="$bundle/Contents/MacOS/RecortiaE2E"
mkdir -p .build
if (( build )); then
  # A failed rebuild must not leave a previous build's qualification attached to partial output.
  rm -f "$provenance"
  echo "== build Debug"
  if ! xcodebuild -project Recortia.xcodeproj -scheme RecortiaE2E -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived" "${sign_args[@]}" build >"$derived-e2e-build.log" 2>&1; then
    tail -30 "$derived-e2e-build.log" >&2
    echo "e2e: build failed (full log: $derived-e2e-build.log)" >&2
    exit 2
  fi
  # An edit or commit during the build would bind this evidence to sources it did not compile.
  if [[ "$(source_provenance)" != "$current_provenance" ]]; then
    echo "e2e: the source or toolchain changed during the build; rerun on a quiet working tree" >&2
    exit 2
  fi
fi
[[ -x "$app" ]] || { echo "e2e: $app not found; build first" >&2; exit 2; }
# Bind the qualification to the entire built bundle, even when another script rebuilt it.
if ! current_provenance=$(python3 - "$current_provenance" "$bundle" <<'PY'
import hashlib, json, os, pathlib, sys
record = json.loads(sys.argv[1])
bundle = pathlib.Path(sys.argv[2])
if bundle.is_symlink() or not bundle.is_dir():
    sys.exit("e2e: expected a regular app bundle directory")
def walk_error(error):
    raise error
entries = []
for directory, directories, files in os.walk(bundle, followlinks=False, onerror=walk_error):
    for name in directories + files:
        path = pathlib.Path(directory) / name
        if path.is_symlink() or path.is_file():
            entries.append(path)
fingerprint = hashlib.sha256()
for path in sorted(entries, key=lambda path: os.fsencode(path.relative_to(bundle))):
    name = os.fsencode(path.relative_to(bundle))
    fingerprint.update(len(name).to_bytes(8, "big") + name)
    if path.is_symlink():
        target = os.fsencode(os.readlink(path))
        fingerprint.update(b"symlink\0" + len(target).to_bytes(8, "big") + target)
    else:
        fingerprint.update(b"file\0" + path.stat().st_size.to_bytes(8, "big"))
        with path.open("rb") as contents:
            while chunk := contents.read(64 * 1024):
                fingerprint.update(chunk)
record["app_bundle_sha256"] = fingerprint.hexdigest()
print(json.dumps(record, sort_keys=True))
PY
); then
  echo "e2e: could not fingerprint app bundle for build provenance; rebuild with the selected toolchain" >&2
  exit 2
fi
if (( build )); then
  print -r -- "$current_provenance" > "$provenance"
elif [[ ! -f "$provenance" ]] || [[ "$(cat "$provenance")" != "$current_provenance" ]]; then
  echo "e2e: missing or mismatched build provenance at $provenance; rebuild with the selected toolchain" >&2
  exit 2
fi

run_root="$PWD/.scratch/e2e/$(date +%Y%m%d-%H%M%S)-$$"
rc=0
for language in $languages; do
  out="$run_root/$language"
  mkdir -p "$out"
  cp "$provenance" "$out/provenance.json"
  echo "== run $language → $out"
  args=(-RecortiaE2E "$out" -AppleLanguages "($language)" -AppleLocale "${language/-/_}")
  [[ -n "$only" ]] && args+=(-RecortiaE2EOnly "$only")
  set +e
  "$app" "${args[@]}" 2>"$out/runner.log" &
  pid=$!
  # Watchdog: stop only this run's process if it outlives the timeout.
  ( sleep "$timeout_seconds"; kill -TERM "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid"
  exit_code=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  set -e
  cat "$out/runner.log"
  if [[ ! -f "$out/report.json" ]]; then
    echo "e2e[$language]: no report (exit $exit_code: crash or timeout after ${timeout_seconds}s)" >&2
    rc=1
    continue
  fi
  summary=$(python3 - "$out/report.json" <<'PY'
import json, sys
results = json.load(open(sys.argv[1]))
passed = sum(r["passed"] for r in results)
shots = sum(len(r["screenshots"]) for r in results)
print(f"{passed}/{len(results)} scenarios passed, {shots} screenshots")
for r in results:
    if not r["passed"]:
        bad = [a for a in r["assertions"] if not a["passed"]]
        print(f"  FAIL {r['id']}: " + "; ".join(f"{a['name']} ({a['detail']})" for a in bad[:3]))
sys.exit(0 if results and passed == len(results) else 1)
PY
  ) || rc=1
  echo "e2e[$language]: $summary (exit $exit_code)"
  (( exit_code == 0 )) || rc=1
done
echo "e2e: output in $run_root"
exit $rc
