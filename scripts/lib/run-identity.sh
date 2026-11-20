# Sourced by check.sh, e2e.sh and release.sh. A run prints `<suite>: $(run_identity)` when it starts
# and `<suite>: end $(run_identity)` before its success marker; scripts/tests-report.py credits the
# run to a commit only when both name that commit with a clean tree. A git failure reads as
# unknown, never as clean.
run_identity() {
  local sha changes state
  sha=$(git rev-parse HEAD 2>/dev/null) || sha=unknown
  if changes=$(git status --porcelain --untracked-files=all 2>/dev/null); then
    if [[ -z $changes ]]; then state=clean; else state=dirty; fi
  else
    state=unknown
  fi
  print -r -- "commit $sha tree $state"
}
