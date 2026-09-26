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

echo "== format lint"
xcrun swift format lint --strict --recursive --parallel Packages/RecortiaKit/Sources Packages/RecortiaKit/Tests RecortiaApp RecortiaUITests

if command -v xcodegen >/dev/null; then
  echo "== generated project is current"
  before=$(find Recortia.xcodeproj -name '*.pbxproj' -o -name '*.xcscheme' | sort | xargs shasum | shasum)
  xcodegen generate --quiet
  after=$(find Recortia.xcodeproj -name '*.pbxproj' -o -name '*.xcscheme' | sort | xargs shasum | shasum)
  if [[ "$before" != "$after" ]]; then
    echo "check: Recortia.xcodeproj was stale; it has been regenerated from project.yml, commit the result" >&2
    exit 1
  fi
elif [[ -n "${CI:-}" ]]; then
  echo "check: xcodegen is missing, so the generated-project freshness gate cannot run in CI" >&2
  exit 1
fi

echo "== package tests"
swift test --package-path Packages/RecortiaKit --parallel

echo "== app build"
xcodebuild -project Recortia.xcodeproj -scheme Recortia -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/dd -onlyUsePackageVersionsFromResolvedFile \
  "${sign_args[@]}" build | tail -3

echo "check: all gates passed"
