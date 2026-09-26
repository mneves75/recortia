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
xcrun swift format lint --strict --recursive --parallel Packages/FramepinKit/Sources Packages/FramepinKit/Tests FramepinApp FramepinUITests

if command -v xcodegen >/dev/null; then
  echo "== generated project is current"
  xcodegen generate --quiet
  git diff --exit-code -- Framepin.xcodeproj
fi

echo "== package tests"
swift test --package-path Packages/FramepinKit --parallel

echo "== app build"
xcodebuild -project Framepin.xcodeproj -scheme Framepin -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/dd "${sign_args[@]}" build | tail -3

echo "check: all gates passed"
