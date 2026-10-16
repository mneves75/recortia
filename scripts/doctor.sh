#!/bin/zsh
# Stable baseline by default; RECORTIA_TOOLCHAIN_MODE=development selects the recorded RC (ADR-001).
# --release requires the stable baseline even when development mode is inherited.
# Exit codes: 0 ok, 1 mismatch or missing tool.
set -euo pipefail
cd "${0:A:h}/.."

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

toolchain_mode="${RECORTIA_TOOLCHAIN_MODE:-stable}"
if (( $# == 1 )) && [[ "$1" == "--release" ]]; then
  toolchain_mode=stable
elif (( $# != 0 )); then
  echo "doctor: usage: scripts/doctor.sh [--release]" >&2
  exit 1
fi
case "$toolchain_mode" in
  stable|development) ;;
  *) echo "doctor: unknown RECORTIA_TOOLCHAIN_MODE '$toolchain_mode' (use stable or development)" >&2; exit 1 ;;
esac

expected_output=$(python3 - "$toolchain_mode" <<'PY'
import json, sys
try:
    record = json.load(open("TOOLCHAIN.json"))
    if record["allow_beta_toolchains_for_release"] is not False:
        raise ValueError("prerelease toolchains cannot qualify releases")
    if sys.argv[1] == "stable":
        selected = record["stable_xcode_baseline"]
        required_channel = "stable"
    else:
        selected = {
            "version": record["actual_xcode_version"],
            "build": record["actual_xcode_build"],
            "release_channel": record["actual_xcode_release_channel"],
        }
        required_channel = "release_candidate"
    if selected["release_channel"] != required_channel:
        raise ValueError(f"{sys.argv[1]} mode requires release_channel={required_channel}")
    if int(selected["version"].split(".")[0]) != record["required_stable_xcode_major"]:
        raise ValueError("selected Xcode major differs from the reviewed baseline")
    for field in ("version", "build", "release_channel"):
        value = selected[field]
        if not isinstance(value, str) or not value or any(character.isspace() for character in value):
            raise ValueError(f"invalid toolchain {field}")
        print(value)
except (OSError, KeyError, TypeError, ValueError) as error:
    sys.exit(f"doctor: toolchain policy error: {error}")
PY
)
expected_fields=("${(@f)expected_output}")
expected_version="${expected_fields[1]}"
expected_build="${expected_fields[2]}"
expected_channel="${expected_fields[3]}"
baseline_label="stable baseline"
[[ "$toolchain_mode" == "development" ]] && baseline_label="recorded development toolchain"
xcode_output=$(xcodebuild -version)
actual_build=$(awk '/Build version/ {print $3}' <<< "$xcode_output")
actual_version=$(awk '/^Xcode/ {print $2}' <<< "$xcode_output")

rc=0
if [[ "$actual_build" != "$expected_build" || "$actual_version" != "$expected_version" ]]; then
  echo "doctor: Xcode $actual_version ($actual_build; $DEVELOPER_DIR) != $baseline_label $expected_version ($expected_build)" >&2
  echo "doctor: select the reviewed toolchain with DEVELOPER_DIR; RECORTIA_TOOLCHAIN_MODE=development permits only the recorded RC for development" >&2
  rc=1
else
  if [[ "$toolchain_mode" == "development" ]]; then
    echo "doctor: DEVELOPMENT Xcode $actual_version ($actual_build), $expected_channel; not release qualification"
  else
    echo "doctor: Xcode $actual_version ($actual_build) matches the stable baseline in TOOLCHAIN.json"
  fi
fi

if ! command -v xcodegen >/dev/null; then
  echo "doctor: xcodegen missing (brew install xcodegen); needed only to regenerate the project" >&2
fi

swift_output=$(xcrun swift --version 2>&1)
swift_line="${swift_output%%$'\n'*}"
echo "doctor: $swift_line"
exit $rc
