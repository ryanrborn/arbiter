#!/usr/bin/env bash
#
# Run the coordinator-session restart-survival regression test (bd-b95w36).
#
# This is the §4.2 spike of docs/browser-hosted-coordinator-sessions.md as an
# automated test: it starts a throwaway systemd *user* service standing in for
# arbiter.service, launches a session from inside it through
# Arbiter.Sessions.launch/1, restarts the stand-in for real, and asserts that
#
#   * the arb-session-<id> scope is still active and the tmux server is the
#     same pid it was before,
#   * the pane's sequenced output is contiguous 1..N across the restart,
#   * a tmux started as a plain child of the same unit is DEAD (the negative
#     control — this is what proves the test can fail),
#   * stopping (rather than restarting) the stand-in leaves the scope active.
#
# The test is excluded from `mix precommit` because it needs a real systemd
# user instance, which CI runners generally do not have. This script is the
# documented way to run it locally or on the arbiter host.
#
#   scripts/session-restart-survival.sh              # run it
#   scripts/session-restart-survival.sh --log FILE   # also tee output to FILE
#
# SAFETY: nothing here — or in the test — ever matches a process by name.
# Every unit, scope and tmux socket it touches is an exact name derived from a
# fresh unique id, and the live coordinator's own `arbiter.service` is never
# addressed. The script verifies afterwards that arbiter.service is still in
# the state it found it in.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FILE="test/integration/session_restart_survival_test.exs"
LOG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --log)
      LOG="${2:?--log needs a path}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,27p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

for tool in systemd-run systemctl tmux; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIPPED: $tool is not installed — this test needs a systemd user instance." >&2
    echo "Run it on the arbiter host instead." >&2
    exit 1
  fi
done

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "SKIPPED: no systemd user instance here (systemctl --user cannot reach the bus)." >&2
  echo "Run it on the arbiter host instead." >&2
  exit 1
fi

# Recorded before and checked after: this script must be incapable of
# disturbing the live coordinator.
ARBITER_BEFORE="$(systemctl --user is-active arbiter.service 2>&1 || true)"

echo "systemd user instance: ok"
echo "arbiter.service before: ${ARBITER_BEFORE}"
echo

# `mix test <path>` at an umbrella root is not scoped to one app — it runs
# every app's whole suite — so run it from apps/arbiter.
cd "${REPO_ROOT}/apps/arbiter"

set +e
if [ -n "$LOG" ]; then
  MIX_ENV=test mix test --include systemd_user "$TEST_FILE" 2>&1 | tee "$LOG"
  STATUS=${PIPESTATUS[0]}
else
  MIX_ENV=test mix test --include systemd_user "$TEST_FILE"
  STATUS=$?
fi
set -e

ARBITER_AFTER="$(systemctl --user is-active arbiter.service 2>&1 || true)"
echo
echo "arbiter.service after:  ${ARBITER_AFTER}"

if [ "$ARBITER_BEFORE" != "$ARBITER_AFTER" ]; then
  echo "WARNING: arbiter.service changed state during this run " \
    "(${ARBITER_BEFORE} -> ${ARBITER_AFTER}). That is not something this test does; " \
    "check what else was running." >&2
fi

# Leftover scratch units would collide with nothing (every name carries a fresh
# unique id), but report them so a crashed run is visible rather than silent.
LEFTOVERS="$(systemctl --user list-units --all --no-legend 'arbrs*' 2>/dev/null || true)"
if [ -n "$LEFTOVERS" ]; then
  echo
  echo "NOTE: stand-in units left behind by this or an earlier run:" >&2
  echo "$LEFTOVERS" >&2
  echo "Stop them by exact name: systemctl --user stop <unit>" >&2
fi

exit "$STATUS"
