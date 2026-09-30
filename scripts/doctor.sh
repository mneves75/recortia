#!/bin/zsh
# Verifies the build environment matches TOOLCHAIN.json before any build or test (ADR-001).
# Exit codes: 0 ok, 1 mismatch or missing tool.
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

expected_build=$(python3 -c 'import json;print(json.load(open("TOOLCHAIN.json"))["actual_xcode_build"])')
actual_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
actual_version=$(xcodebuild -version | awk '/^Xcode/ {print $2}')

rc=0
if [[ "$actual_build" != "$expected_build" ]]; then
  echo "doctor: Xcode build $actual_build ($DEVELOPER_DIR) != TOOLCHAIN.json $expected_build" >&2
  echo "doctor: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer (xcode-select may point to a beta)" >&2
  rc=1
else
  echo "doctor: Xcode $actual_version ($actual_build) matches TOOLCHAIN.json"
fi

if ! command -v xcodegen >/dev/null; then
  echo "doctor: xcodegen missing (brew install xcodegen); needed only to regenerate the project" >&2
fi

swift_output=$(xcrun swift --version 2>&1)
swift_line="${swift_output%%$'\n'*}"
echo "doctor: $swift_line"
exit $rc
