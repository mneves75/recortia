#!/bin/zsh
# Runs the XcodeGen pinned in TOOLCHAIN.json, never a global copy: another XcodeGen release writes
# a different project, so freshness evidence is reproducible only with the pinned one.
# First use downloads the pinned zip into .build/tools/, verifies its sha256 and unpacks it; a
# checksum mismatch installs nothing. The caller's working directory is kept.
# Usage: scripts/xcodegen.sh <xcodegen arguments...>   e.g. scripts/xcodegen.sh generate
set -euo pipefail
root="${0:A:h:h}"

pin_output=$(python3 - "$root/TOOLCHAIN.json" <<'PY'
import json, re, sys
try:
    pin = json.load(open(sys.argv[1]))["xcodegen"]
    version, sha256, url = pin["version"], pin["sha256"], pin["url"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(\.[0-9]+)*", version):
        raise ValueError(f"invalid version {version!r}")
    if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("invalid sha256")
    if not isinstance(url, str) or not url or any(c.isspace() for c in url):
        raise ValueError("invalid url")
    print(version, sha256, url, sep="\n")
except (OSError, KeyError, TypeError, ValueError) as error:
    sys.exit(f"xcodegen: TOOLCHAIN.json pin error: {error}")
PY
)
pin=("${(@f)pin_output}")
version="${pin[1]}"
sha256="${pin[2]}"
url="${pin[3]}"

tools="$root/.build/tools"
install="$tools/xcodegen-$version"
binary="$install/bin/xcodegen"
if [[ ! -x "$binary" ]]; then
  mkdir -p "$tools"
  staging=$(mktemp -d "$tools/.xcodegen-$version.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  echo "xcodegen: fetching pinned XcodeGen $version" >&2
  if ! curl -fsSL --retry 3 -o "$staging/xcodegen.zip" "$url"; then
    echo "xcodegen: download of $url failed" >&2
    exit 1
  fi
  actual=$(shasum -a 256 "$staging/xcodegen.zip" | awk '{print $1}')
  if [[ "$actual" != "$sha256" ]]; then
    echo "xcodegen: sha256 $actual of $url != pinned $sha256 in TOOLCHAIN.json; nothing installed" >&2
    exit 1
  fi
  unzip -q "$staging/xcodegen.zip" -d "$staging/unpacked"
  if [[ ! -x "$staging/unpacked/xcodegen/bin/xcodegen" ]]; then
    echo "xcodegen: the pinned zip has no xcodegen/bin/xcodegen" >&2
    exit 1
  fi
  # A concurrent run may have installed it meanwhile from the same verified zip.
  [[ -e "$install" ]] || mv "$staging/unpacked/xcodegen" "$install"
  rm -rf -- "$staging"
  trap - EXIT
fi
exec "$binary" "$@"
