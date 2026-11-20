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

expected_ran="tests-report: ran $(python3 scripts/tests-report.py --count) gate tests"
if [[ "$tests_ran" != "$expected_ran" ]]; then
  echo "check: the gate test list did not run in this gate (expected '$expected_ran')" >&2
  exit 1
fi
echo "check: end $(run_identity)"
echo "check: all gates passed"
