#!/bin/zsh
# Runs the XcodeGen pinned in TOOLCHAIN.json, never a global copy: another XcodeGen release writes
# a different project, so freshness evidence is reproducible only with the pinned one.
# First use downloads the pinned zip over https into a staging directory, verifies its sha256,
# unpacks it and publishes it by one rename into .build/tools/xcodegen-<version>-<digest prefix>;
# a checksum mismatch installs nothing. The cache is keyed by the digest, so a changed pin never
# runs an older entry. The caller's working directory is kept.
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
    if not isinstance(url, str) or not re.fullmatch(r"https://[!-~]+", url):
        raise ValueError(f"invalid url {url!r} (https only, no spaces or control characters)")
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
install="$tools/xcodegen-$version-${sha256[1,16]}"
binary="$install/bin/xcodegen"
if [[ -L "$install" ]]; then
  echo "xcodegen: $install is a symbolic link; remove it so the verified zip can be installed" >&2
  exit 1
fi
if [[ ! -x "$binary" ]]; then
  mkdir -p "$tools"
  staging=$(mktemp -d "$tools/.xcodegen-$version.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  echo "xcodegen: fetching pinned XcodeGen $version" >&2
  if ! curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
      -o "$staging/xcodegen.zip" -- "$url"; then
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
  # One rename publishes the complete entry. When a concurrent run published first, the rename
  # fails on the existing entry and this run uses it; its staging is discarded either way.
  python3 - "$staging/unpacked/xcodegen" "$install" <<'PY'
import errno, os, sys
source, target = sys.argv[1:]
try:
    os.rename(source, target)
except OSError as error:
    if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or os.path.islink(target) or not os.path.isdir(target):
        sys.exit(f"xcodegen: cannot publish {target}: {error}")
PY
  rm -rf -- "$staging"
  trap - EXIT
  if [[ -L "$install" || ! -x "$binary" ]]; then
    echo "xcodegen: $install is not a usable XcodeGen entry" >&2
    exit 1
  fi
fi
exec "$binary" "$@"
