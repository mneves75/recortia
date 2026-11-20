#!/bin/zsh
# Release-configuration gate for hosted CI (REL-01): qualifies the toolchain, builds the shipping app
# and the E2E scheme unsigned in Release, scans the shipping bundle for test-only code, and requires
# that the E2E runner and its foreground helper compiled to nothing (both are Debug-only).
# Usage: scripts/check-release-build.sh   (run from a clean derived-data directory in CI)
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

# The same qualification release.sh requires: never build Release with an unreviewed Xcode.
scripts/doctor.sh --release

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

# The Release E2E product links the fixture generators on purpose, so it is scanned only for the
# runner's own launch arguments and type, which exist only under RECORTIA_E2E.
e2e=$products/RecortiaE2E.app
if [[ ! -f "$e2e/Contents/MacOS/RecortiaE2E" ]]; then
  echo "release: $e2e has no executable; refusing to pass without scanning it" >&2
  exit 1
fi
for marker in -RecortiaE2EOnly -RecortiaE2EProbe -RecortiaE2ELastWindowProbe E2ERunner; do
  if grep -raqF -- "$marker" "$e2e/Contents/MacOS"; then
    echo "release: E2E runner code ($marker) is in the Release E2E product $e2e" >&2
    exit 1
  fi
done

helper=$products/RecortiaE2EForegroundHost.app
if [[ -e "$helper/Contents/MacOS" ]]; then
  echo "release: the E2E foreground helper has an executable in Release: $helper/Contents/MacOS" >&2
  exit 1
fi
echo "release: Release build gate passed"
