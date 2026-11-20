#!/bin/zsh
# Physical Space probe (FR-01, ACCEPTANCE_TESTS CAP-02): does showing a window configured like a
# Recortia surface switch the user's Space while another app is in a fullscreen Space?
# It briefly puts its own empty host window into fullscreen on the current desktop, so run it
# on a dedicated desktop or with the owner's consent. It reads only window-list metadata for
# its own processes: no screen pixels, no Screen Recording permission.
#
# Usage: scripts/space-probe/run.sh <fresh|stale> <variant>...
#   fresh  the probe creates its window after the host is fullscreen
#   stale  the probe's window already exists on the desktop Space, then is shown again
# Variants: default, follow-activate-first, follow-order-first, activate-only-default,
#   activate-only-follow, panel-activating, panel-nonactivating, panel-nonactivating-alljoin,
#   overlay, dynamic-follow, dynamic-pin (see probe.swift). Each prints one JSON line;
#   spaceChanges must be 0 for every variant Recortia uses (follow-*, activate-only-follow,
#   panel-*, overlay, and the dynamic-* variants that start accessory and become regular, ADR-007).
# FORCE=1 stands in for user-granted activation (a hotkey or menu click); without it macOS 14+
# may decline the probe's cooperative activation request.
set -u
cd "${0:A:h}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
bin=../../.build/space-probe
mkdir -p "$bin"
xcrun swiftc -O host.swift -o "$bin/host" || exit 2
xcrun swiftc -O probe.swift -o "$bin/probe" || exit 2

mode=${1:-}; shift || true
if [[ $mode != fresh && $mode != stale ]] || (( $# == 0 )); then
  echo "usage: run.sh <fresh|stale> <variant>..." >&2
  exit 2
fi
# Exit 0 only when every variant's probe exited 0 and printed its own JSON result; a timeout, a
# crash or a missing line is a failed measurement, never a pass.
rc=0
work=$(mktemp -d)
for variant in "$@"; do
  rm -f "$work/ready" "$work/hostpid" "$work/result" "$work/fullscreen"
  # The host creates this file from windowDidEnterFullScreen; the probe measures only after it.
  export FULLSCREEN_FILE=$work/fullscreen
  if [[ $mode == stale ]]; then
    READY_FILE=$work/ready HOST_PID_FILE=$work/hostpid "$bin/probe" "$variant" stale >"$work/result" &
    probe=$!
    for i in {1..40}; do [[ -f $work/ready ]] && break; sleep 0.25; done
  fi
  "$bin/host" &
  host=$!
  echo $host > "$work/hostpid"
  if [[ $mode == fresh ]]; then
    HOST_PID_FILE=$work/hostpid "$bin/probe" "$variant" fresh >"$work/result" &
    probe=$!
  fi
  for i in {1..60}; do kill -0 $probe 2>/dev/null || break; sleep 0.25; done
  kill $probe 2>/dev/null
  wait $probe
  probe_status=$?
  kill $host 2>/dev/null
  wait $host 2>/dev/null
  cat "$work/result"
  if (( probe_status != 0 )) || ! python3 - "$variant" "$work/result" "$mode" <<'PY'
import json, pathlib, sys
lines = [line for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if line.strip()]
try:
    result = json.loads(lines[-1]) if lines else None
except json.JSONDecodeError:
    result = None
if not isinstance(result, dict):
    sys.exit(1)
count = result.get("spaceChanges")
# A count measures a Space change only from the requested mode, after the host entered its
# fullscreen Space, with the host still in front.
valid = (result.get("variant") == sys.argv[1] and result.get("mode") == sys.argv[3]
         and result.get("hostFrontBefore") is True and result.get("hostEnteredFullScreen") is True
         and type(count) is int)
sys.exit(0 if valid else 1)
PY
  then
    echo "space-probe: no valid result for $variant (probe exit $probe_status)" >&2
    rc=1
  fi
  sleep 1.5
done
rm -rf "$work"
exit $rc
