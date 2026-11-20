#!/bin/zsh
# Release-configuration gate for hosted CI (REL-01): builds the shipping app and the E2E scheme
# unsigned in Release, scans the shipping bundle for test-only code, and requires that the E2E
# foreground helper compiled to nothing (it is Debug-only, like the runner).
# Usage: scripts/check-release-build.sh   (run from a clean derived-data directory in CI)
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

derived=.build/dd-release
products=$derived/Build/Products/Release
for scheme in Recortia RecortiaE2E; do
  echo "== Release build of $scheme (unsigned)"
  xcodebuild -project Recortia.xcodeproj -scheme "$scheme" -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- build | tail -3
done

echo "== test-only code in the Release app"
scripts/check-release-binary.sh "$products/Recortia.app"

helper=$products/RecortiaE2EForegroundHost.app
if [[ -e "$helper/Contents/MacOS" ]]; then
  echo "release: the E2E foreground helper has an executable in Release: $helper/Contents/MacOS" >&2
  exit 1
fi
echo "release: Release build gate passed"
