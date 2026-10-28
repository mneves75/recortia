#!/bin/zsh
# One entry point into the existing suites. Resolves the installed toolchain against
# TOOLCHAIN.json, then execs the suite with the right DEVELOPER_DIR and mode, so a gate
# invocation cannot silently run under the wrong Xcode.
# usage: ./init.sh [check|e2e|doctor|tests] [suite arguments...]
#   ./init.sh check --unsigned      the repository gate
#   ./init.sh e2e --lang all        the DEBUG scenario runner through the real app
#   ./init.sh doctor                toolchain report only
#   ./init.sh tests                 print tests.json
# Exit codes: 0 ok, 1 no reviewed toolchain matches, 2 bad usage.
set -euo pipefail
cd "${0:A:h}"

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

command_name="${1:-check}"
(( $# > 0 )) && shift

case "$command_name" in
  check|e2e|doctor|tests) ;;
  *) print -u2 "init: unknown suite '$command_name' (check | e2e | doctor | tests)"; exit 2 ;;
esac

# The record decides the mode. Try the reviewed stable baseline first, then the recorded
# release candidate, and refuse rather than guess when neither matches this Xcode.
mode=""
if RECORTIA_TOOLCHAIN_MODE=stable scripts/doctor.sh >/dev/null 2>&1; then
  mode=stable
elif RECORTIA_TOOLCHAIN_MODE=development scripts/doctor.sh >/dev/null 2>&1; then
  mode=development
  print -u2 "init: DEVELOPMENT toolchain (recorded release candidate): compilation and test evidence only, never release qualification"
else
  print -u2 "init: no reviewed toolchain matches $DEVELOPER_DIR"
  RECORTIA_TOOLCHAIN_MODE=stable scripts/doctor.sh || true
  exit 1
fi
export RECORTIA_TOOLCHAIN_MODE="$mode"

case "$command_name" in
  doctor) exec scripts/doctor.sh "$@" ;;
  check) exec scripts/check.sh "$@" ;;
  e2e) exec scripts/e2e.sh "$@" ;;
  tests) exec python3 scripts/tests-report.py --print "$@" ;;
esac
