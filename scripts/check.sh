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

scripts/doctor.sh

echo "== toolchain and E2E isolation regressions"
python3 scripts/test-doctor.py
python3 scripts/test-e2e-isolation.py
python3 scripts/test-localization.py
python3 scripts/test-release-entitlements.py
python3 scripts/test-release-binary.py
python3 scripts/test-project-freshness.py

echo "== format lint"
xcrun swift format lint --strict --recursive --parallel Packages/RecortiaKit/Sources Packages/RecortiaKit/Tests RecortiaApp RecortiaUITests

echo "== generated project is current (compared with git)"
scripts/check-project-fresh.sh

echo "== package tests"
swift test --package-path Packages/RecortiaKit --parallel

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

echo "check: all gates passed"
