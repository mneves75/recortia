#!/bin/zsh
# The repository gate: toolchain, formatting, generated project freshness, package tests, app build.
# Usage: scripts/check.sh [--unsigned]   (--unsigned for CI and machines without the signing identity)
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

sign_args=()
if [[ "${1:-}" == "--unsigned" ]]; then
  sign_args=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=-)
fi

source scripts/lib/run-identity.sh
echo "check: $(run_identity)"
scripts/doctor.sh

echo "== script regressions (the list is GATES in scripts/tests-report.py)"
# Keeps the dispatcher's completion line; the end of this script refuses to pass without it.
tests_ran=""
python3 scripts/tests-report.py --run-tests | while IFS= read -r line; do
  print -r -- "$line"
  if [[ $line == "tests-report: ran "* ]]; then tests_ran=$line; fi
done

echo "== deployment target agrees everywhere (ADR-008)"
python3 scripts/check-deployment-target.py

echo "== gate inventory"
python3 scripts/tests-report.py --check

echo "== format lint"
xcrun swift format lint --strict --recursive --parallel Packages/RecortiaKit/Sources Packages/RecortiaKit/Tests RecortiaApp RecortiaUITests

echo "== generated project is current (compared with git)"
scripts/check-project-fresh.sh

echo "== package tests"
xcrun swift test --package-path Packages/RecortiaKit --parallel

echo "== app build"
xcodebuild -project Recortia.xcodeproj -scheme Recortia -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/dd -onlyUsePackageVersionsFromResolvedFile \
  "${sign_args[@]}" build | tail -3

echo "== pt-BR covers every extracted string"
scripts/check-localization.py .build/dd Recortia

echo "== E2E target build (the runner must keep compiling)"
xcodebuild -project Recortia.xcodeproj -scheme RecortiaE2E -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/dd -onlyUsePackageVersionsFromResolvedFile \
  "${sign_args[@]}" build | tail -3

echo "== E2E binary refuses missing or malformed launch requests"
# A binary that failed to refuse would start the real runner, which drives the foreground; hold the
# shared E2E lock (in the primary checkout) so it can never run beside another E2E run.
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir="$PWD/.git"
e2e_lock="${common_dir:h}/.scratch/e2e.lock"
mkdir -p "${e2e_lock:h}"
until mkdir "$e2e_lock" 2>/dev/null; do
  echo "check: waiting for $e2e_lock"
  sleep 15
done
trap 'rmdir "$e2e_lock" 2>/dev/null' EXIT
RECORTIA_E2E_BINARY="$PWD/.build/dd/Build/Products/Debug/RecortiaE2E.app/Contents/MacOS/RecortiaE2E" \
  python3 scripts/test-e2e-isolation.py E2ELaunchGuardTests.test_built_binary_refuses_missing_or_malformed_requests
rmdir "$e2e_lock"
trap - EXIT

expected_ran="tests-report: ran $(python3 scripts/tests-report.py --count) gate tests"
if [[ "$tests_ran" != "$expected_ran" ]]; then
  echo "check: the gate test list did not run in this gate (expected '$expected_ran')" >&2
  exit 1
fi
echo "check: end $(run_identity)"
echo "check: all gates passed"
