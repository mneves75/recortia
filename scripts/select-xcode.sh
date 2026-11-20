#!/bin/zsh
# Prints the DEVELOPER_DIR of the installed Xcode whose version AND build equal
# stable_xcode_baseline in TOOLCHAIN.json. Runner images move Xcode paths, so CI selects by
# version and build, never by path. Every candidate is listed on stderr.
# Usage: scripts/select-xcode.sh [applications-directory]   (default /Applications)
# Exit codes: 0 selected, 1 no candidate matches, 2 bad usage.
set -euo pipefail
cd "${0:A:h}/.."

if (( $# > 1 )); then
  echo "select-xcode: usage: scripts/select-xcode.sh [applications-directory]" >&2
  exit 2
fi
applications="${1:-/Applications}"

baseline=$(python3 -c 'import json; b = json.load(open("TOOLCHAIN.json"))["stable_xcode_baseline"]; print(b["version"]); print(b["build"])')
want=("${(@f)baseline}")
want_version="${want[1]}"
want_build="${want[2]}"

selected=""
available=()
for app in "$applications"/Xcode*.app(N/); do
  if ! output=$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2>&1); then
    print -u2 -r -- "$app: xcodebuild -version failed: $output"
    continue
  fi
  print -u2 -r -- "$app:"$'\n'"$output"
  version=$(awk '/^Xcode/ {print $2}' <<< "$output")
  build=$(awk '/Build version/ {print $3}' <<< "$output")
  available+=("$version ($build)")
  if [[ -z "$selected" && "$version" == "$want_version" && "$build" == "$want_build" ]]; then
    selected="$app"
  fi
done

if [[ -z "$selected" ]]; then
  print -u2 -r -- "select-xcode: no Xcode in $applications matches the stable baseline $want_version ($want_build) in TOOLCHAIN.json; available: ${(j:, :)available:-none}"
  exit 1
fi
print -u2 -r -- "select-xcode: selected $selected for $want_version ($want_build)"
print -r -- "$selected/Contents/Developer"
