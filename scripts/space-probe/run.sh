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
#   overlay (see probe.swift). Each prints one JSON line; spaceChanges must be 0 for every
#   variant Recortia uses (follow-*, activate-only-follow, panel-*, overlay).
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
[[ $mode == fresh || $mode == stale ]] || { echo "usage: run.sh <fresh|stale> <variant>..." >&2; exit 2; }
work=$(mktemp -d)
for variant in "$@"; do
  rm -f "$work/ready" "$work/hostpid"
  if [[ $mode == stale ]]; then
    READY_FILE=$work/ready HOST_PID_FILE=$work/hostpid "$bin/probe" "$variant" stale &
    probe=$!
    for i in {1..40}; do [[ -f $work/ready ]] && break; sleep 0.25; done
  fi
  "$bin/host" &
  host=$!
  echo $host > "$work/hostpid"
  if [[ $mode == fresh ]]; then
    HOST_PID_FILE=$work/hostpid "$bin/probe" "$variant" fresh &
    probe=$!
  fi
  for i in {1..60}; do kill -0 $probe 2>/dev/null || break; sleep 0.25; done
  kill $probe 2>/dev/null
  kill $host 2>/dev/null
  wait $host 2>/dev/null
  sleep 1.5
done
rm -rf "$work"
