#!/bin/zsh
# End-to-end scenario run (RecortiaApp/E2E): builds Debug, runs the app binary with
# `-RecortiaE2E <dir>` per language, and prints each report. Synthetic inputs only: no screen
# capture, TCC prompt, general clipboard, or user settings are touched.
# Usage: scripts/e2e.sh [--lang en|pt-BR|all] [--only id,id] [--unsigned] [--no-build]
# Output: .scratch/e2e/<timestamp>/<lang>/{report.json,report.md,NN-*.png}
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

derived=.build/dd
app="$derived/Build/Products/Debug/RecortiaE2E.app/Contents/MacOS/RecortiaE2E"
mkdir -p .build
if (( build )); then
  echo "== build Debug"
  if ! xcodebuild -project Recortia.xcodeproj -scheme RecortiaE2E -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived" "${sign_args[@]}" build >"$derived-e2e-build.log" 2>&1; then
    tail -30 "$derived-e2e-build.log" >&2
    echo "e2e: build failed (full log: $derived-e2e-build.log)" >&2
    exit 2
  fi
fi
[[ -x "$app" ]] || { echo "e2e: $app not found; build first" >&2; exit 2; }

run_root="$PWD/.scratch/e2e/$(date +%Y%m%d-%H%M%S)"
rc=0
for language in $languages; do
  out="$run_root/$language"
  mkdir -p "$out"
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
