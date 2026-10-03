#!/bin/zsh
# Builds the Developer ID app, notarizes and staples it, then builds, signs, notarizes, and staples
# the disk image from that app, from a reviewed tag, and writes a manifest that ties it to its source, gate result, toolchain, and dependencies (SPEC.md §12).
# Owner-only: needs the Developer ID identity, the "Recortia Developer ID" provisioning profile, and
# an `asc` notary profile.
# Usage: scripts/release.sh            release the tag at HEAD (v<MARKETING_VERSION>[-betaN])
#        scripts/release.sh --dry-run  untagged local build: no gate, no notarization
set -euo pipefail
cd "${0:A:h}/.."
root=$PWD

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

if [[ -n "$(git status --porcelain)" ]]; then
  echo "release: the working tree is dirty; release only a committed state" >&2
  exit 1
fi

source_commit=$(git rev-parse HEAD)
version=$(git show "${source_commit}:project.yml" | sed -n 's/^ *MARKETING_VERSION: *//p')
build=$(git show "${source_commit}:project.yml" | sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p')
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || ! "$build" =~ '^[0-9]+$' ]]; then
  echo "release: unexpected version '$version' or build '$build' in project.yml" >&2
  exit 1
fi

tag=$(git describe --exact-match --tags "$source_commit" 2>/dev/null || true)
if (( ! dry_run )); then
  if [[ ! "$tag" =~ "^v${version//./\\.}(-beta[0-9]+)?$" ]]; then
    echo "release: HEAD must carry a reviewed tag v$version or v$version-betaN (found '${tag:-none}')" >&2
    exit 1
  fi
  label=${tag#v}
else
  label="$version-dev"
fi

out=$root/.build/release/$label
rm -rf "$out"
git worktree prune
mkdir -p "$out"

# Build from a fresh checkout of the selected commit with its own derived data and package checkouts, so nothing
# ignored or cached in the working tree can reach the signed binary.
src=$out/src
git worktree add --quiet --detach "$src" "$source_commit"
trap 'git -C "$root" worktree remove --force "$src" 2>/dev/null || true' EXIT

gate="skipped (dry run)"
if (( ! dry_run )); then
  echo "== gate"
  (cd "$src" && scripts/check.sh) > "$out/gate.log" 2>&1 ||
    { tail -20 "$out/gate.log" >&2; echo "release: the gate failed; see $out/gate.log" >&2; exit 1; }
  gate="passed (scripts/check.sh, log in gate.log)"
fi

echo "== archive $version ($build)"
xcodebuild -project "$src/Recortia.xcodeproj" -scheme Recortia -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/Recortia.xcarchive" \
  -derivedDataPath "$out/dd" -clonedSourcePackagesDirPath "$out/spm" \
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
  <key>provisioningProfiles</key>
  <dict><key>dev.mvneves.Recortia</key><string>Recortia Developer ID</string></dict>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Recortia.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" | tail -1
app="$out/export/Recortia.app"

echo "== verify the app"
codesign --verify --deep --strict --verbose=2 "$app"
built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
built_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
if [[ "$built_version" != "$version" || "$built_build" != "$build" ]]; then
  echo "release: built $built_version ($built_build) does not match project.yml $version ($build)" >&2
  exit 1
fi
# Parse the entitlement key itself; another matching string does not grant Keychain access.
entitlements="$out/entitlements.plist"
codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
python3 "$src/scripts/check-release-entitlements.py" "$entitlements" \
  --access-group Q96FUTC5G8.dev.mvneves.Recortia
if [[ ! -f "$app/Contents/embedded.provisionprofile" ]]; then
  echo "release: the provisioning profile is missing" >&2
  exit 1
fi
signature=$(codesign -dvv "$app" 2>&1)
if [[ "$signature" != *"flags=0x10000(runtime)"* ]]; then
  echo "release: Hardened Runtime is not enabled" >&2
  exit 1
fi
scripts/check-release-binary.sh "$app"
notice="$src/RecortiaApp/Resources/KeyboardShortcuts-LICENSE.txt"
upstream_notice="$out/spm/checkouts/KeyboardShortcuts/license"
bundled_notice="$app/Contents/Resources/KeyboardShortcuts-LICENSE.txt"
if ! cmp -s "$notice" "$upstream_notice" || ! cmp -s "$notice" "$bundled_notice"; then
  echo "release: the bundled KeyboardShortcuts notice is missing or differs from the pinned package license" >&2
  exit 1
fi
if ! cmp -s "$src/LICENSE" "$app/Contents/Resources/Recortia-LICENSE.txt"; then
  echo "release: the bundled Recortia license is missing or differs from the reviewed source" >&2
  exit 1
fi

# Notarize and staple the app itself before it goes into the image, so a copy dragged out of the DMG
# still passes Gatekeeper offline. The DMG is notarized and stapled again below.
if (( ! dry_run )); then
  echo "== notarize the app"
  app_zip="$out/Recortia-$label-app.zip"
  ditto -c -k --keepParent "$app" "$app_zip"
  asc notarization submit --file "$app_zip" --wait --timeout 1h --output table
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  # Stapling adds a ticket to the bundle; the signature seal and Gatekeeper assessment must still hold.
  codesign --verify --deep --strict "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

echo "== disk image"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Recortia.app"
ln -s /Applications "$staging/Applications"
dmg="$out/Recortia-$label.dmg"
hdiutil create -volname "Recortia $label" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --sign "Developer ID Application: Marcus Neves (Q96FUTC5G8)" --timestamp "$dmg"

if (( ! dry_run )); then
  echo "== notarize"
  asc notarization submit --file "$dmg" --wait --timeout 1h --output table
  # Apple's stapler, not `asc notarization staple`: stapling rewrites the file, which asc then
  # reports as an unverified change and fails the run.
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
resolved="$src/Recortia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
{
  echo "version: $version ($build)"
  echo "tag: ${tag:-none}"
  echo "commit: $source_commit"
  echo "gate: $gate"
  echo "package_resolved_sha256: $(shasum -a 256 "$resolved" | cut -d' ' -f1)"
  echo "toolchain: $(xcodebuild -version | tr '\n' ' ')"
  echo "dependencies:"
  python3 - "$resolved" "$out/spm/checkouts" <<'PY'
import json, pathlib, sys
pins = json.load(open(sys.argv[1]))["pins"]
checkouts = pathlib.Path(sys.argv[2])
for pin in pins:
    state = pin["state"]
    license_files = sorted(checkouts.glob(f"{pin['identity']}/LICENSE*")) + sorted(checkouts.glob(f"{pin['identity']}/license*"))
    first = license_files[0].read_text(errors="replace").strip().splitlines()[0] if license_files else "unknown"
    print(f"  - {pin['identity']} {state.get('version', '-')} {state['revision'][:12]} {pin['location']} ({first})")
PY
  echo "notarized: $(( ! dry_run ))"
  echo "dmg: $(basename "$dmg")"
  echo "sha256: $sha"
} > "$out/manifest.txt"
cat "$out/manifest.txt"
