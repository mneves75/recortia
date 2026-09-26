#!/bin/zsh
# Builds, signs, notarizes, and staples the Developer ID disk image, and writes a manifest that
# ties it to its source. Owner-only: needs the Developer ID identity and an `asc` notary profile.
# Usage: scripts/release.sh [--skip-notarize]
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

notarize=1
[[ "${1:-}" == "--skip-notarize" ]] && notarize=0

if [[ -n "$(git status --porcelain)" ]]; then
  echo "release: the working tree is dirty; release only a committed state" >&2
  exit 1
fi

version=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p' project.yml)
out=.build/release/$version
rm -rf "$out"
mkdir -p "$out"

echo "== archive $version ($build)"
xcodebuild -project Recortia.xcodeproj -scheme Recortia -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/Recortia.xcarchive" \
  -onlyUsePackageVersionsFromResolvedFile archive | tail -2

cat > "$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>Q96FUTC5G8</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Recortia.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" | tail -1
app="$out/export/Recortia.app"

echo "== verify the app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'get-task-allow' &&
  { echo "release: get-task-allow is present; this is not a distribution build" >&2; exit 1; }
codesign -dvv "$app" 2>&1 | grep -q 'flags=0x10000(runtime)' ||
  { echo "release: Hardened Runtime is not enabled" >&2; exit 1; }
# The DEBUG-only E2E scenario runner and previews must be compiled out.
if strings -a "$app/Contents/MacOS/Recortia" | grep -Eq 'RecortiaE2E|PreviewPreferenceIntegrity'; then
  echo "release: DEBUG-only code is present in the Release binary" >&2
  exit 1
fi

echo "== disk image"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Recortia.app"
ln -s /Applications "$staging/Applications"
dmg="$out/Recortia-$version.dmg"
hdiutil create -volname "Recortia $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --sign "Developer ID Application: Marcus Neves (Q96FUTC5G8)" --timestamp "$dmg"

if (( notarize )); then
  echo "== notarize"
  asc notarization submit --file "$dmg" --wait --timeout 1h --output table
  asc notarization staple --file "$dmg" --confirm --output table
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
{
  echo "version: $version ($build)"
  echo "commit: $(git rev-parse HEAD)"
  echo "package_resolved_sha256: $(shasum -a 256 Recortia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved | cut -d' ' -f1)"
  echo "toolchain: $(xcodebuild -version | tr '\n' ' ')"
  echo "notarized: $(( notarize ))"
  echo "dmg: $(basename "$dmg")"
  echo "sha256: $sha"
} > "$out/manifest.txt"
cat "$out/manifest.txt"
